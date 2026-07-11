#include <CLI/CLI.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

#include "bindings.h"
#include "input_data.hpp"
#include "loaders.hpp"
#include "model.hpp"
#include "random_iter.hpp"
#include "ssim.hpp"

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {

volatile std::sig_atomic_t cancellationSignal = 0;

void observeCancellation(int signal) {
    cancellationSignal = signal;
}

class EventWriter {
public:
    EventWriter(bool enabled, std::ostream &stream) : enabled_(enabled), stream_(stream) {}

    void emit(const std::string &event, json fields = json::object()) {
        if (!enabled_) return;
        fields["event"] = event;
        fields["schema_version"] = 1;
        fields["sequence"] = ++sequence_;
        stream_ << fields.dump() << '\n' << std::flush;
    }

private:
    bool enabled_;
    std::ostream &stream_;
    std::uint64_t sequence_ = 0;
};

bool cancelIfRequested(EventWriter &events, int completedIteration) {
    if (cancellationSignal == 0) return false;
    events.emit("cancellation_requested", {{"iteration", completedIteration},
                                           {"signal", cancellationSignal}});
    msplat_gpu_sync();
    events.emit("cancelled", {{"iteration", completedIteration}});
    return true;
}

void throwSystemError(const std::string &operation, const fs::path &path) {
    throw std::runtime_error(operation + " " + path.string() + ": " + std::strerror(errno));
}

void syncFile(const fs::path &path) {
    int descriptor = ::open(path.c_str(), O_RDONLY);
    if (descriptor < 0) throwSystemError("cannot open", path);
    if (::fsync(descriptor) != 0) {
        int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throwSystemError("cannot sync", path);
    }
    if (::close(descriptor) != 0) throwSystemError("cannot close", path);
}

void syncDirectory(const fs::path &path) {
    int descriptor = ::open(path.c_str(), O_RDONLY);
    if (descriptor < 0) throwSystemError("cannot open directory", path);
    if (::fsync(descriptor) != 0) {
        int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throwSystemError("cannot sync directory", path);
    }
    if (::close(descriptor) != 0) throwSystemError("cannot close directory", path);
}

struct PlyValidation {
    std::uint64_t vertices;
    std::uint64_t properties;
    std::uintmax_t bytes;
};

PlyValidation validateBinaryPly(const fs::path &path) {
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) throw std::runtime_error("cannot open PLY for validation");

    std::string line;
    if (!std::getline(input, line) || line != "ply") {
        throw std::runtime_error("PLY header is missing the magic line");
    }
    if (!std::getline(input, line) || line != "format binary_little_endian 1.0") {
        throw std::runtime_error("PLY must use binary_little_endian 1.0");
    }

    std::uint64_t vertices = 0;
    std::uint64_t properties = 0;
    bool sawVertexElement = false;
    bool sawEndHeader = false;
    for (int headerLine = 0; headerLine < 512 && std::getline(input, line); ++headerLine) {
        constexpr std::string_view vertexPrefix = "element vertex ";
        if (line.rfind(vertexPrefix, 0) == 0) {
            if (sawVertexElement) throw std::runtime_error("PLY has duplicate vertex elements");
            const std::string count = line.substr(vertexPrefix.size());
            std::size_t parsed = 0;
            try {
                vertices = std::stoull(count, &parsed);
            } catch (const std::exception &) {
                throw std::runtime_error("PLY vertex count is invalid");
            }
            if (parsed != count.size() || vertices == 0) {
                throw std::runtime_error("PLY vertex count is invalid");
            }
            sawVertexElement = true;
        } else if (sawVertexElement && line.rfind("property float ", 0) == 0) {
            ++properties;
        } else if (line == "end_header") {
            sawEndHeader = true;
            break;
        }
        const auto position = input.tellg();
        if (position < 0 || position > 65536) {
            throw std::runtime_error("PLY header is unreasonably large");
        }
    }

    if (!sawEndHeader || !sawVertexElement || properties < 17) {
        throw std::runtime_error("PLY vertex layout is incomplete");
    }
    const auto payloadOffsetPosition = input.tellg();
    if (payloadOffsetPosition < 0) throw std::runtime_error("PLY payload offset is invalid");
    const auto payloadOffset = static_cast<std::uintmax_t>(payloadOffsetPosition);
    constexpr std::uintmax_t floatBytes = sizeof(float);
    if (properties > std::numeric_limits<std::uintmax_t>::max() / floatBytes) {
        throw std::runtime_error("PLY payload size overflows");
    }
    const std::uintmax_t rowBytes = properties * floatBytes;
    if (vertices > (std::numeric_limits<std::uintmax_t>::max() - payloadOffset) / rowBytes) {
        throw std::runtime_error("PLY payload size overflows");
    }
    const std::uintmax_t expectedBytes = payloadOffset + vertices * rowBytes;
    const std::uintmax_t actualBytes = fs::file_size(path);
    if (actualBytes != expectedBytes) {
        throw std::runtime_error("PLY payload length does not match its header");
    }
    return {vertices, properties, actualBytes};
}

bool savePlyAtomically(Model &model, const fs::path &output, int step, EventWriter &events) {
    fs::path parent = output.parent_path();
    if (parent.empty()) parent = fs::current_path();
    fs::create_directories(parent);

    fs::path temporary = parent / ("." + output.filename().string() + ".tmp." +
                                   std::to_string(static_cast<long long>(::getpid())) + ".ply");
    std::error_code ignored;
    fs::remove(temporary, ignored);

    try {
        model.save(temporary.string(), step);
        if (!fs::is_regular_file(temporary) || fs::file_size(temporary) == 0) {
            throw std::runtime_error("msplat produced an empty PLY");
        }
        validateBinaryPly(temporary);
        syncFile(temporary);
        if (cancelIfRequested(events, step)) {
            fs::remove(temporary, ignored);
            return false;
        }
        if (::rename(temporary.c_str(), output.c_str()) != 0) {
            throwSystemError("cannot atomically replace", output);
        }
        syncDirectory(parent);
        return true;
    } catch (...) {
        fs::remove(temporary, ignored);
        throw;
    }
}

struct EvaluationMetrics {
    double psnr = 0;
    double ssim = 0;
    double l1 = 0;
    int views = 0;
};

std::optional<EvaluationMetrics> evaluate(
    Model &model,
    std::vector<Camera> &cameras,
    int step,
    EventWriter &events
) {
    EvaluationMetrics metrics;
    metrics.views = static_cast<int>(cameras.size());
    for (Camera &camera : cameras) {
        if (cancelIfRequested(events, step)) return std::nullopt;
        MTensor rendered = model.render(camera, step);
        msplat_gpu_sync();
        MTensor renderedCpu = rendered.cpu();
        MTensor targetCpu = camera.getGPUImage(model.getDownscaleFactor(step)).cpu();
        metrics.psnr += psnr(renderedCpu, targetCpu);
        metrics.ssim += ssim_eval(renderedCpu, targetCpu);
        metrics.l1 += l1_loss(renderedCpu, targetCpu);
        if (cancelIfRequested(events, step)) return std::nullopt;
    }
    if (metrics.views > 0) {
        metrics.psnr /= metrics.views;
        metrics.ssim /= metrics.views;
        metrics.l1 /= metrics.views;
    }
    return metrics;
}

} // namespace

int main(int argc, char *argv[]) {
    CLI::App app{"EasySplat native msplat trainer"};
    app.set_help_flag("-h,--help", "Show this help message");
    app.set_version_flag("--version", APP_VERSION);

    std::string inputPath;
    std::string outputPath = "splat.ply";
    int numIterations = 30000;
    int numDownscales = 2;
    float downscaleFactor = 1.0f;
    std::uint64_t seed = 42;
    bool evalMode = false;
    bool eventsJsonl = false;
    bool selfCheck = false;
    std::string plyToValidate;

    app.add_option("--input", inputPath, "COLMAP dataset directory");
    app.add_option("--output", outputPath, "Final PLY output path");
    app.add_option("--num-iters", numIterations, "Training iterations")
        ->check(CLI::Range(1, 1000000));
    app.add_option("--num-downscales", numDownscales, "Progressive downscale levels")
        ->check(CLI::Range(0, 16));
    app.add_option("--downscale-factor", downscaleFactor, "Initial image downscale factor")
        ->check(CLI::Range(1.0f, 32.0f));
    app.add_option("--seed", seed, "Deterministic uint64 camera-order seed");
    app.add_flag("--eval", evalMode, "Hold out every eighth camera for evaluation");
    app.add_flag("--events-jsonl", eventsJsonl, "Reserve stdout for schema-v1 JSONL events");
    app.add_flag("--self-check", selfCheck, "Initialize Metal and load the adjacent metallib");
    app.add_option("--validate-ply", plyToValidate, "Validate a binary Gaussian PLY")
        ->check(CLI::ExistingFile);

    CLI11_PARSE(app, argc, argv);

    std::streambuf *jsonBuffer = std::cout.rdbuf();
    std::ostream jsonOutput(jsonBuffer);
    if (eventsJsonl) std::cout.rdbuf(std::cerr.rdbuf());
    EventWriter events(eventsJsonl, jsonOutput);

    try {
        if (!plyToValidate.empty()) {
            const PlyValidation validation = validateBinaryPly(plyToValidate);
            events.emit("output_validation", {{"output_bytes", validation.bytes},
                                               {"status", "ok"},
                                               {"vertex_count", validation.vertices}});
            if (!eventsJsonl) std::cout << "PLY validation passed\n";
            return 0;
        }
        if (selfCheck) {
            if (msplat_device() == nullptr) {
                throw std::runtime_error("Metal device initialization returned null");
            }
            msplat_gpu_sync();
            events.emit("self_check", {{"status", "ok"}, {"version", APP_VERSION}});
            if (!eventsJsonl) std::cout << "Metal self-check passed\n";
            return 0;
        }

        if (inputPath.empty()) throw std::runtime_error("--input is required for training");
        if (!fs::is_directory(inputPath)) throw std::runtime_error("input dataset directory does not exist");
        if (fs::path(outputPath).extension() != ".ply") throw std::runtime_error("--output must end in .ply");

        struct sigaction action {};
        action.sa_handler = observeCancellation;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        if (sigaction(SIGINT, &action, nullptr) != 0 || sigaction(SIGTERM, &action, nullptr) != 0) {
            throw std::runtime_error("failed to install cancellation handlers");
        }

        InputData inputData = inputDataFromX(inputPath);
        for (Camera &camera : inputData.cameras) camera.loadImage(downscaleFactor);

        std::vector<Camera> cameras;
        std::vector<Camera> testCameras;
        if (evalMode) {
            std::tie(cameras, testCameras) = inputData.splitTrainTest(8);
        } else {
            Camera *unusedValidationCamera = nullptr;
            std::tie(cameras, unusedValidationCamera) = inputData.getCameras(false);
        }
        if (cameras.empty()) throw std::runtime_error("input dataset contains no training cameras");

        constexpr int resolutionSchedule = 3000;
        constexpr int shDegree = 3;
        constexpr int shDegreeInterval = 1000;
        constexpr int refineEvery = 100;
        constexpr int warmupLength = 500;
        constexpr int resetAlphaEvery = 30;
        constexpr float densifyGradThreshold = 0.0002f;
        constexpr float densifySizeThreshold = 0.01f;
        constexpr int stopScreenSizeAt = 4000;
        constexpr float splitScreenSize = 0.05f;
        constexpr float ssimWeight = 0.2f;
        constexpr float background[3] = {0.6130f, 0.0101f, 0.3984f};

        Model model(inputData, static_cast<int>(cameras.size()), numDownscales,
                    resolutionSchedule, shDegree, shDegreeInterval, refineEvery,
                    warmupLength, resetAlphaEvery, densifyGradThreshold,
                    densifySizeThreshold, stopScreenSizeAt, splitScreenSize,
                    numIterations, false, background);

        std::vector<size_t> camIndices(cameras.size());
        std::iota(camIndices.begin(), camIndices.end(), 0);
        InfiniteRandomIterator<size_t> camsIter(camIndices, seed);

        events.emit("started", {{"iteration", 0},
                                {"iteration_limit", numIterations},
                                {"seed", seed},
                                {"version", APP_VERSION}});

        const auto startedAt = std::chrono::steady_clock::now();
        auto lastProgressAt = startedAt;
        for (int step = 1; step <= numIterations; ++step) {
            if (cancelIfRequested(events, step - 1)) return 130;

            Camera &camera = cameras[camsIter.next()];
            MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
            model.fullIteration(camera, step, target, ssimWeight);
            model.schedulersStep(step);
            model.afterTrain(step);
            msplat_commit();

            if (cancelIfRequested(events, step)) return 130;

            auto now = std::chrono::steady_clock::now();
            if (step == numIterations || now - lastProgressAt >= std::chrono::seconds(1)) {
                msplat_gpu_sync();
                now = std::chrono::steady_clock::now();
                const double elapsed = std::chrono::duration<double>(now - startedAt).count();
                const double rate = elapsed > 0 ? static_cast<double>(step) / elapsed : 0;
                const double eta = rate > 0 ? static_cast<double>(numIterations - step) / rate : 0;
                events.emit("progress", {{"elapsed_seconds", elapsed},
                                         {"eta_seconds", eta},
                                         {"gaussian_count", model.num_active},
                                         {"iteration", step},
                                         {"iteration_limit", numIterations},
                                         {"iterations_per_second", rate}});
                lastProgressAt = now;
            }
        }

        if (cancelIfRequested(events, numIterations)) return 130;
        EvaluationMetrics metrics;
        if (evalMode) {
            const auto evaluation = evaluate(model, testCameras, numIterations, events);
            if (!evaluation) return 130;
            metrics = *evaluation;
        }
        if (cancelIfRequested(events, numIterations)) return 130;

        if (!savePlyAtomically(model, outputPath, numIterations, events)) return 130;
        const std::uintmax_t outputBytes = fs::file_size(outputPath);
        const double elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - startedAt).count();

        json completed = {{"elapsed_seconds", elapsed},
                          {"gaussian_count", model.num_active},
                          {"iteration", numIterations},
                          {"iteration_limit", numIterations},
                          {"output_bytes", outputBytes}};
        if (evalMode) {
            completed["evaluation"] = {{"l1", metrics.l1},
                                       {"psnr", metrics.psnr},
                                       {"ssim", metrics.ssim},
                                       {"views", metrics.views}};
        }
        events.emit("completed", completed);
        if (!eventsJsonl) std::cerr << "EasySplat training completed: " << outputPath << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return 1;
    }
}
