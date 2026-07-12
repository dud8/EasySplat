#include <CLI/CLI.hpp>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <unistd.h>
#include <vector>

#include "bindings.h"
#include "input_data.hpp"
#include "loaders.hpp"
#include "model.hpp"
#include "random_iter.hpp"

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {

volatile std::sig_atomic_t cancellationSignal = 0;

void observeCancellation(int signal) {
    cancellationSignal = signal;
}

class EventWriter {
public:
    explicit EventWriter(int descriptor) : descriptor_(descriptor) {
        if (descriptor_ >= 0 && ::fcntl(descriptor_, F_GETFD) == -1) {
            throw std::runtime_error("event file descriptor is not open");
        }
    }

    bool enabled() const { return descriptor_ >= 0; }

    void emit(const std::string &event, json fields = json::object()) {
        if (!enabled()) return;
        fields["event"] = event;
        fields["schema_version"] = 1;
        fields["sequence"] = ++sequence_;
        std::string record = fields.dump();
        record.push_back('\n');
        const char *cursor = record.data();
        std::size_t remaining = record.size();
        while (remaining > 0) {
            const ssize_t written = ::write(descriptor_, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                throw std::runtime_error(
                    "cannot write event file descriptor: " + std::string(std::strerror(errno))
                );
            }
            cursor += written;
            remaining -= static_cast<std::size_t>(written);
        }
    }

private:
    int descriptor_;
    std::uint64_t sequence_ = 0;
};

struct TrainingProfileConfig {
    const char *name;
    int iterationLimit;
    int plateauWindow;
    int numDownscales;
};

constexpr std::array<TrainingProfileConfig, 3> trainingProfiles = {{
    {"fast", 3000, 400, 0},
    {"balanced", 7000, 800, 0},
    {"high-detail", 15000, 1500, 0},
}};

const TrainingProfileConfig &trainingProfileNamed(const std::string &name) {
    const auto match = std::find_if(
        trainingProfiles.begin(), trainingProfiles.end(),
        [&](const TrainingProfileConfig &candidate) { return name == candidate.name; }
    );
    if (match == trainingProfiles.end()) {
        throw std::runtime_error("--profile must be fast, balanced, or high-detail");
    }
    return *match;
}

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
        msplat_gpu_sync();
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

} // namespace

int main(int argc, char *argv[]) {
    CLI::App app{"EasySplat native msplat trainer"};
    app.set_help_flag("-h,--help", "Show this help message");
    app.set_version_flag("--version", APP_VERSION);

    std::string datasetPath;
    std::string outputPath;
    std::string profileName;
    std::uint64_t seed = 42;
    int eventsFileDescriptor = -1;
    bool selfCheck = false;
    std::string plyToValidate;

    CLI::Option *datasetOption = app.add_option(
        "--dataset", datasetPath, "Canonical COLMAP dataset directory"
    );
    CLI::Option *outputOption = app.add_option("--output", outputPath, "Final PLY output path");
    CLI::Option *profileOption = app.add_option(
        "--profile", profileName, "Training profile: fast, balanced, or high-detail"
    );
    CLI::Option *seedOption = app.add_option(
        "--seed", seed, "Deterministic uint64 camera-order seed"
    );
    CLI::Option *eventsOption = app.add_option(
        "--events-fd", eventsFileDescriptor, "Descriptor for schema-v1 JSONL events"
    );
    eventsOption->check(CLI::Range(0, std::numeric_limits<int>::max()));
    app.add_flag("--self-check", selfCheck, "Initialize Metal and load the adjacent metallib");
    app.add_option("--validate-ply", plyToValidate, "Validate a binary Gaussian PLY")
        ->check(CLI::ExistingFile);

    CLI11_PARSE(app, argc, argv);

    try {
        struct sigaction ignoreBrokenPipe {};
        ignoreBrokenPipe.sa_handler = SIG_IGN;
        sigemptyset(&ignoreBrokenPipe.sa_mask);
        ignoreBrokenPipe.sa_flags = 0;
        if (sigaction(SIGPIPE, &ignoreBrokenPipe, nullptr) != 0) {
            throw std::runtime_error("failed to configure event-pipe handling");
        }
        EventWriter events(eventsFileDescriptor);
        if (eventsFileDescriptor == STDOUT_FILENO) std::cout.rdbuf(std::cerr.rdbuf());

        if (!plyToValidate.empty()) {
            const PlyValidation validation = validateBinaryPly(plyToValidate);
            events.emit("output_validation", {{"output_bytes", validation.bytes},
                                               {"status", "ok"},
                                               {"vertex_count", validation.vertices}});
            if (!events.enabled()) std::cout << "PLY validation passed\n";
            return 0;
        }
        if (selfCheck) {
            if (msplat_device() == nullptr) {
                throw std::runtime_error("Metal device initialization returned null");
            }
            msplat_gpu_sync();
            events.emit("self_check", {{"status", "ok"}, {"version", APP_VERSION}});
            if (!events.enabled()) std::cout << "Metal self-check passed\n";
            return 0;
        }

        if (datasetOption->count() == 0) throw std::runtime_error("--dataset is required for training");
        if (outputOption->count() == 0) throw std::runtime_error("--output is required for training");
        if (profileOption->count() == 0) throw std::runtime_error("--profile is required for training");
        if (seedOption->count() == 0) throw std::runtime_error("--seed is required for training");
        if (eventsOption->count() == 0) throw std::runtime_error("--events-fd is required for training");
        const TrainingProfileConfig &profile = trainingProfileNamed(profileName);
        if (!fs::is_directory(datasetPath)) throw std::runtime_error("dataset directory does not exist");
        if (fs::path(outputPath).extension() != ".ply") throw std::runtime_error("--output must end in .ply");

        struct sigaction action {};
        action.sa_handler = observeCancellation;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        if (sigaction(SIGINT, &action, nullptr) != 0 || sigaction(SIGTERM, &action, nullptr) != 0) {
            throw std::runtime_error("failed to install cancellation handlers");
        }

        InputData inputData = inputDataFromX(datasetPath);
        for (Camera &camera : inputData.cameras) camera.loadImage(1.0f);

        std::vector<Camera> cameras;
        Camera *unusedValidationCamera = nullptr;
        std::tie(cameras, unusedValidationCamera) = inputData.getCameras(false);
        if (cameras.empty()) throw std::runtime_error("input dataset contains no training cameras");

        constexpr int resolutionSchedule = 3000;
        constexpr int shDegree = 3;
        constexpr int shDegreeInterval = 1000;
        constexpr int refineEvery = 100;
        constexpr int lossSyncBatch = refineEvery;
        constexpr int warmupLength = 500;
        constexpr int resetAlphaEvery = 30;
        constexpr float densifyGradThreshold = 0.0002f;
        constexpr float densifySizeThreshold = 0.01f;
        constexpr int stopScreenSizeAt = 4000;
        constexpr float splitScreenSize = 0.05f;
        constexpr float ssimWeight = 0.2f;
        constexpr float background[3] = {0.6130f, 0.0101f, 0.3984f};

        Model model(inputData, static_cast<int>(cameras.size()), profile.numDownscales,
                    resolutionSchedule, shDegree, shDegreeInterval, refineEvery,
                    warmupLength, resetAlphaEvery, densifyGradThreshold,
                    densifySizeThreshold, stopScreenSizeAt, splitScreenSize,
                    profile.iterationLimit, false, background);

        std::vector<size_t> camIndices(cameras.size());
        std::iota(camIndices.begin(), camIndices.end(), 0);
        InfiniteRandomIterator<size_t> camsIter(camIndices, seed);

        events.emit("started", {{"camera_count", cameras.size()},
                                {"initial_gaussian_count", model.num_active},
                                {"iteration", 0},
                                {"iteration_limit", profile.iterationLimit},
                                {"plateau_window", profile.plateauWindow},
                                {"profile", profile.name},
                                {"seed", seed},
                                {"version", APP_VERSION}});

        const auto startedAt = std::chrono::steady_clock::now();
        auto lastProgressAt = startedAt;
        int plateauSampleCount = 0;
        std::vector<float> plateauLosses(lossSyncBatch);
        std::vector<std::size_t> plateauCameraIndices(lossSyncBatch);
        std::vector<double> bestCameraLosses(
            cameras.size(),
            std::numeric_limits<double>::infinity()
        );
        int lastImprovementIteration = warmupLength;
        double latestWindowLoss = std::numeric_limits<double>::quiet_NaN();
        int latestLossIteration = 0;
        int completedIteration = 0;
        std::string stopReason = "iteration_limit";
        for (int step = 1; step <= profile.iterationLimit; ++step) {
            if (cancelIfRequested(events, step - 1)) return 130;

            const std::size_t cameraIndex = camsIter.next();
            Camera &camera = cameras[cameraIndex];
            MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
            model.fullIteration(camera, step, target, ssimWeight);
            model.schedulersStep(step);
            model.afterTrain(step);
            if (step > warmupLength) {
                const float normalization = 1.0f /
                    static_cast<float>(model.lastHeight * model.lastWidth);
                plateauCameraIndices[plateauSampleCount] = cameraIndex;
                msplat_record_last_loss(
                    plateauSampleCount,
                    lossSyncBatch,
                    normalization
                );
                ++plateauSampleCount;
            }
            msplat_commit();
            completedIteration = step;

            bool plateauReached = false;
            if (plateauSampleCount == lossSyncBatch) {
                msplat_sync_loss_window(plateauSampleCount, plateauLosses.data());
                double totalLoss = 0;
                const int firstWindowIteration = step - plateauSampleCount + 1;
                for (int index = 0; index < plateauSampleCount; ++index) {
                    const double loss = plateauLosses[index];
                    const std::size_t sampledCamera = plateauCameraIndices[index];
                    double &bestCameraLoss = bestCameraLosses[sampledCamera];
                    const double improvementThreshold = std::isfinite(bestCameraLoss)
                        ? std::max(1e-7, std::abs(bestCameraLoss) * 1e-4)
                        : 0;
                    if (!std::isfinite(bestCameraLoss) ||
                        loss < bestCameraLoss - improvementThreshold) {
                        bestCameraLoss = loss;
                        lastImprovementIteration = firstWindowIteration + index;
                    }
                    totalLoss += loss;
                }
                latestWindowLoss = totalLoss / static_cast<double>(plateauSampleCount);
                latestLossIteration = step;
                plateauSampleCount = 0;
                plateauReached = step - lastImprovementIteration >= profile.plateauWindow;
            }

            if (cancelIfRequested(events, step)) return 130;

            auto now = std::chrono::steady_clock::now();
            if (step == profile.iterationLimit || now - lastProgressAt >= std::chrono::seconds(1)) {
                msplat_gpu_sync();
                now = std::chrono::steady_clock::now();
                const double elapsed = std::chrono::duration<double>(now - startedAt).count();
                const double rate = elapsed > 0 ? static_cast<double>(step) / elapsed : 0;
                const double eta = rate > 0
                    ? static_cast<double>(profile.iterationLimit - step) / rate
                    : 0;
                json progress = {{"elapsed_seconds", elapsed},
                                 {"eta_seconds", eta},
                                 {"gaussian_count", model.num_active},
                                 {"iteration", step},
                                 {"iteration_limit", profile.iterationLimit},
                                 {"iterations_per_second", rate}};
                if (std::isfinite(latestWindowLoss)) {
                    progress["loss"] = latestWindowLoss;
                    progress["loss_iteration"] = latestLossIteration;
                }
                events.emit("progress", std::move(progress));
                lastProgressAt = now;
            }

            if (plateauReached && step < profile.iterationLimit) {
                stopReason = "plateau";
                events.emit("early_stop", {{"iteration", step},
                                           {"last_improvement_iteration", lastImprovementIteration},
                                           {"loss", latestWindowLoss},
                                           {"loss_iteration", latestLossIteration},
                                           {"plateau_window", profile.plateauWindow},
                                           {"reason", stopReason}});
                break;
            }
        }

        if (cancelIfRequested(events, completedIteration)) return 130;

        if (!savePlyAtomically(model, outputPath, completedIteration, events)) return 130;
        const std::uintmax_t outputBytes = fs::file_size(outputPath);
        const double elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - startedAt).count();

        json completed = {{"elapsed_seconds", elapsed},
                          {"gaussian_count", model.num_active},
                          {"iteration", completedIteration},
                          {"iteration_limit", profile.iterationLimit},
                          {"output_bytes", outputBytes},
                          {"plateau_window", profile.plateauWindow},
                          {"profile", profile.name},
                          {"seed", seed},
                          {"stop_reason", stopReason}};
        events.emit("completed", completed);
        if (!events.enabled()) std::cout << "EasySplat training completed: " << outputPath << '\n';
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return 1;
    }
}
