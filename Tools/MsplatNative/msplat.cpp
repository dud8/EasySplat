// Modified by the EasySplat project in 2026 from msplat 1.1.3.
// Licensed under Apache-2.0; see Tools/MsplatNative/NOTICE.md.

#include <CLI/CLI.hpp>
#include <CommonCrypto/CommonDigest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <unistd.h>
#include <vector>
#include <mach-o/dyld.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/stdio.h>

#include "bindings.h"
#include "input_data.hpp"
#include "isolation_runtime.hpp"
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

std::int64_t peakResidentMemoryBytes() {
    struct rusage usage {};
    if (::getrusage(RUSAGE_SELF, &usage) != 0) {
        throw std::runtime_error(
            "cannot measure peak resident memory: " + std::string(std::strerror(errno))
        );
    }
    if (usage.ru_maxrss <= 0) {
        throw std::runtime_error("peak resident memory is unavailable");
    }
    const auto bytes = static_cast<std::uint64_t>(usage.ru_maxrss);
    if (bytes > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
        throw std::runtime_error("peak resident memory exceeds the event schema limit");
    }
    // Darwin reports ru_maxrss in bytes. Other platforms use different units.
    return static_cast<std::int64_t>(bytes);
}

void releaseCameraResources(Camera &camera) {
    camera.image = Image {};
    std::unordered_map<int, Image> {}.swap(camera.imagePyramids);
    std::unordered_map<int, MTensor> {}.swap(camera.mtensorImageCache);
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
        fields["schema_version"] = 2;
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

constexpr int maximumPreparseArgumentCount = 4096;
constexpr std::size_t maximumPreparseTokenBytes = 128;

struct PreparseIntent {
    bool suppressParseDiagnostics = false;
};

std::optional<std::string_view> boundedPreparseToken(const char *argument) {
    if (argument == nullptr) return std::nullopt;
    const std::size_t length = ::strnlen(
        argument,
        maximumPreparseTokenBytes + 1
    );
    if (length > maximumPreparseTokenBytes) return std::nullopt;
    return std::string_view(argument, length);
}

bool reservesStandardEventDescriptor(std::string_view value) {
    int descriptor = -1;
    if (!CLI::detail::lexical_cast(std::string(value), descriptor)) {
        return false;
    }
    return descriptor == STDOUT_FILENO || descriptor == STDERR_FILENO;
}

PreparseIntent scanPreparseIntent(int argc, char *argv[]) {
    if (argc < 0 || argc > maximumPreparseArgumentCount || argv == nullptr) {
        return {true};
    }

    PreparseIntent intent;
    for (int index = 1; index < argc; ++index) {
        if (argv[index] == nullptr) return {true};
        const auto token = boundedPreparseToken(argv[index]);
        if (!token.has_value()) return {true};
        if (*token == "--") break;
        if (*token == "--isolate") {
            intent.suppressParseDiagnostics = true;
            continue;
        }
        constexpr std::string_view eventsOption = "--events-fd";
        if (token->size() > eventsOption.size() &&
            token->substr(0, eventsOption.size()) == eventsOption &&
            (*token)[eventsOption.size()] == '=') {
            if (reservesStandardEventDescriptor(
                    token->substr(eventsOption.size() + 1)
                )) {
                intent.suppressParseDiagnostics = true;
            }
            continue;
        }
        if (*token != eventsOption || index + 1 >= argc) continue;
        if (argv[index + 1] == nullptr) return {true};
        const auto value = boundedPreparseToken(argv[index + 1]);
        if (!value.has_value()) return {true};
        if (reservesStandardEventDescriptor(*value)) {
            intent.suppressParseDiagnostics = true;
        }
    }
    return intent;
}

void emitCapturedParseDiagnostics(
    const std::string &standardOutput,
    const std::string &standardError
) {
    std::cout << standardOutput << std::flush;
    std::cerr << standardError << std::flush;
}

using BoundEventFileIdentity =
    std::pair<std::uint64_t, std::uint64_t>;

std::optional<BoundEventFileIdentity> boundEventFileIdentity(int descriptor) {
    if (descriptor < 0) return std::nullopt;
    struct stat status {};
    if (::fstat(descriptor, &status) != 0) {
        throw std::runtime_error(
            "cannot bind event file descriptor: " +
            std::string(std::strerror(errno))
        );
    }
    if (!S_ISREG(status.st_mode)) return std::nullopt;
    return BoundEventFileIdentity {
        static_cast<std::uint64_t>(status.st_dev),
        static_cast<std::uint64_t>(status.st_ino),
    };
}

void rejectEventDescriptorAliases(
    const std::optional<BoundEventFileIdentity> &eventIdentity,
    const std::vector<fs::path> &protectedPaths
) {
    if (!eventIdentity.has_value()) return;
    for (const fs::path &path : protectedPaths) {
        if (path.empty()) continue;
        struct stat status {};
        if (::lstat(path.c_str(), &status) != 0) {
            if (errno == ENOENT) continue;
            throw std::runtime_error(
                "cannot inspect protected isolation path before event emission"
            );
        }
        if (static_cast<std::uint64_t>(status.st_dev) ==
                eventIdentity->first &&
            static_cast<std::uint64_t>(status.st_ino) ==
                eventIdentity->second) {
            throw std::runtime_error(
                "event file descriptor must not alias an isolation artifact"
            );
        }
    }
}

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

constexpr std::string_view msplatSourceCommit =
    "106499b0a53f82b0c92d013b0861fbebd341b17e";

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

struct SceneBounds {
    std::array<double, 3> center {};
    double radius = 0;
};

struct GaussianBoundsSample {
    std::array<double, 3> position {};
    double largestPhysicalScale = 0;
    double alpha = 0;
};

double stableSigmoid(double value) {
    if (value >= 0) {
        return 1.0 / (1.0 + std::exp(-value));
    }
    const double exponential = std::exp(value);
    return exponential / (1.0 + exponential);
}

std::optional<GaussianBoundsSample> makeBoundsSample(
    const float *position,
    const float *logScales,
    float opacityLogit
) {
    if (!std::isfinite(opacityLogit)) return std::nullopt;
    GaussianBoundsSample sample;
    for (std::size_t axis = 0; axis < 3; ++axis) {
        if (!std::isfinite(position[axis]) || !std::isfinite(logScales[axis])) {
            return std::nullopt;
        }
        sample.position[axis] = position[axis];
        const double physicalScale = std::exp(static_cast<double>(logScales[axis]));
        if (!std::isfinite(physicalScale) || physicalScale <= 0 ||
            physicalScale > std::numeric_limits<float>::max()) {
            return std::nullopt;
        }
        sample.largestPhysicalScale = std::max(
            sample.largestPhysicalScale,
            physicalScale
        );
    }
    sample.alpha = stableSigmoid(opacityLogit);
    if (!std::isfinite(sample.alpha)) return std::nullopt;
    return sample;
}

double sortedMedian(std::vector<double> values) {
    if (values.empty()) throw std::runtime_error("scene bounds have no samples");
    std::sort(values.begin(), values.end());
    const std::size_t middle = values.size() / 2;
    if ((values.size() & 1U) != 0) return values[middle];
    return values[middle - 1] + (values[middle] - values[middle - 1]) * 0.5;
}

SceneBounds robustSceneBounds(const std::vector<GaussianBoundsSample> &finiteSamples) {
    if (finiteSamples.empty()) {
        throw std::runtime_error("final Gaussians contain no finite scene-bounds samples");
    }

    std::vector<GaussianBoundsSample> opaqueSamples;
    opaqueSamples.reserve(finiteSamples.size());
    for (const auto &sample : finiteSamples) {
        if (sample.alpha >= 0.01) opaqueSamples.push_back(sample);
    }
    // A handful of surviving alpha values cannot define robust scene scale. Require
    // at least eight samples (or every sample in a tiny fixture) and one per thousand
    // for large models before excluding low-alpha Gaussians.
    const std::size_t minimumOpaqueCount = std::min(
        finiteSamples.size(),
        std::max<std::size_t>(
            8,
            (finiteSamples.size() + 999) / 1000
        )
    );
    const auto &samples = opaqueSamples.size() >= minimumOpaqueCount
        ? opaqueSamples
        : finiteSamples;

    SceneBounds bounds;
    for (std::size_t axis = 0; axis < 3; ++axis) {
        std::vector<double> coordinates;
        coordinates.reserve(samples.size());
        for (const auto &sample : samples) coordinates.push_back(sample.position[axis]);
        bounds.center[axis] = sortedMedian(std::move(coordinates));
    }

    std::vector<double> extents;
    extents.reserve(samples.size());
    for (const auto &sample : samples) {
        const double x = sample.position[0] - bounds.center[0];
        const double y = sample.position[1] - bounds.center[1];
        const double z = sample.position[2] - bounds.center[2];
        const double distance = std::hypot(std::hypot(x, y), z);
        const double extent = distance + 3.0 * sample.largestPhysicalScale;
        if (!std::isfinite(extent) || extent <= 0) continue;
        extents.push_back(extent);
    }
    if (extents.empty()) {
        throw std::runtime_error("final Gaussians have no finite positive extents");
    }
    std::sort(extents.begin(), extents.end());
    // Deterministic nearest-rank p99.5: ceil(0.995 * N) - 1.
    const std::size_t rank = std::max<std::size_t>(
        1,
        (995 * extents.size() + 999) / 1000
    );
    bounds.radius = extents[std::min(rank, extents.size()) - 1];
    if (!std::isfinite(bounds.center[0]) || !std::isfinite(bounds.center[1]) ||
        !std::isfinite(bounds.center[2]) || !std::isfinite(bounds.radius) ||
        bounds.radius <= 0) {
        throw std::runtime_error("computed scene bounds are not finite and positive");
    }
    return bounds;
}

SceneBounds robustSceneBounds(const Model &model) {
    if (model.num_active <= 0 || model.means.numel() < model.num_active * 3LL ||
        model.scales.numel() < model.num_active * 3LL ||
        model.opacities.numel() < model.num_active) {
        throw std::runtime_error("final Gaussian tensors are incomplete");
    }
    msplat_gpu_sync();
    const float *means = model.means.data<float>();
    const float *scales = model.scales.data<float>();
    const float *opacities = model.opacities.data<float>();
    if (model.keepCrs && (!std::isfinite(model.scale) || model.scale <= 0 ||
        !std::isfinite(model.translation[0]) || !std::isfinite(model.translation[1]) ||
        !std::isfinite(model.translation[2]))) {
        throw std::runtime_error("final Gaussian coordinate transform is invalid");
    }
    std::vector<GaussianBoundsSample> samples;
    samples.reserve(static_cast<std::size_t>(model.num_active));
    for (int index = 0; index < model.num_active; ++index) {
        auto sample = makeBoundsSample(
            means + index * 3,
            scales + index * 3,
            opacities[index]
        );
        if (sample) {
            if (model.keepCrs) {
                bool outputTransformIsFinite = true;
                for (std::size_t axis = 0; axis < 3; ++axis) {
                    sample->position[axis] =
                        sample->position[axis] / model.scale + model.translation[axis];
                    outputTransformIsFinite = outputTransformIsFinite &&
                        std::isfinite(sample->position[axis]) &&
                        std::abs(sample->position[axis]) <= std::numeric_limits<float>::max();
                }
                sample->largestPhysicalScale /= model.scale;
                outputTransformIsFinite = outputTransformIsFinite &&
                    std::isfinite(sample->largestPhysicalScale) &&
                    sample->largestPhysicalScale > 0 &&
                    sample->largestPhysicalScale <= std::numeric_limits<float>::max();
                if (!outputTransformIsFinite) continue;
            }
            samples.push_back(*sample);
        }
    }
    return robustSceneBounds(samples);
}

void verifySceneBoundsSelfCheck() {
    auto requireNear = [](double actual, double expected, const char *label) {
        if (!std::isfinite(actual) || std::abs(actual - expected) > 1e-9) {
            throw std::runtime_error(std::string("scene-bounds self-check failed: ") + label);
        }
    };
    auto sample = [](double x, double y, double z, double scale, double alpha) {
        return GaussianBoundsSample {{x, y, z}, scale, alpha};
    };

    std::vector<GaussianBoundsSample> outlierFixture(
        199,
        sample(0, 0, 0, 1, 0.5)
    );
    outlierFixture.push_back(sample(10'000, 0, 0, 1, 0.5));
    const SceneBounds outlierBounds = robustSceneBounds(outlierFixture);
    requireNear(outlierBounds.center[0], 0, "coordinate median");
    requireNear(outlierBounds.radius, 3, "p99.5 outlier rejection");

    std::vector<GaussianBoundsSample> opacityFixture(
        100,
        sample(1'000, 0, 0, 1, 0.001)
    );
    for (int index = 0; index < 8; ++index) {
        opacityFixture.push_back(sample(2, -1, 4, 2, 0.5));
    }
    const SceneBounds opacityBounds = robustSceneBounds(opacityFixture);
    requireNear(opacityBounds.center[0], 2, "alpha-qualified center");
    requireNear(opacityBounds.radius, 6, "alpha-qualified radius");

    const float anisotropicPosition[] = {0, 0, 0};
    const float anisotropicLogScales[] = {
        0,
        static_cast<float>(std::log(4.0)),
        static_cast<float>(std::log(2.0)),
    };
    const auto anisotropic = makeBoundsSample(
        anisotropicPosition,
        anisotropicLogScales,
        0
    );
    if (!anisotropic) throw std::runtime_error("scene-bounds anisotropic fixture was rejected");
    const SceneBounds anisotropicBounds = robustSceneBounds({*anisotropic});
    if (std::abs(anisotropicBounds.radius - 12.0) > 1e-5) {
        throw std::runtime_error("scene-bounds self-check failed: stored log-scale conversion");
    }

    const float invalidPosition[] = {
        std::numeric_limits<float>::quiet_NaN(), 0, 0,
    };
    const float validLogScales[] = {0, 0, 0};
    if (makeBoundsSample(invalidPosition, validLogScales, 0)) {
        throw std::runtime_error("scene-bounds self-check failed: non-finite position accepted");
    }
    const float invalidLogScales[] = {
        0, std::numeric_limits<float>::infinity(), 0,
    };
    const float overflowingLogScales[] = {0, 100, 0};
    if (makeBoundsSample(anisotropicPosition, invalidLogScales, 0) ||
        makeBoundsSample(anisotropicPosition, overflowingLogScales, 0) ||
        makeBoundsSample(
            anisotropicPosition,
            validLogScales,
            std::numeric_limits<float>::quiet_NaN()
        )) {
        throw std::runtime_error("scene-bounds self-check failed: non-finite parameter accepted");
    }

    std::vector<GaussianBoundsSample> lowAlphaFallback;
    for (int index = 0; index < 7; ++index) {
        lowAlphaFallback.push_back(sample(5, 6, 7, 1, 0.5));
    }
    lowAlphaFallback.push_back(sample(5, 6, 7, 1, 0.001));
    const SceneBounds fallbackBounds = robustSceneBounds(lowAlphaFallback);
    requireNear(fallbackBounds.center[1], 6, "low-alpha deterministic fallback");
    requireNear(fallbackBounds.radius, 3, "low-alpha fallback radius");

    const SceneBounds allLowAlphaBounds = robustSceneBounds({
        sample(-2, 3, 1, 0.5, 0.001),
        sample(-2, 3, 1, 0.5, 0.001),
    });
    requireNear(allLowAlphaBounds.center[2], 1, "all-low-alpha center fallback");
    requireNear(allLowAlphaBounds.radius, 1.5, "all-low-alpha radius fallback");
}

struct TrainingIdentity {
    std::string inputDigest;
    std::string geometryDigest;
};

struct TrainerCheckpointState {
    int iteration = 0;
    int lastImprovementIteration = 0;
    std::vector<double> bestCameraLosses;
    std::optional<double> latestLoss;
    int latestLossIteration = 0;
    double elapsedSeconds = 0;
    std::uint64_t rasterFallbackCount = 0;
    std::uint64_t droppedIntersectionCount = 0;
    double rasterExactFallbackElapsedSeconds = 0;
    std::uint64_t rasterExactBufferGrowthCount = 0;
    std::uint64_t rasterExactBufferBytesAdded = 0;
    double rasterReplayElapsedSeconds = 0;
    std::uint64_t rasterPeakExactIntersectionCapacity = 0;
};

struct CheckpointReceipt {
    int iteration;
    std::string generation;
    std::string payloadDigest;
    std::uintmax_t payloadBytes;
};

constexpr std::uintmax_t maximumCheckpointManifestBytes = 4 * 1024 * 1024;
constexpr std::uintmax_t maximumCheckpointPayloadBytes = 32ULL * 1024 * 1024 * 1024;

bool rasterRecoveryMetricsAreValid(
    std::uint64_t fallbackCount,
    double exactFallbackElapsedSeconds,
    std::uint64_t exactBufferGrowthCount,
    std::uint64_t exactBufferBytesAdded,
    double replayElapsedSeconds,
    std::uint64_t peakExactIntersectionCapacity,
    std::uint64_t memoryBudgetBytes
) {
    if (!std::isfinite(exactFallbackElapsedSeconds) ||
        !std::isfinite(replayElapsedSeconds) ||
        exactFallbackElapsedSeconds < 0 || replayElapsedSeconds < 0 ||
        exactBufferGrowthCount > fallbackCount || memoryBudgetBytes == 0 ||
        peakExactIntersectionCapacity > std::numeric_limits<std::uint32_t>::max()) {
        return false;
    }
    if (fallbackCount == 0) {
        return exactFallbackElapsedSeconds == 0 && exactBufferGrowthCount == 0 &&
            exactBufferBytesAdded == 0 && replayElapsedSeconds == 0 &&
            peakExactIntersectionCapacity == 0;
    }
    return exactFallbackElapsedSeconds > 0 && exactBufferGrowthCount > 0 &&
        exactBufferBytesAdded > 0 && replayElapsedSeconds > 0 &&
        peakExactIntersectionCapacity > 2048 &&
        1 + ((exactBufferBytesAdded - 1) / memoryBudgetBytes) <= exactBufferGrowthCount;
}

void throwSystemError(const std::string &operation, const fs::path &path);
void requirePlainDirectory(const fs::path &path);
void syncDirectory(const fs::path &path);

class Sha256Accumulator {
public:
    Sha256Accumulator() {
        if (CC_SHA256_Init(&context_) != 1) {
            throw std::runtime_error("cannot initialize SHA-256");
        }
    }

    void update(const void *bytes, std::size_t count) {
        const auto *cursor = static_cast<const unsigned char *>(bytes);
        while (count > 0) {
            const CC_LONG chunk = static_cast<CC_LONG>(std::min<std::size_t>(
                count, std::numeric_limits<CC_LONG>::max()
            ));
            if (CC_SHA256_Update(&context_, cursor, chunk) != 1) {
                throw std::runtime_error("cannot update SHA-256");
            }
            cursor += chunk;
            count -= chunk;
        }
    }

    void update(const std::string &value) {
        update(value.data(), value.size());
    }

    void updateInteger(std::uint64_t value) {
        unsigned char encoded[8];
        for (int index = 7; index >= 0; --index) {
            encoded[index] = static_cast<unsigned char>(value & 0xff);
            value >>= 8;
        }
        update(encoded, sizeof(encoded));
    }

    std::string finish() {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        if (CC_SHA256_Final(digest, &context_) != 1) {
            throw std::runtime_error("cannot finish SHA-256");
        }
        std::ostringstream result;
        result << std::hex << std::setfill('0');
        for (unsigned char byte : digest) {
            result << std::setw(2) << static_cast<unsigned int>(byte);
        }
        return result.str();
    }

private:
    CC_SHA256_CTX context_ {};
};

struct OpenFile {
    explicit OpenFile(const fs::path &path) {
        descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (descriptor < 0) throwSystemError("cannot open", path);
    }

    ~OpenFile() {
        if (descriptor >= 0) ::close(descriptor);
    }

    OpenFile(const OpenFile &) = delete;
    OpenFile &operator=(const OpenFile &) = delete;
    int descriptor = -1;
};

struct stat requireRegularFile(const fs::path &path, bool requireSingleLink = false) {
    struct stat metadata {};
    if (::lstat(path.c_str(), &metadata) != 0) throwSystemError("cannot inspect", path);
    if (!S_ISREG(metadata.st_mode) || (requireSingleLink && metadata.st_nlink != 1)) {
        throw std::runtime_error(
            requireSingleLink
                ? "expected an ordinary, single-link file: " + path.string()
                : "expected an ordinary file: " + path.string()
        );
    }
    return metadata;
}

bool sameStableFileMetadata(const struct stat &left, const struct stat &right) {
    return S_ISREG(left.st_mode) && S_ISREG(right.st_mode) &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
        left.st_nlink == right.st_nlink && left.st_size == right.st_size &&
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
        left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
        left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
        left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

void hashFileInto(
    Sha256Accumulator &digest,
    const fs::path &path,
    const std::string &relativeName,
    bool requireSingleLink = false,
    const std::optional<std::string> &expectedContentDigest = std::nullopt
) {
    const struct stat pathMetadata = requireRegularFile(path, requireSingleLink);
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0) throwSystemError("cannot inspect", path);
    if (!sameStableFileMetadata(pathMetadata, openedMetadata)) {
        throw std::runtime_error("file changed while opening: " + path.string());
    }

    digest.updateInteger(relativeName.size());
    digest.update(relativeName);
    digest.updateInteger(static_cast<std::uint64_t>(openedMetadata.st_size));
    std::array<unsigned char, 1024 * 1024> buffer {};
    std::uint64_t consumed = 0;
    std::optional<Sha256Accumulator> contentDigest;
    if (expectedContentDigest) contentDigest.emplace();
    while (true) {
        const ssize_t count = ::read(file.descriptor, buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throwSystemError("cannot read", path);
        if (count == 0) break;
        digest.update(buffer.data(), static_cast<std::size_t>(count));
        if (contentDigest) contentDigest->update(buffer.data(), static_cast<std::size_t>(count));
        consumed += static_cast<std::uint64_t>(count);
    }
    if (consumed != static_cast<std::uint64_t>(openedMetadata.st_size)) {
        throw std::runtime_error("file size changed while hashing: " + path.string());
    }
    struct stat finalOpenedMetadata {};
    struct stat finalPathMetadata {};
    if (::fstat(file.descriptor, &finalOpenedMetadata) != 0 ||
        ::lstat(path.c_str(), &finalPathMetadata) != 0 ||
        !sameStableFileMetadata(openedMetadata, finalOpenedMetadata) ||
        !sameStableFileMetadata(openedMetadata, finalPathMetadata)) {
        throw std::runtime_error("file changed while hashing: " + path.string());
    }
    if (contentDigest && contentDigest->finish() != *expectedContentDigest) {
        throw std::runtime_error("orientation file changed after validation");
    }
}

std::pair<std::string, std::uintmax_t> hashFileContent(
    const fs::path &path,
    bool requireSingleLink = false
) {
    const struct stat pathMetadata = requireRegularFile(path, requireSingleLink);
    if (pathMetadata.st_size < 0) {
        throw std::runtime_error("file has an invalid size: " + path.string());
    }
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0) throwSystemError("cannot inspect", path);
    if (!S_ISREG(openedMetadata.st_mode) || openedMetadata.st_dev != pathMetadata.st_dev ||
        openedMetadata.st_ino != pathMetadata.st_ino || openedMetadata.st_size != pathMetadata.st_size) {
        throw std::runtime_error("file changed while opening: " + path.string());
    }

    Sha256Accumulator digest;
    std::array<unsigned char, 1024 * 1024> buffer {};
    std::uintmax_t consumed = 0;
    while (true) {
        const ssize_t count = ::read(file.descriptor, buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throwSystemError("cannot read", path);
        if (count == 0) break;
        digest.update(buffer.data(), static_cast<std::size_t>(count));
        consumed += static_cast<std::uintmax_t>(count);
    }
    if (consumed != static_cast<std::uintmax_t>(openedMetadata.st_size)) {
        throw std::runtime_error("file size changed while hashing: " + path.string());
    }
    return {digest.finish(), consumed};
}

std::string digestFiles(
    const fs::path &root,
    const std::vector<std::string> &names,
    bool requireSingleLink = false
) {
    Sha256Accumulator digest;
    digest.update("EasySplat file digest v1");
    for (const std::string &name : names) {
        hashFileInto(digest, root / name, name, requireSingleLink);
    }
    return digest.finish();
}

bool isSupportedTrainingImageName(const std::string &name) {
    if (name.empty() || name.front() == '.') return false;
    std::string extension = fs::path(name).extension().string();
    for (char &character : extension) {
        if (character >= 'A' && character <= 'Z') {
            character = static_cast<char>(character - 'A' + 'a');
        }
    }
    return extension == ".jpg" || extension == ".jpeg" || extension == ".png";
}

TrainingIdentity computeTrainingIdentity(
    const fs::path &dataset,
    const std::string &orientationContentDigest
) {
    const fs::path images = dataset / "images";
    const fs::path sparse = dataset / "sparse" / "0";
    if (!fs::is_directory(images) || !fs::is_directory(sparse)) {
        throw std::runtime_error("dataset must contain images and sparse/0 directories");
    }

    std::vector<std::string> imageNames;
    for (const fs::directory_entry &entry : fs::directory_iterator(images)) {
        imageNames.push_back(entry.path().filename().string());
    }
    std::sort(imageNames.begin(), imageNames.end());
    if (imageNames.empty() || std::adjacent_find(imageNames.begin(), imageNames.end()) != imageNames.end()) {
        throw std::runtime_error("dataset image set is empty or ambiguous");
    }
    for (const std::string &name : imageNames) {
        if (!isSupportedTrainingImageName(name)) {
            throw std::runtime_error("unsupported entry in dataset images: " + name);
        }
        (void)requireRegularFile(images / name, true);
    }

    Sha256Accumulator geometryDigest;
    geometryDigest.update("EasySplat file digest v1");
    hashFileInto(geometryDigest, sparse / "cameras.bin", "cameras.bin", true);
    hashFileInto(geometryDigest, sparse / "images.bin", "images.bin", true);
    hashFileInto(geometryDigest, sparse / "points3D.bin", "points3D.bin", true);
    hashFileInto(
        geometryDigest,
        sparse / "easysplat_orientation.json",
        "easysplat_orientation.json",
        true,
        orientationContentDigest
    );

    return TrainingIdentity {digestFiles(images, imageNames, true), geometryDigest.finish()};
}

void copyAuthenticatedFile(
    const fs::path &source,
    const fs::path &destination
) {
    const struct stat namedBefore = requireRegularFile(source, true);
    OpenFile input(source);
    struct stat openedBefore {};
    if (::fstat(input.descriptor, &openedBefore) != 0 ||
        !sameStableFileMetadata(namedBefore, openedBefore)) {
        throw std::runtime_error(
            "dataset input changed while opening snapshot source: " +
            source.string()
        );
    }
    int output = ::open(
        destination.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (output < 0) {
        throwSystemError("cannot create authenticated dataset snapshot", destination);
    }
    bool created = true;
    try {
        std::array<std::uint8_t, 1024 * 1024> buffer {};
        std::uint64_t consumed = 0;
        while (true) {
            if (cancellationSignal != 0) {
                throw easysplat::isolation::CancellationError();
            }
            const ssize_t count = ::read(
                input.descriptor,
                buffer.data(),
                buffer.size()
            );
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) {
                throwSystemError("cannot read authenticated dataset input", source);
            }
            if (count == 0) break;
            std::size_t written = 0;
            while (written < static_cast<std::size_t>(count)) {
                const ssize_t amount = ::write(
                    output,
                    buffer.data() + written,
                    static_cast<std::size_t>(count) - written
                );
                if (amount < 0 && errno == EINTR) continue;
                if (amount <= 0) {
                    throwSystemError(
                        "cannot write authenticated dataset snapshot",
                        destination
                    );
                }
                written += static_cast<std::size_t>(amount);
            }
            consumed += static_cast<std::uint64_t>(count);
        }
        if (openedBefore.st_size < 0 ||
            consumed != static_cast<std::uint64_t>(openedBefore.st_size)) {
            throw std::runtime_error(
                "dataset input changed while copying snapshot source: " +
                source.string()
            );
        }
        struct stat openedAfter {};
        struct stat namedAfter {};
        if (::fstat(input.descriptor, &openedAfter) != 0 ||
            ::lstat(source.c_str(), &namedAfter) != 0 ||
            !sameStableFileMetadata(openedBefore, openedAfter) ||
            !sameStableFileMetadata(openedBefore, namedAfter)) {
            throw std::runtime_error(
                "dataset input changed while copying snapshot source: " +
                source.string()
            );
        }
        if (::fsync(output) != 0) {
            throwSystemError("cannot sync authenticated dataset snapshot", destination);
        }
        if (::close(output) != 0) {
            output = -1;
            throwSystemError("cannot close authenticated dataset snapshot", destination);
        }
        output = -1;
        created = false;
    } catch (...) {
        if (output >= 0) (void)::close(output);
        if (created) (void)::unlink(destination.c_str());
        throw;
    }
}

class ScopedDescriptor {
public:
    explicit ScopedDescriptor(int descriptor = -1) : descriptor_(descriptor) {}

    ~ScopedDescriptor() {
        if (descriptor_ >= 0) (void)::close(descriptor_);
    }

    ScopedDescriptor(const ScopedDescriptor &) = delete;
    ScopedDescriptor &operator=(const ScopedDescriptor &) = delete;

    int get() const { return descriptor_; }

private:
    int descriptor_;
};

bool sameIsolationSnapshotEntry(
    const struct stat &expected,
    const struct stat &actual
) {
    return (expected.st_mode & S_IFMT) == (actual.st_mode & S_IFMT) &&
        expected.st_dev == actual.st_dev &&
        expected.st_ino == actual.st_ino &&
        expected.st_uid == actual.st_uid;
}

[[noreturn]] void throwIsolationSnapshotCleanupError(
    const std::string &operation
) {
    const int savedError = errno;
    throw std::runtime_error(
        operation + ": " + std::string(std::strerror(savedError))
    );
}

void restoreIsolationSnapshotClaim(
    int parentDescriptor,
    const std::string &claimedName,
    const std::string &originalName
) noexcept {
    (void)::renameatx_np(
        parentDescriptor,
        claimedName.c_str(),
        parentDescriptor,
        originalName.c_str(),
        RENAME_EXCL
    );
}

std::string claimIsolationSnapshotEntry(
    int parentDescriptor,
    const std::string &originalName,
    const struct stat &expected,
    std::string_view claimPrefix
) {
    const auto token = static_cast<unsigned long long>(
        std::chrono::steady_clock::now().time_since_epoch().count()
    );
    for (unsigned int attempt = 0; attempt < 128; ++attempt) {
        const std::string claimedName =
            std::string(claimPrefix) + "." +
            std::to_string(static_cast<long long>(::getpid())) + "." +
            std::to_string(token) + "." +
            std::to_string(attempt);
        if (::renameatx_np(
                parentDescriptor,
                originalName.c_str(),
                parentDescriptor,
                claimedName.c_str(),
                RENAME_EXCL
            ) != 0) {
            if (errno == EEXIST) continue;
            throwIsolationSnapshotCleanupError(
                "cannot claim private isolation snapshot entry"
            );
        }

        struct stat claimedMetadata {};
        if (::fstatat(
                parentDescriptor,
                claimedName.c_str(),
                &claimedMetadata,
                AT_SYMLINK_NOFOLLOW
            ) != 0 ||
            !sameIsolationSnapshotEntry(expected, claimedMetadata)) {
            restoreIsolationSnapshotClaim(
                parentDescriptor,
                claimedName,
                originalName
            );
            throw std::runtime_error(
                "private isolation snapshot entry changed while claiming it"
            );
        }
        return claimedName;
    }
    throw std::runtime_error(
        "cannot reserve a private isolation snapshot cleanup name"
    );
}

std::vector<std::string> isolationSnapshotEntryNames(int directoryDescriptor) {
    const int duplicate = ::fcntl(
        directoryDescriptor,
        F_DUPFD_CLOEXEC,
        0
    );
    if (duplicate < 0) {
        throwIsolationSnapshotCleanupError(
            "cannot duplicate private isolation snapshot directory"
        );
    }
    DIR *directory = ::fdopendir(duplicate);
    if (directory == nullptr) {
        const int savedError = errno;
        (void)::close(duplicate);
        errno = savedError;
        throwIsolationSnapshotCleanupError(
            "cannot enumerate private isolation snapshot directory"
        );
    }

    std::vector<std::string> names;
    errno = 0;
    while (dirent *entry = ::readdir(directory)) {
        const std::string name(entry->d_name);
        if (name != "." && name != "..") names.push_back(name);
        errno = 0;
    }
    const int enumerationError = errno;
    const int closeStatus = ::closedir(directory);
    if (enumerationError != 0) {
        errno = enumerationError;
        throwIsolationSnapshotCleanupError(
            "cannot enumerate private isolation snapshot directory"
        );
    }
    if (closeStatus != 0) {
        throwIsolationSnapshotCleanupError(
            "cannot close private isolation snapshot directory"
        );
    }
    std::sort(names.begin(), names.end());
    return names;
}

void removeIsolationSnapshotContentsAt(int directoryDescriptor) {
    for (const std::string &name :
         isolationSnapshotEntryNames(directoryDescriptor)) {
        struct stat expected {};
        if (::fstatat(
                directoryDescriptor,
                name.c_str(),
                &expected,
                AT_SYMLINK_NOFOLLOW
            ) != 0) {
            throwIsolationSnapshotCleanupError(
                "cannot inspect private isolation snapshot entry"
            );
        }
        const std::string claimedName = claimIsolationSnapshotEntry(
            directoryDescriptor,
            name,
            expected,
            ".easysplat-isolation-entry"
        );
        bool removed = false;
        try {
            if (S_ISDIR(expected.st_mode)) {
                {
                    ScopedDescriptor child(::openat(
                        directoryDescriptor,
                        claimedName.c_str(),
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    ));
                    if (child.get() < 0) {
                        throwIsolationSnapshotCleanupError(
                            "cannot open private isolation snapshot directory"
                        );
                    }
                    struct stat opened {};
                    if (::fstat(child.get(), &opened) != 0 ||
                        !sameIsolationSnapshotEntry(expected, opened)) {
                        throw std::runtime_error(
                            "private isolation snapshot directory changed while opening it"
                        );
                    }
                    removeIsolationSnapshotContentsAt(child.get());
                    struct stat openedAfter {};
                    struct stat namedAfter {};
                    if (::fstat(child.get(), &openedAfter) != 0 ||
                        ::fstatat(
                            directoryDescriptor,
                            claimedName.c_str(),
                            &namedAfter,
                            AT_SYMLINK_NOFOLLOW
                        ) != 0 ||
                        !sameIsolationSnapshotEntry(expected, openedAfter) ||
                        !sameIsolationSnapshotEntry(expected, namedAfter)) {
                        throw std::runtime_error(
                            "private isolation snapshot directory changed during cleanup"
                        );
                    }
                }
                if (::unlinkat(
                        directoryDescriptor,
                        claimedName.c_str(),
                        AT_REMOVEDIR
                    ) != 0) {
                    throwIsolationSnapshotCleanupError(
                        "cannot remove private isolation snapshot directory"
                    );
                }
            } else if (S_ISREG(expected.st_mode)) {
                {
                    ScopedDescriptor file(::openat(
                        directoryDescriptor,
                        claimedName.c_str(),
                        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                    ));
                    if (file.get() < 0) {
                        throwIsolationSnapshotCleanupError(
                            "cannot open private isolation snapshot file"
                        );
                    }
                    struct stat opened {};
                    struct stat namedAfter {};
                    if (::fstat(file.get(), &opened) != 0 ||
                        ::fstatat(
                            directoryDescriptor,
                            claimedName.c_str(),
                            &namedAfter,
                            AT_SYMLINK_NOFOLLOW
                        ) != 0 ||
                        !sameIsolationSnapshotEntry(expected, opened) ||
                        !sameIsolationSnapshotEntry(expected, namedAfter)) {
                        throw std::runtime_error(
                            "private isolation snapshot file changed during cleanup"
                        );
                    }
                }
                if (::unlinkat(
                        directoryDescriptor,
                        claimedName.c_str(),
                        0
                    ) != 0) {
                    throwIsolationSnapshotCleanupError(
                        "cannot remove private isolation snapshot file"
                    );
                }
            } else if (S_ISLNK(expected.st_mode)) {
                if (::unlinkat(
                        directoryDescriptor,
                        claimedName.c_str(),
                        0
                    ) != 0) {
                    throwIsolationSnapshotCleanupError(
                        "cannot remove private isolation snapshot link"
                    );
                }
            } else {
                throw std::runtime_error(
                    "unsupported entry in private isolation snapshot"
                );
            }
            removed = true;
        } catch (...) {
            if (!removed) {
                restoreIsolationSnapshotClaim(
                    directoryDescriptor,
                    claimedName,
                    name
                );
            }
            throw;
        }
    }
    if (::fsync(directoryDescriptor) != 0) {
        throwIsolationSnapshotCleanupError(
            "cannot sync private isolation snapshot directory"
        );
    }
}

std::string claimIsolationSnapshotRoot(
    int parentDescriptor,
    const std::string &rootName,
    const struct stat &expected
) {
    return claimIsolationSnapshotEntry(
        parentDescriptor,
        rootName,
        expected,
        ".easysplat-isolation-cleanup"
    );
}

class IsolationDatasetSnapshot {
public:
    explicit IsolationDatasetSnapshot(const fs::path &dataset) {
        std::string pattern = (
            fs::temp_directory_path() /
            ("easysplat-isolation-dataset." +
             std::to_string(static_cast<long long>(::getpid())) +
             ".XXXXXX")
        ).string();
        std::vector<char> mutablePattern(pattern.begin(), pattern.end());
        mutablePattern.push_back('\0');
        char *created = ::mkdtemp(mutablePattern.data());
        if (created == nullptr) {
            throwSystemError(
                "cannot create private isolation dataset snapshot",
                fs::temp_directory_path()
            );
        }
        root_ = fs::path(created);
        try {
            if (::chmod(root_.c_str(), 0700) != 0) {
                throwSystemError(
                    "cannot protect private isolation dataset snapshot",
                    root_
                );
            }
            struct stat rootStatus {};
            if (::lstat(root_.c_str(), &rootStatus) != 0 ||
                !S_ISDIR(rootStatus.st_mode) ||
                rootStatus.st_uid != ::getuid() ||
                rootStatus.st_nlink < 2) {
                throw std::runtime_error(
                    "private isolation dataset snapshot identity is invalid"
                );
            }
            rootDevice_ = static_cast<std::uint64_t>(rootStatus.st_dev);
            rootInode_ = static_cast<std::uint64_t>(rootStatus.st_ino);
            fs::create_directories(sparsePath());
            fs::create_directory(imagesPath());
            if (::chmod((root_ / "sparse").c_str(), 0700) != 0 ||
                ::chmod(sparsePath().c_str(), 0700) != 0 ||
                ::chmod(imagesPath().c_str(), 0700) != 0) {
                throwSystemError(
                    "cannot protect isolation dataset snapshot directories",
                    root_
                );
            }

            const fs::path sourceSparse = dataset / "sparse" / "0";
            for (const char *name : {
                     "cameras.bin",
                     "images.bin",
                     "points3D.bin",
                     "easysplat_orientation.json",
                 }) {
                copyAuthenticatedFile(
                    sourceSparse / name,
                    sparsePath() / name
                );
            }

            std::vector<std::string> imageNames;
            for (const fs::directory_entry &entry :
                 fs::directory_iterator(dataset / "images")) {
                imageNames.push_back(entry.path().filename().string());
            }
            std::sort(imageNames.begin(), imageNames.end());
            if (imageNames.empty() ||
                std::adjacent_find(imageNames.begin(), imageNames.end()) !=
                    imageNames.end()) {
                throw std::runtime_error(
                    "dataset image set is empty or ambiguous during snapshot"
                );
            }
            for (const std::string &name : imageNames) {
                if (!isSupportedTrainingImageName(name)) {
                    throw std::runtime_error(
                        "unsupported entry in dataset images: " + name
                    );
                }
                copyAuthenticatedFile(
                    dataset / "images" / name,
                    imagesPath() / name
                );
            }
            syncDirectory(sparsePath());
            syncDirectory(imagesPath());
            syncDirectory(root_ / "sparse");
            syncDirectory(root_);
        } catch (...) {
            removeSafely();
            throw;
        }
    }

    ~IsolationDatasetSnapshot() {
        removeSafely();
    }

    IsolationDatasetSnapshot(const IsolationDatasetSnapshot &) = delete;
    IsolationDatasetSnapshot &operator=(const IsolationDatasetSnapshot &) = delete;

    const fs::path &rootPath() const { return root_; }
    fs::path sparsePath() const { return root_ / "sparse" / "0"; }
    fs::path imagesPath() const { return root_ / "images"; }

    void verifySnapshotIdentity(
        const TrainingIdentity &expected,
        const std::string &orientationContentDigest
    ) const {
        verifyRootIdentity();
        const TrainingIdentity actual = computeTrainingIdentity(
            root_,
            orientationContentDigest
        );
        verifyRootIdentity();
        if (actual.inputDigest != expected.inputDigest ||
            actual.geometryDigest != expected.geometryDigest) {
            throw std::runtime_error(
                "private isolation dataset snapshot digest mismatch"
            );
        }
    }

    void verifyCameraResources(const InputData &inputData) const {
        verifyRootIdentity();
        const fs::path expectedParent = imagesPath().lexically_normal();
        for (const Camera &camera : inputData.cameras) {
            const fs::path path = fs::path(camera.filePath).lexically_normal();
            if (path.parent_path() != expectedParent) {
                throw std::runtime_error(
                    "COLMAP camera escaped the authenticated image snapshot"
                );
            }
            (void)requireRegularFile(path, true);
        }
        verifyRootIdentity();
    }

private:
    void verifyRootIdentity() const {
        struct stat status {};
        if (root_.empty() ||
            ::lstat(root_.c_str(), &status) != 0 ||
            !S_ISDIR(status.st_mode) ||
            static_cast<std::uint64_t>(status.st_dev) != rootDevice_ ||
            static_cast<std::uint64_t>(status.st_ino) != rootInode_ ||
            status.st_uid != ::getuid()) {
            throw std::runtime_error(
                "private isolation dataset snapshot identity changed"
            );
        }
    }

    void removeSafely() noexcept {
        if (root_.empty()) return;
        try {
            const fs::path parentPath = root_.parent_path();
            const std::string rootName = root_.filename().string();
            ScopedDescriptor parent(::open(
                parentPath.c_str(),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            ));
            if (parent.get() < 0 || rootName.empty()) {
                root_.clear();
                return;
            }

            struct stat expected {};
            if (::fstatat(
                    parent.get(),
                    rootName.c_str(),
                    &expected,
                    AT_SYMLINK_NOFOLLOW
                ) != 0 ||
                !S_ISDIR(expected.st_mode) ||
                static_cast<std::uint64_t>(expected.st_dev) != rootDevice_ ||
                static_cast<std::uint64_t>(expected.st_ino) != rootInode_ ||
                expected.st_uid != ::getuid()) {
                root_.clear();
                return;
            }

            const std::string claimedName = claimIsolationSnapshotRoot(
                parent.get(),
                rootName,
                expected
            );
            bool removed = false;
            try {
                {
                    ScopedDescriptor claimed(::openat(
                        parent.get(),
                        claimedName.c_str(),
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    ));
                    if (claimed.get() < 0) {
                        throwIsolationSnapshotCleanupError(
                            "cannot open claimed private isolation snapshot"
                        );
                    }
                    struct stat opened {};
                    if (::fstat(claimed.get(), &opened) != 0 ||
                        !sameIsolationSnapshotEntry(expected, opened)) {
                        throw std::runtime_error(
                            "claimed private isolation snapshot identity changed"
                        );
                    }
                    removeIsolationSnapshotContentsAt(claimed.get());
                    struct stat openedAfter {};
                    struct stat namedAfter {};
                    if (::fstat(claimed.get(), &openedAfter) != 0 ||
                        ::fstatat(
                            parent.get(),
                            claimedName.c_str(),
                            &namedAfter,
                            AT_SYMLINK_NOFOLLOW
                        ) != 0 ||
                        !sameIsolationSnapshotEntry(expected, openedAfter) ||
                        !sameIsolationSnapshotEntry(expected, namedAfter)) {
                        throw std::runtime_error(
                            "claimed private isolation snapshot changed during cleanup"
                        );
                    }
                }
                if (::unlinkat(
                        parent.get(),
                        claimedName.c_str(),
                        AT_REMOVEDIR
                    ) != 0) {
                    throwIsolationSnapshotCleanupError(
                        "cannot remove claimed private isolation snapshot"
                    );
                }
                if (::fsync(parent.get()) != 0) {
                    throwIsolationSnapshotCleanupError(
                        "cannot sync private isolation snapshot parent"
                    );
                }
                removed = true;
            } catch (...) {
                if (!removed) {
                    restoreIsolationSnapshotClaim(
                        parent.get(),
                        claimedName,
                        rootName
                    );
                }
                throw;
            }
        } catch (...) {
            // Cleanup is best-effort and must never escape the destructor. Any
            // identity uncertainty preserves the claimed tree or replacement.
        }
        root_.clear();
    }

    fs::path root_;
    std::uint64_t rootDevice_ = 0;
    std::uint64_t rootInode_ = 0;
};

std::pair<std::uint64_t, std::uint64_t> stableColmapRecordCount(
    const fs::path &path,
    std::uint64_t minimumRecordBytes
) {
    const struct stat pathMetadata = requireRegularFile(path, true);
    if (pathMetadata.st_size < 8) {
        throw std::runtime_error(
            "COLMAP binary header is truncated: " + path.string()
        );
    }
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0 ||
        !sameStableFileMetadata(pathMetadata, openedMetadata)) {
        throw std::runtime_error(
            "COLMAP binary changed while opening: " + path.string()
        );
    }
    std::uint64_t count = 0;
    std::size_t consumed = 0;
    while (consumed < sizeof(count)) {
        const ssize_t amount = ::pread(
            file.descriptor,
            reinterpret_cast<std::uint8_t *>(&count) + consumed,
            sizeof(count) - consumed,
            static_cast<off_t>(consumed)
        );
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) {
            throw std::runtime_error(
                "COLMAP binary header is truncated: " + path.string()
            );
        }
        consumed += static_cast<std::size_t>(amount);
    }
    struct stat finalOpenedMetadata {};
    struct stat finalPathMetadata {};
    if (::fstat(file.descriptor, &finalOpenedMetadata) != 0 ||
        ::lstat(path.c_str(), &finalPathMetadata) != 0 ||
        !sameStableFileMetadata(openedMetadata, finalOpenedMetadata) ||
        !sameStableFileMetadata(openedMetadata, finalPathMetadata)) {
        throw std::runtime_error(
            "COLMAP binary changed while reading its header: " +
            path.string()
        );
    }
    const std::uint64_t bytes =
        static_cast<std::uint64_t>(openedMetadata.st_size);
    if (count > (bytes - sizeof(count)) / minimumRecordBytes) {
        throw std::runtime_error(
            "COLMAP binary record count exceeds its file size: " +
            path.string()
        );
    }
    return {count, bytes};
}

void enforceIsolationColmapLoadBudget(
    const fs::path &sparse,
    std::uint64_t memoryBudgetBytes
) {
    const auto [cameraCount, cameraBytes] = stableColmapRecordCount(
        sparse / "cameras.bin",
        48
    );
    const auto [imageCount, imageBytes] = stableColmapRecordCount(
        sparse / "images.bin",
        73
    );
    const auto [pointCount, pointBytes] = stableColmapRecordCount(
        sparse / "points3D.bin",
        51
    );
    (void)cameraBytes;
    (void)pointBytes;
    constexpr std::uint64_t conservativeCameraBytes = 256;
    constexpr std::uint64_t conservativeImageBytes = 1024;
    constexpr std::uint64_t conservativePointBytes = 32;
    const std::array<std::pair<std::uint64_t, std::uint64_t>, 3>
        allocations = {{
            {cameraCount, conservativeCameraBytes},
            {imageCount, conservativeImageBytes},
            {pointCount, conservativePointBytes},
        }};
    std::uint64_t requiredBytes = 0;
    for (const auto &[count, bytesPerRecord] : allocations) {
        if (count >
            (std::numeric_limits<std::uint64_t>::max() - requiredBytes) /
                bytesPerRecord) {
            throw easysplat::isolation::MemoryLimitError(
                "COLMAP loader allocation exceeds the native range"
            );
        }
        requiredBytes += count * bytesPerRecord;
    }
    // The pinned COLMAP reader appends each image name one byte at a time.
    // Its vector allocation is covered above, but a malformed authenticated
    // file can otherwise hide an arbitrarily large string behind one record.
    // Two input bytes per file byte conservatively cover libc++ string growth.
    constexpr std::uint64_t imageParserBytesPerInputByte = 2;
    if (imageBytes >
        (std::numeric_limits<std::uint64_t>::max() - requiredBytes) /
            imageParserBytesPerInputByte) {
        throw easysplat::isolation::MemoryLimitError(
            "COLMAP image metadata exceeds the native range"
        );
    }
    requiredBytes += imageBytes * imageParserBytesPerInputByte;
    if (requiredBytes > memoryBudgetBytes) {
        throw easysplat::isolation::MemoryLimitError(
            "COLMAP loader allocation exceeds the isolation memory budget"
        );
    }
}

fs::path trainerExecutablePath() {
    std::uint32_t capacity = 0;
    if (_NSGetExecutablePath(nullptr, &capacity) != -1 || capacity == 0 || capacity > 1024 * 1024) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    std::vector<char> buffer(capacity);
    if (_NSGetExecutablePath(buffer.data(), &capacity) != 0) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    return fs::canonical(fs::path(buffer.data()));
}

std::string computeTrainerBuildDigest() {
    const fs::path executable = trainerExecutablePath();
    const fs::path directory = executable.parent_path();
    return digestFiles(
        directory,
        {executable.filename().string(), "default.metallib"}
    );
}

struct BenchmarkDecodeOutput {
    std::string sha256;
    std::uintmax_t bytes;
};

BenchmarkDecodeOutput writeRGB8Atomically(const fs::path &output, const Image &image) {
    if (image.width <= 0 || image.height <= 0 ||
        image.data.size() != static_cast<std::size_t>(image.width) *
            static_cast<std::size_t>(image.height) * 3) {
        throw std::runtime_error("decoded benchmark image has invalid dimensions");
    }
    const fs::path parent = output.parent_path().empty() ? fs::current_path() : output.parent_path();
    requirePlainDirectory(parent);
    const int parentDescriptor = ::open(
        parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (parentDescriptor < 0) throwSystemError("cannot open benchmark output directory", parent);

    std::string temporaryName;
    int outputDescriptor = -1;
    for (unsigned int attempt = 0; attempt < 100; ++attempt) {
        temporaryName = ".benchmark-decode." +
            std::to_string(static_cast<long long>(::getpid())) + "." +
            std::to_string(attempt);
        outputDescriptor = ::openat(
            parentDescriptor,
            temporaryName.c_str(),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600
        );
        if (outputDescriptor >= 0) break;
        if (errno != EEXIST) {
            const int savedErrno = errno;
            ::close(parentDescriptor);
            errno = savedErrno;
            throwSystemError("cannot create benchmark decode output", output);
        }
    }
    if (outputDescriptor < 0) {
        ::close(parentDescriptor);
        throw std::runtime_error("cannot allocate a benchmark decode output name");
    }

    Sha256Accumulator digest;
    std::uintmax_t byteCount = 0;
    bool installed = false;
    bool parentOpen = true;
    try {
        std::array<std::uint8_t, 1024 * 1024> buffer {};
        std::size_t buffered = 0;
        auto flush = [&]() {
            std::size_t writtenTotal = 0;
            while (writtenTotal < buffered) {
                const ssize_t written = ::write(
                    outputDescriptor,
                    buffer.data() + writtenTotal,
                    buffered - writtenTotal
                );
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) throwSystemError("cannot write benchmark decode output", output);
                writtenTotal += static_cast<std::size_t>(written);
            }
            digest.update(buffer.data(), buffered);
            byteCount += buffered;
            buffered = 0;
        };
        for (float value : image.data) {
            if (!std::isfinite(value)) {
                throw std::runtime_error("decoded benchmark image contains a non-finite pixel");
            }
            const float scaled = std::clamp(value * 255.0f, 0.0f, 255.0f);
            buffer[buffered++] = static_cast<std::uint8_t>(scaled + 0.5f);
            if (buffered == buffer.size()) flush();
        }
        if (buffered > 0) flush();
        if (::fsync(outputDescriptor) != 0) {
            throwSystemError("cannot sync benchmark decode output", output);
        }
        if (::close(outputDescriptor) != 0) {
            outputDescriptor = -1;
            throwSystemError("cannot close benchmark decode output", output);
        }
        outputDescriptor = -1;
        if (::renameatx_np(
                parentDescriptor,
                temporaryName.c_str(),
                parentDescriptor,
                output.filename().c_str(),
                RENAME_EXCL
            ) != 0) {
            throwSystemError("cannot install benchmark decode output", output);
        }
        installed = true;
        if (::fsync(parentDescriptor) != 0) {
            throwSystemError("cannot sync benchmark output directory", parent);
        }
        (void)::close(parentDescriptor);
        parentOpen = false;
        return {"sha256:" + digest.finish(), byteCount};
    } catch (...) {
        if (outputDescriptor >= 0) ::close(outputDescriptor);
        if (parentOpen) {
            ::unlinkat(
                parentDescriptor,
                installed ? output.filename().c_str() : temporaryName.c_str(),
                0
            );
            ::close(parentDescriptor);
        }
        throw;
    }
}

void throwSystemError(const std::string &operation, const fs::path &path) {
    throw std::runtime_error(operation + " " + path.string() + ": " + std::strerror(errno));
}

void syncFile(const fs::path &path) {
    int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
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
    int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) throwSystemError("cannot open directory", path);
    if (::fsync(descriptor) != 0) {
        int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throwSystemError("cannot sync directory", path);
    }
    if (::close(descriptor) != 0) throwSystemError("cannot close directory", path);
}

struct CheckpointContext {
    const TrainingProfileConfig &profile;
    std::uint64_t seed;
    std::size_t cameraCount;
    TrainingIdentity identity;
    std::string trainerBuildDigest;
    std::uint64_t memoryBudgetBytes;
};

class CheckpointCompatibilityError : public std::runtime_error {
public:
    CheckpointCompatibilityError(std::string reason, std::string message)
        : std::runtime_error(std::move(message)), reason_(std::move(reason)) {}

    const std::string &reason() const { return reason_; }

private:
    std::string reason_;
};

struct ValidatedCheckpoint {
    CheckpointReceipt receipt;
    TrainerCheckpointState trainerState;
    int gaussianCount;
    int backingCapacity;
    fs::path payloadPath;
};

class ScopedDirectoryRemoval {
public:
    explicit ScopedDirectoryRemoval(fs::path path) : path_(std::move(path)) {}
    ~ScopedDirectoryRemoval() {
        if (!active_) return;
        std::error_code ignored;
        fs::remove_all(path_, ignored);
    }
    void release() { active_ = false; }

private:
    fs::path path_;
    bool active_ = true;
};

bool isLowercaseHex(const std::string &value, std::size_t length = 64) {
    return value.size() == length && std::all_of(value.begin(), value.end(), [](char character) {
        return (character >= '0' && character <= '9') ||
            (character >= 'a' && character <= 'f');
    });
}

void requirePlainDirectory(const fs::path &path) {
    struct stat metadata {};
    if (::lstat(path.c_str(), &metadata) != 0) throwSystemError("cannot inspect directory", path);
    if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("expected an ordinary directory: " + path.string());
    }
}

std::string readBoundedTextFile(
    const fs::path &path,
    std::uintmax_t maximumBytes,
    bool requireSingleLink = true
) {
    const struct stat pathMetadata = requireRegularFile(path, requireSingleLink);
    if (pathMetadata.st_size < 0 ||
        static_cast<std::uintmax_t>(pathMetadata.st_size) > maximumBytes) {
        throw std::runtime_error("file exceeds its size limit: " + path.string());
    }
    OpenFile file(path);
    struct stat openedMetadata {};
    if (::fstat(file.descriptor, &openedMetadata) != 0) throwSystemError("cannot inspect", path);
    if (!sameStableFileMetadata(pathMetadata, openedMetadata)) {
        throw std::runtime_error("file changed while opening: " + path.string());
    }

    std::string contents(static_cast<std::size_t>(openedMetadata.st_size), '\0');
    std::size_t consumed = 0;
    while (consumed < contents.size()) {
        const ssize_t count = ::read(
            file.descriptor,
            contents.data() + consumed,
            contents.size() - consumed
        );
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throwSystemError("cannot read", path);
        if (count == 0) {
            throw std::runtime_error("file ended while being read: " + path.string());
        }
        consumed += static_cast<std::size_t>(count);
    }

    struct stat finalOpenedMetadata {};
    struct stat finalPathMetadata {};
    if (::fstat(file.descriptor, &finalOpenedMetadata) != 0 ||
        ::lstat(path.c_str(), &finalPathMetadata) != 0 ||
        !sameStableFileMetadata(openedMetadata, finalOpenedMetadata) ||
        !sameStableFileMetadata(openedMetadata, finalPathMetadata)) {
        throw std::runtime_error("file changed while being read: " + path.string());
    }
    return contents;
}

struct OrientationOverlay {
    std::array<double, 4> sourceToCanonicalWxyz;
    std::array<double, 9> sourceToCanonical;
    std::string contentDigest;
    bool isIdentity;
};

std::string sha256(const std::string &contents) {
    Sha256Accumulator digest;
    digest.update(contents);
    return digest.finish();
}

std::array<double, 9> rotationMatrixFromUnitQuaternion(
    const std::array<double, 4> &quaternion
) {
    const double w = quaternion[0];
    const double x = quaternion[1];
    const double y = quaternion[2];
    const double z = quaternion[3];
    const std::array<double, 9> rotation = {
        1.0 - 2.0 * (y * y + z * z),
        2.0 * (x * y - w * z),
        2.0 * (x * z + w * y),
        2.0 * (x * y + w * z),
        1.0 - 2.0 * (x * x + z * z),
        2.0 * (y * z - w * x),
        2.0 * (x * z - w * y),
        2.0 * (y * z + w * x),
        1.0 - 2.0 * (x * x + y * y),
    };

    const double determinant =
        rotation[0] * (rotation[4] * rotation[8] - rotation[5] * rotation[7]) -
        rotation[1] * (rotation[3] * rotation[8] - rotation[5] * rotation[6]) +
        rotation[2] * (rotation[3] * rotation[7] - rotation[4] * rotation[6]);
    if (!std::isfinite(determinant) || std::abs(determinant - 1.0) > 1.0e-10) {
        throw std::runtime_error("orientation quaternion does not produce a proper rotation");
    }
    return rotation;
}

OrientationOverlay parseOrientationOverlay(const std::string &contents) {
    bool duplicateKey = false;
    std::set<std::string> parsedKeys;
    json payload;
    try {
        payload = json::parse(
            contents,
            [&](int, json::parse_event_t event, json &parsed) {
                if (event == json::parse_event_t::key) {
                    const std::string key = parsed.get<std::string>();
                    if (!parsedKeys.insert(key).second) duplicateKey = true;
                }
                return true;
            }
        );
    } catch (const std::exception &error) {
        throw std::runtime_error(
            "orientation file is not valid JSON: " + std::string(error.what())
        );
    }
    if (duplicateKey || !payload.is_object() || payload.size() != 2 ||
        !payload.contains("schema_version") ||
        !payload.contains("source_to_canonical_wxyz")) {
        throw std::runtime_error("orientation file does not match closed schema 1");
    }
    const json &schemaVersion = payload.at("schema_version");
    if (!schemaVersion.is_number_integer() || schemaVersion.get<int>() != 1) {
        throw std::runtime_error("orientation schema_version must be integer 1");
    }
    const json &encodedQuaternion = payload.at("source_to_canonical_wxyz");
    if (!encodedQuaternion.is_array() || encodedQuaternion.size() != 4) {
        throw std::runtime_error("orientation quaternion must contain four numbers in wxyz order");
    }

    std::array<double, 4> quaternion {};
    double squaredNorm = 0;
    for (std::size_t index = 0; index < quaternion.size(); ++index) {
        if (!encodedQuaternion[index].is_number()) {
            throw std::runtime_error("orientation quaternion must contain only numbers");
        }
        quaternion[index] = encodedQuaternion[index].get<double>();
        if (!std::isfinite(quaternion[index])) {
            throw std::runtime_error("orientation quaternion must be finite");
        }
        squaredNorm += quaternion[index] * quaternion[index];
    }
    if (!std::isfinite(squaredNorm) || squaredNorm <= 0) {
        throw std::runtime_error("orientation quaternion has an invalid norm");
    }
    if (std::abs(squaredNorm - 1.0) > 1.0e-6) {
        throw std::runtime_error("orientation quaternion must have unit length");
    }
    const double norm = std::sqrt(squaredNorm);
    if (quaternion[0] < 0) {
        throw std::runtime_error("orientation quaternion sign is not canonical");
    }
    if (quaternion[0] == 0) {
        const auto firstNonzero = std::find_if(
            quaternion.begin() + 1,
            quaternion.end(),
            [](double value) { return value != 0; }
        );
        if (firstNonzero == quaternion.end() || *firstNonzero < 0) {
            throw std::runtime_error("orientation quaternion sign is not canonical");
        }
    }
    for (double &value : quaternion) value /= norm;

    const bool identity = quaternion[0] == 1.0 && quaternion[1] == 0.0 &&
        quaternion[2] == 0.0 && quaternion[3] == 0.0;
    return OrientationOverlay {
        quaternion,
        rotationMatrixFromUnitQuaternion(quaternion),
        sha256(contents),
        identity,
    };
}

OrientationOverlay readOrientationOverlay(const fs::path &dataset) {
    constexpr std::uintmax_t maximumOrientationBytes = 4096;
    const fs::path path = dataset / "sparse" / "0" / "easysplat_orientation.json";
    return parseOrientationOverlay(readBoundedTextFile(path, maximumOrientationBytes, true));
}

std::array<double, 3> rotateVector(
    const std::array<double, 9> &rotation,
    const std::array<double, 3> &vector
) {
    return {
        rotation[0] * vector[0] + rotation[1] * vector[1] + rotation[2] * vector[2],
        rotation[3] * vector[0] + rotation[4] * vector[1] + rotation[5] * vector[2],
        rotation[6] * vector[0] + rotation[7] * vector[1] + rotation[8] * vector[2],
    };
}

float checkedFloat(double value, const char *description) {
    if (!std::isfinite(value) ||
        std::abs(value) > static_cast<double>(std::numeric_limits<float>::max())) {
        throw std::runtime_error(std::string(description) + " exceeds the finite float range");
    }
    return static_cast<float>(value);
}

void applyOrientationOverlay(InputData &inputData, const OrientationOverlay &orientation) {
    if (orientation.isIdentity) return;
    if (!std::isfinite(inputData.scale) || inputData.scale <= 0) {
        throw std::runtime_error("input normalization scale is invalid");
    }
    if (inputData.points.count < 0 ||
        static_cast<std::uint64_t>(inputData.points.count) >
            std::numeric_limits<std::size_t>::max() / 3 ||
        inputData.points.xyz.size() != static_cast<std::size_t>(inputData.points.count) * 3) {
        throw std::runtime_error("input sparse-point storage is inconsistent");
    }

    double maximumAbsoluteCenter = 0;
    for (const Camera &camera : inputData.cameras) {
        if (!camera.image.empty() || !camera.imagePyramids.empty() ||
            !camera.mtensorImageCache.empty() || camera.cachedViewMat.defined() ||
            camera.cachedProjViewMat.defined()) {
            throw std::runtime_error("orientation must be applied before camera resources are cached");
        }
        for (float value : camera.camToWorld) {
            if (!std::isfinite(value)) {
                throw std::runtime_error("input camera pose is not finite");
            }
        }
        if (camera.camToWorld[12] != 0 || camera.camToWorld[13] != 0 ||
            camera.camToWorld[14] != 0 || camera.camToWorld[15] != 1) {
            throw std::runtime_error("input camera pose is not an affine c2w transform");
        }
        const auto rotatedCenter = rotateVector(
            orientation.sourceToCanonical,
            {camera.camToWorld[3], camera.camToWorld[7], camera.camToWorld[11]}
        );
        for (double value : rotatedCenter) {
            if (!std::isfinite(value)) {
                throw std::runtime_error("rotated camera center is not finite");
            }
            maximumAbsoluteCenter = std::max(maximumAbsoluteCenter, std::abs(value));
        }
    }

    // Upstream uses scale 1 for coincident camera centers. Preserve that
    // degenerate convention; otherwise re-normalize in canonical axes.
    const double normalizationFactor = maximumAbsoluteCenter > 0
        ? 1.0 / maximumAbsoluteCenter
        : 1.0;
    if (!std::isfinite(normalizationFactor) || normalizationFactor <= 0) {
        throw std::runtime_error("canonical camera normalization is invalid");
    }

    for (Camera &camera : inputData.cameras) {
        const std::array<double, 9> sourceBasis = {
            camera.camToWorld[0], camera.camToWorld[1], camera.camToWorld[2],
            camera.camToWorld[4], camera.camToWorld[5], camera.camToWorld[6],
            camera.camToWorld[8], camera.camToWorld[9], camera.camToWorld[10],
        };
        for (int row = 0; row < 3; ++row) {
            for (int column = 0; column < 3; ++column) {
                double value = 0;
                for (int inner = 0; inner < 3; ++inner) {
                    value += orientation.sourceToCanonical[row * 3 + inner] *
                        sourceBasis[inner * 3 + column];
                }
                camera.camToWorld[row * 4 + column] = checkedFloat(
                    value,
                    "canonical camera basis"
                );
            }
        }
        const auto center = rotateVector(
            orientation.sourceToCanonical,
            {camera.camToWorld[3], camera.camToWorld[7], camera.camToWorld[11]}
        );
        camera.camToWorld[3] = checkedFloat(
            center[0] * normalizationFactor,
            "canonical camera center"
        );
        camera.camToWorld[7] = checkedFloat(
            center[1] * normalizationFactor,
            "canonical camera center"
        );
        camera.camToWorld[11] = checkedFloat(
            center[2] * normalizationFactor,
            "canonical camera center"
        );
    }

    for (std::int64_t index = 0; index < inputData.points.count; ++index) {
        const std::size_t offset = static_cast<std::size_t>(index) * 3;
        const std::array<double, 3> sourcePoint = {
            inputData.points.xyz[offset],
            inputData.points.xyz[offset + 1],
            inputData.points.xyz[offset + 2],
        };
        if (!std::isfinite(sourcePoint[0]) || !std::isfinite(sourcePoint[1]) ||
            !std::isfinite(sourcePoint[2])) {
            throw std::runtime_error("input sparse point is not finite");
        }
        const auto point = rotateVector(orientation.sourceToCanonical, sourcePoint);
        for (int component = 0; component < 3; ++component) {
            inputData.points.xyz[offset + component] = checkedFloat(
                point[component] * normalizationFactor,
                "canonical sparse point"
            );
        }
    }

    const std::array<double, 3> sourceTranslation = {
        inputData.translation[0], inputData.translation[1], inputData.translation[2],
    };
    if (!std::isfinite(sourceTranslation[0]) || !std::isfinite(sourceTranslation[1]) ||
        !std::isfinite(sourceTranslation[2])) {
        throw std::runtime_error("input normalization translation is not finite");
    }
    const auto translation = rotateVector(
        orientation.sourceToCanonical,
        sourceTranslation
    );
    for (int component = 0; component < 3; ++component) {
        inputData.translation[component] = checkedFloat(
            translation[component],
            "canonical normalization translation"
        );
    }
    inputData.scale = checkedFloat(
        static_cast<double>(inputData.scale) * normalizationFactor,
        "canonical normalization scale"
    );
    if (inputData.scale <= 0) {
        throw std::runtime_error("canonical normalization scale is invalid");
    }
}

void verifyOrientationOverlaySelfCheck() {
    const OrientationOverlay orientation = parseOrientationOverlay(
        "{\"schema_version\":1,\"source_to_canonical_wxyz\":"
        "[0.8660254037844386,0.1336306209562122,"
        "0.2672612419124244,0.4008918628686366]}"
    );

    const std::array<std::string, 4> invalid = {
        "{\"schema_version\":1,\"source_to_canonical_wxyz\":[1,0,0,0],\"extra\":0}",
        "{\"schema_version\":1,\"schema_version\":1,\"source_to_canonical_wxyz\":[1,0,0,0]}",
        "{\"schema_version\":1,\"source_to_canonical_wxyz\":[2,0,0,0]}",
        "{\"schema_version\":1,\"source_to_canonical_wxyz\":[-1,0,0,0]}",
    };
    for (const std::string &candidate : invalid) {
        bool rejected = false;
        try {
            (void)parseOrientationOverlay(candidate);
        } catch (const std::exception &) {
            rejected = true;
        }
        if (!rejected) throw std::runtime_error("orientation parser self-check accepted invalid input");
    }

    // Raw camera centers are (4,-1,2), (-2,3,0), and (1,5,-4), with
    // mean (1,7/3,-2/3); sourceCameras stores their normalized c2w values.
    constexpr std::array<std::array<float, 16>, 3> sourceCameras = {{
        {1, 0, 0, 0.9f, 0, 1, 0, -1, 0, 0, 1, 0.8f, 0, 0, 0, 1},
        {0, -1, 0, -0.9f, 1, 0, 0, 0.2f, 0, 0, 1, 0.2f, 0, 0, 0, 1},
        {1, 0, 0, 0, 0, 0, -1, 0.8f, 0, 1, 0, -1, 0, 0, 0, 1},
    }};
    InputData inputData;
    inputData.scale = 0.3f;
    inputData.translation[0] = 1;
    inputData.translation[1] = 7.0f / 3.0f;
    inputData.translation[2] = -2.0f / 3.0f;
    inputData.points.count = 4;
    // The first two points represent COLMAP sparse points; the latter two
    // represent points merged from a learned initializer.
    inputData.points.xyz = {
        0.3f, -0.7f, -0.7f,
        -0.6f, 0.5f, 0.8f,
        1.2f, -1.3f, 0.5f,
        -1.2f, -0.4f, -0.1f,
    };
    inputData.points.rgb.assign(12, 0);
    for (const auto &source : sourceCameras) {
        Camera camera;
        std::copy(source.begin(), source.end(), camera.camToWorld);
        inputData.cameras.push_back(std::move(camera));
    }

    applyOrientationOverlay(inputData, orientation);

    // These constants come from rotating the raw fixture first, then applying
    // the same mean and L-infinity normalization as a physically rotated model.
    // They intentionally do not use the overlay's matrix or vector helpers.
    constexpr std::array<std::array<double, 16>, 3> expectedCameras = {{
        {
            0.5357142857142857, -0.6229365034008422, 0.5700529070291329, 1,
            0.765793646257985, 0.6428571428571428, -0.017169310657423553,
            0.020896314834495874,
            -0.35576719274341856, 0.44574073922885216, 0.8214285714285714,
            -0.06968601904581694,
            0, 0, 0, 1,
        },
        {
            -0.6229365034008422, -0.5357142857142857, 0.5700529070291329,
            -0.31561894295822923,
            0.6428571428571428, -0.765793646257985, -0.017169310657423553,
            -0.3613278325389292,
            0.44574073922885216, 0.35576719274341856, 0.8214285714285714,
            0.36744370453847897,
            0, 0, 0, 1,
        },
        {
            0.5357142857142857, 0.5700529070291329, 0.6229365034008422,
            -0.6843810570417704,
            0.765793646257985, -0.017169310657423553, -0.6428571428571428,
            0.34043151770443325,
            -0.35576719274341856, 0.8214285714285714, -0.44574073922885216,
            -0.2977576854926622,
            0, 0, 0, 1,
        },
    }};
    constexpr std::array<double, 12> expectedPoints = {
        0.12666072409766602, -0.13339343787716143, -0.636560675627507,
        -0.11328681106205996, -0.09722692740553023, 0.7004409406983003,
        1.1131105705535043, 0.04782038141426362, -0.381564942600894,
        -0.28869487637846147, -0.7522657022785499, 0.10664221753684251,
    };
    constexpr std::array<double, 3> expectedTranslation = {
        -1.2978394935737683,
        2.277239853362934,
        0.13667548450485578,
    };
    constexpr double expectedScale = 0.1921695167380479;
    constexpr double tolerance = 2.0e-6;
    const auto requireNear = [](double actual, double expected, const char *field) {
        if (!std::isfinite(actual) || std::abs(actual - expected) > tolerance) {
            throw std::runtime_error(std::string("orientation parity mismatch: ") + field);
        }
    };
    for (std::size_t cameraIndex = 0; cameraIndex < inputData.cameras.size(); ++cameraIndex) {
        for (std::size_t component = 0; component < 16; ++component) {
            requireNear(
                inputData.cameras[cameraIndex].camToWorld[component],
                expectedCameras[cameraIndex][component],
                "camera c2w"
            );
        }
    }
    for (std::size_t component = 0; component < expectedPoints.size(); ++component) {
        requireNear(inputData.points.xyz[component], expectedPoints[component], "point");
    }
    for (std::size_t component = 0; component < expectedTranslation.size(); ++component) {
        requireNear(inputData.translation[component], expectedTranslation[component], "translation");
    }
    requireNear(inputData.scale, expectedScale, "scale");

    const auto project = [](const Camera &camera, const float *point) {
        const std::array<double, 3> delta = {
            point[0] - camera.camToWorld[3],
            point[1] - camera.camToWorld[7],
            point[2] - camera.camToWorld[11],
        };
        const double viewX = camera.camToWorld[0] * delta[0]
            + camera.camToWorld[4] * delta[1]
            + camera.camToWorld[8] * delta[2];
        const double viewY = camera.camToWorld[1] * delta[0]
            + camera.camToWorld[5] * delta[1]
            + camera.camToWorld[9] * delta[2];
        const double viewZ = camera.camToWorld[2] * delta[0]
            + camera.camToWorld[6] * delta[1]
            + camera.camToWorld[10] * delta[2];
        if (!std::isfinite(viewZ) || std::abs(viewZ) <= 1.0e-9) {
            throw std::runtime_error("orientation parity projection has invalid depth");
        }
        return std::array<double, 2> {viewX / viewZ, viewY / viewZ};
    };
    constexpr std::array<std::size_t, 3> projectedPointIndices = {0, 1, 2};
    constexpr std::array<std::array<double, 2>, 3> expectedProjections = {{
        {0.4, -0.2},
        {0.5, -0.5},
        {4.0 / 7.0, 5.0 / 7.0},
    }};
    for (std::size_t cameraIndex = 0; cameraIndex < inputData.cameras.size(); ++cameraIndex) {
        const std::size_t pointIndex = projectedPointIndices[cameraIndex];
        const auto projected = project(
            inputData.cameras[cameraIndex],
            inputData.points.xyz.data() + pointIndex * 3
        );
        requireNear(projected[0], expectedProjections[cameraIndex][0], "projection x");
        requireNear(projected[1], expectedProjections[cameraIndex][1], "projection y");
    }
}

void writeAll(int descriptor, const std::string &contents, const fs::path &path) {
    const char *cursor = contents.data();
    std::size_t remaining = contents.size();
    while (remaining > 0) {
        const ssize_t written = ::write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) throwSystemError("cannot write", path);
        cursor += written;
        remaining -= static_cast<std::size_t>(written);
    }
}

void writeExclusiveFile(const fs::path &path, const std::string &contents) {
    const int descriptor = ::open(
        path.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
    );
    if (descriptor < 0) throwSystemError("cannot create", path);
    try {
        writeAll(descriptor, contents, path);
        if (::fsync(descriptor) != 0) throwSystemError("cannot sync", path);
        if (::close(descriptor) != 0) throwSystemError("cannot close", path);
    } catch (...) {
        const int savedErrno = errno;
        ::close(descriptor);
        errno = savedErrno;
        throw;
    }
}

std::optional<std::string> readCurrentGeneration(const fs::path &checkpointRoot) {
    const fs::path current = checkpointRoot / "CURRENT";
    struct stat metadata {};
    if (::lstat(current.c_str(), &metadata) != 0) {
        if (errno == ENOENT) return std::nullopt;
        throwSystemError("cannot inspect", current);
    }
    std::string generation = readBoundedTextFile(current, 128);
    if (!generation.empty() && generation.back() == '\n') generation.pop_back();
    if (generation.size() != 73 || generation[8] != '-' ||
        !std::all_of(generation.begin(), generation.begin() + 8, [](char value) {
            return value >= '0' && value <= '9';
        }) ||
        !isLowercaseHex(generation.substr(9))) {
        throw std::runtime_error("checkpoint CURRENT entry is invalid");
    }
    return generation;
}

fs::path prepareCheckpointRoot(const fs::path &checkpointRoot) {
    if (checkpointRoot.empty() || checkpointRoot.filename().empty()) {
        throw std::runtime_error("checkpoint path must name a directory");
    }
    requirePlainDirectory(checkpointRoot.parent_path());
    struct stat metadata {};
    if (::lstat(checkpointRoot.c_str(), &metadata) != 0) {
        if (errno != ENOENT) throwSystemError("cannot inspect checkpoint root", checkpointRoot);
        if (::mkdir(checkpointRoot.c_str(), S_IRWXU) != 0) {
            throwSystemError("cannot create checkpoint root", checkpointRoot);
        }
    } else if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("checkpoint root must be an ordinary directory");
    }
    if (::chmod(checkpointRoot.c_str(), S_IRWXU) != 0) {
        throwSystemError("cannot protect checkpoint root", checkpointRoot);
    }

    const fs::path generations = checkpointRoot / "generations";
    if (::lstat(generations.c_str(), &metadata) != 0) {
        if (errno != ENOENT) throwSystemError("cannot inspect checkpoint generations", generations);
        if (::mkdir(generations.c_str(), S_IRWXU) != 0) {
            throwSystemError("cannot create checkpoint generations", generations);
        }
    } else if (!S_ISDIR(metadata.st_mode)) {
        throw std::runtime_error("checkpoint generations must be an ordinary directory");
    }
    if (::chmod(generations.c_str(), S_IRWXU) != 0) {
        throwSystemError("cannot protect checkpoint generations", generations);
    }
    return generations;
}

std::set<std::string> checkpointManifestKeys() {
    return {
        "backing_capacity", "best_camera_losses", "camera_count", "camera_draw_count",
        "elapsed_seconds", "gaussian_count", "geometry_digest", "input_digest",
        "iteration", "iteration_limit", "last_improvement_iteration", "latest_loss",
        "latest_loss_iteration", "payload_bytes", "payload_file", "payload_schema",
        "memory_budget_bytes", "payload_sha256", "plateau_window", "profile",
        "raster_exact_buffer_bytes_added", "raster_exact_buffer_growth_count",
        "raster_exact_fallback_elapsed_seconds", "raster_fallback_count",
        "raster_peak_exact_intersection_capacity", "raster_replay_elapsed_seconds",
        "dropped_intersection_count", "schema_version", "seed",
        "trainer_build_digest", "trainer_version"
    };
}

ValidatedCheckpoint validateCheckpointGeneration(
    const fs::path &checkpointRoot,
    const std::string &generation,
    const CheckpointContext &context
) {
    const fs::path generationPath = checkpointRoot / "generations" / generation;
    requirePlainDirectory(generationPath);
    std::set<std::string> actualFiles;
    for (const fs::directory_entry &entry : fs::directory_iterator(generationPath)) {
        actualFiles.insert(entry.path().filename().string());
    }
    if (actualFiles != std::set<std::string>{"manifest.json", "state.msplat"}) {
        throw std::runtime_error("checkpoint generation has unexpected contents");
    }

    const fs::path manifestPath = generationPath / "manifest.json";
    const fs::path payloadPath = generationPath / "state.msplat";
    const std::string manifestText = readBoundedTextFile(
        manifestPath,
        maximumCheckpointManifestBytes
    );
    json manifest = json::parse(manifestText);
    if (!manifest.is_object()) throw std::runtime_error("checkpoint manifest must be an object");
    std::set<std::string> actualKeys;
    for (auto iterator = manifest.begin(); iterator != manifest.end(); ++iterator) {
        actualKeys.insert(iterator.key());
    }
    if (actualKeys != checkpointManifestKeys()) {
        throw std::runtime_error("checkpoint manifest keys do not match schema 3");
    }

    const int schemaVersion = manifest.at("schema_version").get<int>();
    const int payloadSchema = manifest.at("payload_schema").get<int>();
    const std::string trainerVersion = manifest.at("trainer_version").get<std::string>();
    const std::string trainerDigest = manifest.at("trainer_build_digest").get<std::string>();
    const std::string profile = manifest.at("profile").get<std::string>();
    const std::uint64_t seed = manifest.at("seed").get<std::uint64_t>();
    const std::size_t cameraCount = manifest.at("camera_count").get<std::size_t>();
    const std::string inputDigest = manifest.at("input_digest").get<std::string>();
    const std::string geometryDigest = manifest.at("geometry_digest").get<std::string>();
    const int iteration = manifest.at("iteration").get<int>();
    const int cameraDrawCount = manifest.at("camera_draw_count").get<int>();
    const int iterationLimit = manifest.at("iteration_limit").get<int>();
    const int plateauWindow = manifest.at("plateau_window").get<int>();
    const int gaussianCount = manifest.at("gaussian_count").get<int>();
    const int backingCapacity = manifest.at("backing_capacity").get<int>();
    const std::string payloadFile = manifest.at("payload_file").get<std::string>();
    const std::string payloadDigest = manifest.at("payload_sha256").get<std::string>();
    const std::uintmax_t payloadBytes = manifest.at("payload_bytes").get<std::uintmax_t>();
    const int lastImprovement = manifest.at("last_improvement_iteration").get<int>();
    const int latestLossIteration = manifest.at("latest_loss_iteration").get<int>();
    const double elapsedSeconds = manifest.at("elapsed_seconds").get<double>();
    const std::uint64_t memoryBudgetBytes =
        manifest.at("memory_budget_bytes").get<std::uint64_t>();
    const std::uint64_t rasterFallbackCount =
        manifest.at("raster_fallback_count").get<std::uint64_t>();
    const std::uint64_t droppedIntersectionCount =
        manifest.at("dropped_intersection_count").get<std::uint64_t>();
    const double rasterExactFallbackElapsedSeconds =
        manifest.at("raster_exact_fallback_elapsed_seconds").get<double>();
    const std::uint64_t rasterExactBufferGrowthCount =
        manifest.at("raster_exact_buffer_growth_count").get<std::uint64_t>();
    const std::uint64_t rasterExactBufferBytesAdded =
        manifest.at("raster_exact_buffer_bytes_added").get<std::uint64_t>();
    const double rasterReplayElapsedSeconds =
        manifest.at("raster_replay_elapsed_seconds").get<double>();
    const std::uint64_t rasterPeakExactIntersectionCapacity =
        manifest.at("raster_peak_exact_intersection_capacity").get<std::uint64_t>();

    if (schemaVersion != 3 || payloadSchema != 2 || !isLowercaseHex(trainerDigest) ||
        !isLowercaseHex(inputDigest) || !isLowercaseHex(geometryDigest) || cameraCount == 0 ||
        iteration < 0 || iteration >= iterationLimit || cameraDrawCount != iteration ||
        iterationLimit <= 0 || plateauWindow <= 0 ||
        gaussianCount <= 0 || backingCapacity < gaussianCount || payloadFile != "state.msplat" ||
        !isLowercaseHex(payloadDigest) || payloadBytes == 0 ||
        payloadBytes > maximumCheckpointPayloadBytes || lastImprovement < 0 ||
        lastImprovement > std::max(iteration, 500) || latestLossIteration < 0 ||
        latestLossIteration > iteration || !std::isfinite(elapsedSeconds) || elapsedSeconds < 0 ||
        memoryBudgetBytes == 0 ||
        rasterFallbackCount > std::min<std::uint64_t>(
            static_cast<std::uint64_t>(iteration),
            std::numeric_limits<std::uint32_t>::max()
        ) || droppedIntersectionCount != 0 ||
        !rasterRecoveryMetricsAreValid(
            rasterFallbackCount,
            rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity,
            memoryBudgetBytes
        ) || rasterExactFallbackElapsedSeconds > elapsedSeconds ||
        rasterReplayElapsedSeconds > elapsedSeconds) {
        throw std::runtime_error("checkpoint manifest does not match this training run");
    }

    const json &bestLosses = manifest.at("best_camera_losses");
    if (!bestLosses.is_array() || bestLosses.size() != cameraCount) {
        throw std::runtime_error("checkpoint camera-loss state is invalid");
    }
    std::vector<double> decodedBestLosses;
    decodedBestLosses.reserve(cameraCount);
    for (const json &value : bestLosses) {
        if (value.is_null()) {
            decodedBestLosses.push_back(std::numeric_limits<double>::infinity());
        } else {
            const double loss = value.get<double>();
            if (!std::isfinite(loss) || loss < 0) {
                throw std::runtime_error("checkpoint camera loss is invalid");
            }
            decodedBestLosses.push_back(loss);
        }
    }

    std::optional<double> latestLoss;
    const json &latestLossValue = manifest.at("latest_loss");
    if (!latestLossValue.is_null()) {
        const double decoded = latestLossValue.get<double>();
        if (!std::isfinite(decoded) || decoded < 0 || latestLossIteration == 0) {
            throw std::runtime_error("checkpoint latest loss is invalid");
        }
        latestLoss = decoded;
    } else if (latestLossIteration != 0) {
        throw std::runtime_error("checkpoint latest-loss iteration is inconsistent");
    }

    const auto [actualDigest, actualBytes] = hashFileContent(payloadPath, true);
    if (actualBytes != payloadBytes || actualDigest != payloadDigest) {
        throw std::runtime_error("checkpoint payload hash or size does not match its manifest");
    }

    const int generationIteration = std::stoi(generation.substr(0, 8));
    Sha256Accumulator manifestDigest;
    manifestDigest.update(manifestText);
    if (generationIteration != iteration || generation.substr(9) != manifestDigest.finish()) {
        throw std::runtime_error("checkpoint generation name does not match its manifest");
    }

    if (trainerVersion != APP_VERSION || trainerDigest != context.trainerBuildDigest) {
        throw CheckpointCompatibilityError(
            "trainer_changed",
            "checkpoint trainer build does not match the installed trainer"
        );
    }
    if (profile != context.profile.name || seed != context.seed ||
        iterationLimit != context.profile.iterationLimit ||
        plateauWindow != context.profile.plateauWindow ||
        memoryBudgetBytes != context.memoryBudgetBytes) {
        throw CheckpointCompatibilityError(
            "run_contract_changed",
            "checkpoint profile, seed, or budget no longer matches"
        );
    }
    if (cameraCount != context.cameraCount || inputDigest != context.identity.inputDigest) {
        throw CheckpointCompatibilityError(
            "input_changed",
            "checkpoint input set no longer matches"
        );
    }
    if (geometryDigest != context.identity.geometryDigest) {
        throw CheckpointCompatibilityError(
            "geometry_changed",
            "checkpoint geometry no longer matches"
        );
    }

    return ValidatedCheckpoint {
        CheckpointReceipt {iteration, generation, payloadDigest, payloadBytes},
        TrainerCheckpointState {
            iteration,
            lastImprovement,
            std::move(decodedBestLosses),
            latestLoss,
            latestLossIteration,
            elapsedSeconds,
            rasterFallbackCount,
            droppedIntersectionCount,
            rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity,
        },
        gaussianCount,
        backingCapacity,
        payloadPath,
    };
}

ValidatedCheckpoint loadCheckpoint(
    Model &model,
    const fs::path &checkpointRoot,
    const CheckpointContext &context
) {
    requirePlainDirectory(checkpointRoot);
    requirePlainDirectory(checkpointRoot / "generations");
    const std::optional<std::string> generation = readCurrentGeneration(checkpointRoot);
    if (!generation) throw std::runtime_error("checkpoint has no CURRENT generation");
    ValidatedCheckpoint checkpoint = validateCheckpointGeneration(
        checkpointRoot,
        *generation,
        context
    );
    const int loadedIteration = model.loadCheckpoint(checkpoint.payloadPath.string());
    if (loadedIteration != checkpoint.receipt.iteration ||
        model.num_active != checkpoint.gaussianCount ||
        model.buf_capacity != checkpoint.backingCapacity) {
        throw std::runtime_error("checkpoint payload state does not match its manifest");
    }
    return checkpoint;
}

std::string checkpointManifestText(
    const Model &model,
    const CheckpointContext &context,
    const TrainerCheckpointState &state,
    const std::string &payloadDigest,
    std::uintmax_t payloadBytes
) {
    json bestLosses = json::array();
    for (double loss : state.bestCameraLosses) {
        if (std::isfinite(loss)) bestLosses.push_back(loss);
        else bestLosses.push_back(nullptr);
    }
    json manifest = {
        {"backing_capacity", model.buf_capacity},
        {"best_camera_losses", std::move(bestLosses)},
        {"camera_count", context.cameraCount},
        {"camera_draw_count", state.iteration},
        {"elapsed_seconds", state.elapsedSeconds},
        {"gaussian_count", model.num_active},
        {"geometry_digest", context.identity.geometryDigest},
        {"input_digest", context.identity.inputDigest},
        {"iteration", state.iteration},
        {"iteration_limit", context.profile.iterationLimit},
        {"last_improvement_iteration", state.lastImprovementIteration},
        {"latest_loss", state.latestLoss ? json(*state.latestLoss) : json(nullptr)},
        {"latest_loss_iteration", state.latestLossIteration},
        {"memory_budget_bytes", context.memoryBudgetBytes},
        {"payload_bytes", payloadBytes},
        {"payload_file", "state.msplat"},
        {"payload_schema", 2},
        {"payload_sha256", payloadDigest},
        {"plateau_window", context.profile.plateauWindow},
        {"profile", context.profile.name},
        {"raster_exact_buffer_bytes_added", state.rasterExactBufferBytesAdded},
        {"raster_exact_buffer_growth_count", state.rasterExactBufferGrowthCount},
        {"raster_exact_fallback_elapsed_seconds", state.rasterExactFallbackElapsedSeconds},
        {"raster_fallback_count", state.rasterFallbackCount},
        {"raster_peak_exact_intersection_capacity", state.rasterPeakExactIntersectionCapacity},
        {"raster_replay_elapsed_seconds", state.rasterReplayElapsedSeconds},
        {"dropped_intersection_count", state.droppedIntersectionCount},
        {"schema_version", 3},
        {"seed", context.seed},
        {"trainer_build_digest", context.trainerBuildDigest},
        {"trainer_version", APP_VERSION},
    };
    std::string text = manifest.dump(2);
    text.push_back('\n');
    if (text.size() > maximumCheckpointManifestBytes) {
        throw std::runtime_error("checkpoint manifest exceeds its size limit");
    }
    return text;
}

CheckpointReceipt saveCheckpoint(
    Model &model,
    const fs::path &checkpointRoot,
    const CheckpointContext &context,
    const TrainerCheckpointState &state
) {
    if (state.iteration < 0 || state.iteration >= context.profile.iterationLimit ||
        state.bestCameraLosses.size() != context.cameraCount ||
        state.lastImprovementIteration < 0 ||
        state.lastImprovementIteration > std::max(state.iteration, 500) ||
        !std::isfinite(state.elapsedSeconds) || state.elapsedSeconds < 0 ||
        state.rasterFallbackCount > std::min<std::uint64_t>(
            static_cast<std::uint64_t>(state.iteration),
            std::numeric_limits<std::uint32_t>::max()
        ) || state.droppedIntersectionCount != 0 ||
        !rasterRecoveryMetricsAreValid(
            state.rasterFallbackCount,
            state.rasterExactFallbackElapsedSeconds,
            state.rasterExactBufferGrowthCount,
            state.rasterExactBufferBytesAdded,
            state.rasterReplayElapsedSeconds,
            state.rasterPeakExactIntersectionCapacity,
            context.memoryBudgetBytes
        ) || state.rasterExactFallbackElapsedSeconds > state.elapsedSeconds ||
        state.rasterReplayElapsedSeconds > state.elapsedSeconds) {
        throw std::runtime_error("cannot save inconsistent trainer checkpoint state");
    }
    if ((state.latestLoss.has_value() &&
         (!std::isfinite(*state.latestLoss) || *state.latestLoss < 0 || state.latestLossIteration == 0)) ||
        (!state.latestLoss.has_value() && state.latestLossIteration != 0) ||
        state.latestLossIteration > state.iteration) {
        throw std::runtime_error("cannot save inconsistent checkpoint loss evidence");
    }
    for (double loss : state.bestCameraLosses) {
        if (std::isfinite(loss) && loss < 0) {
            throw std::runtime_error("cannot save an invalid camera loss");
        }
    }

    const fs::path generations = prepareCheckpointRoot(checkpointRoot);
    const std::optional<std::string> previous = readCurrentGeneration(checkpointRoot);
    std::string stagingTemplate = (generations / ".tmp.XXXXXX").string();
    std::vector<char> stagingBuffer(stagingTemplate.begin(), stagingTemplate.end());
    stagingBuffer.push_back('\0');
    char *created = ::mkdtemp(stagingBuffer.data());
    if (!created) throwSystemError("cannot create checkpoint staging directory", generations);
    const fs::path staging(created);
    ScopedDirectoryRemoval stagingCleanup(staging);

    const fs::path payloadPath = staging / "state.msplat";
    model.saveCheckpoint(payloadPath.string(), state.iteration);
    if (::chmod(payloadPath.c_str(), S_IRUSR | S_IWUSR) != 0) {
        throwSystemError("cannot protect checkpoint payload", payloadPath);
    }
    syncFile(payloadPath);
    const auto [payloadDigest, payloadBytes] = hashFileContent(payloadPath, true);
    if (payloadBytes == 0 || payloadBytes > maximumCheckpointPayloadBytes) {
        throw std::runtime_error("checkpoint payload exceeds its size limit");
    }

    const std::string manifestText = checkpointManifestText(
        model,
        context,
        state,
        payloadDigest,
        payloadBytes
    );
    const fs::path manifestPath = staging / "manifest.json";
    writeExclusiveFile(manifestPath, manifestText);
    syncDirectory(staging);

    Sha256Accumulator manifestDigest;
    manifestDigest.update(manifestText);
    std::ostringstream generationName;
    generationName << std::setw(8) << std::setfill('0') << state.iteration
                   << '-' << manifestDigest.finish();
    const std::string generation = generationName.str();
    const fs::path published = generations / generation;
    if (::renamex_np(
            staging.c_str(),
            published.c_str(),
            RENAME_EXCL | RENAME_NOFOLLOW_ANY
        ) != 0) {
        if (errno != EEXIST) throwSystemError("cannot publish checkpoint generation", published);
        const ValidatedCheckpoint existing = validateCheckpointGeneration(
            checkpointRoot,
            generation,
            context
        );
        if (existing.receipt.payloadDigest != payloadDigest ||
            existing.receipt.payloadBytes != payloadBytes ||
            existing.receipt.iteration != state.iteration) {
            throw std::runtime_error("existing checkpoint generation does not match staged state");
        }
    } else {
        stagingCleanup.release();
    }
    syncDirectory(generations);

    const std::string currentContents = generation + "\n";
    std::string currentTemplate = (checkpointRoot / ".CURRENT.tmp.XXXXXX").string();
    std::vector<char> currentBuffer(currentTemplate.begin(), currentTemplate.end());
    currentBuffer.push_back('\0');
    const int currentDescriptor = ::mkstemp(currentBuffer.data());
    if (currentDescriptor < 0) throwSystemError("cannot create checkpoint CURRENT staging file", checkpointRoot);
    const fs::path currentTemporary(currentBuffer.data());
    try {
        if (::fchmod(currentDescriptor, S_IRUSR | S_IWUSR) != 0) {
            throwSystemError("cannot protect checkpoint CURRENT staging file", currentTemporary);
        }
        writeAll(currentDescriptor, currentContents, currentTemporary);
        if (::fsync(currentDescriptor) != 0) {
            throwSystemError("cannot sync checkpoint CURRENT staging file", currentTemporary);
        }
        if (::close(currentDescriptor) != 0) {
            throwSystemError("cannot close checkpoint CURRENT staging file", currentTemporary);
        }
    } catch (...) {
        const int savedErrno = errno;
        ::close(currentDescriptor);
        ::unlink(currentTemporary.c_str());
        errno = savedErrno;
        throw;
    }

    const fs::path current = checkpointRoot / "CURRENT";
    struct stat currentMetadata {};
    if (::lstat(current.c_str(), &currentMetadata) == 0 && !S_ISREG(currentMetadata.st_mode)) {
        ::unlink(currentTemporary.c_str());
        throw std::runtime_error("checkpoint CURRENT must be an ordinary file");
    }
    if (::renamex_np(currentTemporary.c_str(), current.c_str(), RENAME_NOFOLLOW_ANY) != 0) {
        const int savedErrno = errno;
        ::unlink(currentTemporary.c_str());
        errno = savedErrno;
        throwSystemError("cannot publish checkpoint CURRENT", current);
    }
    syncDirectory(checkpointRoot);

    for (const fs::directory_entry &entry : fs::directory_iterator(generations)) {
        const std::string name = entry.path().filename().string();
        if (name == generation || (previous && name == *previous)) continue;
        if (name.rfind(".tmp.", 0) == 0 ||
            (name.size() == 73 && name[8] == '-' && isLowercaseHex(name.substr(9)))) {
            std::error_code ignored;
            fs::remove_all(entry.path(), ignored);
        }
    }

    return CheckpointReceipt {state.iteration, generation, payloadDigest, payloadBytes};
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

bool savePlyAtomically(Model &model, const fs::path &output, int step) {
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
        if (cancellationSignal != 0) {
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
    const PreparseIntent preparseIntent = scanPreparseIntent(argc, argv);
    CLI::App app{"EasySplat native msplat trainer"};
    app.set_help_flag("-h,--help", "Show this help message");
    app.set_version_flag("--version", APP_VERSION);

    std::string datasetPath;
    std::string outputPath;
    std::string profileName;
    std::string checkpointPath;
    std::string resumePath;
    std::string sourcePlyPath;
    std::string maskManifestPath;
    std::string analysisCachePath;
    std::string expectedSourcePlyDigest;
    std::string expectedInputDigest;
    std::string expectedGeometryDigest;
    std::string expectedSelectedFramesDigest;
    std::string expectedTrainingManifestDigest;
    std::string anchorImage;
    std::uint64_t seed = 42;
    std::uint64_t memoryBudgetBytes = 0;
    int anchorInstance = 0;
    int iterationLimitOverride = 0;
    int plateauWindowOverride = 0;
    int holdoutEvery = 0;
    int eventsFileDescriptor = -1;
    bool isolate = false;
    bool selfCheck = false;
    std::string plyToValidate;
    std::string benchmarkDecodePath;
    std::string benchmarkDecodeOutputPath;

    CLI::Option *isolateOption = app.add_flag(
        "--isolate",
        isolate,
        "Run deterministic subject isolation without constructing training state"
    );
    CLI::Option *datasetOption = app.add_option(
        "--dataset", datasetPath, "Canonical COLMAP dataset directory"
    );
    CLI::Option *sourcePlyOption = app.add_option(
        "--source-ply",
        sourcePlyPath,
        "Authenticated source binary Gaussian PLY"
    );
    CLI::Option *maskManifestOption = app.add_option(
        "--mask-manifest",
        maskManifestPath,
        "Authenticated subject-isolation mask manifest"
    );
    CLI::Option *analysisCacheOption = app.add_option(
        "--analysis-cache",
        analysisCachePath,
        "Bounded resumable subject-isolation analysis cache"
    );
    CLI::Option *outputOption = app.add_option(
        "--output",
        outputPath,
        "Final trained or isolated PLY output path"
    );
    CLI::Option *profileOption = app.add_option(
        "--profile", profileName, "Training profile: fast, balanced, or high-detail"
    );
    CLI::Option *iterationLimitOption = app.add_option(
        "--iteration-limit",
        iterationLimitOverride,
        "Positive training iteration limit"
    );
    iterationLimitOption->check(CLI::Range(1, 1000000));
    CLI::Option *plateauWindowOption = app.add_option(
        "--plateau-window",
        plateauWindowOverride,
        "Positive early-stop plateau window"
    );
    plateauWindowOption->check(CLI::Range(1, 1000000));
    CLI::Option *holdoutEveryOption = app.add_option(
        "--holdout-every",
        holdoutEvery,
        "Hold out every Nth camera for validation PSNR; 0 disables"
    );
    // 1 would hold out every camera, leaving nothing to train on, and it also slipped
    // past the resume conflict below because only values above 1 create a split.
    holdoutEveryOption->check(CLI::Validator(
        [](std::string &value) -> std::string {
            const char *begin = value.c_str();
            char *end = nullptr;
            errno = 0;
            const long parsed = std::strtol(begin, &end, 10);
            // strtol rather than stoi: a throwing validator escapes CLI11's error
            // reporting and surfaces as a crash instead of a usage message.
            if (errno != 0 || end == begin || *end != '\0') {
                return "--holdout-every must be an integer";
            }
            if (parsed == 0 || (parsed >= 2 && parsed <= 1000)) return {};
            return "--holdout-every must be 0 or between 2 and 1000";
        },
        "0 or 2..1000"
    ));
    CLI::Option *seedOption = app.add_option(
        "--seed", seed, "UInt64 seed for reproducible camera ordering"
    );
    CLI::Option *memoryBudgetOption = app.add_option(
        "--memory-budget-bytes",
        memoryBudgetBytes,
        "Maximum bytes available to the native raster working set"
    );
    CLI::Option *checkpointOption = app.add_option(
        "--checkpoint", checkpointPath, "Atomic optimizer-checkpoint directory"
    );
    CLI::Option *expectedSourcePlyDigestOption = app.add_option(
        "--expected-source-ply-digest",
        expectedSourcePlyDigest,
        "Expected lowercase SHA-256 digest of the source PLY"
    );
    CLI::Option *expectedInputDigestOption = app.add_option(
        "--expected-input-digest",
        expectedInputDigest,
        "Expected SHA-256 digest of the prepared training images"
    );
    CLI::Option *expectedGeometryDigestOption = app.add_option(
        "--expected-geometry-digest",
        expectedGeometryDigest,
        "Expected SHA-256 digest of the prepared sparse geometry"
    );
    CLI::Option *expectedSelectedFramesDigestOption = app.add_option(
        "--expected-selected-frames-digest",
        expectedSelectedFramesDigest,
        "Expected lowercase SHA-256 digest of the selected-frame identity"
    );
    CLI::Option *expectedTrainingManifestDigestOption = app.add_option(
        "--expected-training-manifest-digest",
        expectedTrainingManifestDigest,
        "Expected lowercase SHA-256 digest of the training manifest"
    );
    CLI::Option *anchorImageOption = app.add_option(
        "--anchor-image",
        anchorImage,
        "Optional selected-frame identity for disambiguation"
    );
    CLI::Option *anchorInstanceOption = app.add_option(
        "--anchor-instance",
        anchorInstance,
        "Optional nonzero 8-bit frame-local instance paired with --anchor-image"
    );
    CLI::Option *resumeOption = app.add_option(
        "--resume",
        resumePath,
        "Validated optimizer-checkpoint directory"
    );
    CLI::Option *eventsOption = app.add_option(
        "--events-fd", eventsFileDescriptor, "Descriptor for schema-v2 JSONL events"
    );
    eventsOption->check(CLI::Range(0, std::numeric_limits<int>::max()));
    CLI::Option *selfCheckOption = app.add_flag(
        "--self-check",
        selfCheck,
        "Initialize Metal and load the adjacent metallib"
    );
    CLI::Option *validatePlyOption = app.add_option(
        "--validate-ply",
        plyToValidate,
        "Validate a binary Gaussian PLY"
    );
    validatePlyOption->check(CLI::ExistingFile);
    CLI::Option *benchmarkDecodeOption = app.add_option(
        "--benchmark-decode",
        benchmarkDecodePath,
        "Decode one benchmark source through production CoreGraphics/ImageIO"
    );
    CLI::Option *benchmarkDecodeOutputOption = app.add_option(
        "--benchmark-decode-output",
        benchmarkDecodeOutputPath,
        "Write the production-decoded benchmark source as tightly packed RGB8"
    );

    try {
        app.parse(argc, argv);
    } catch (const CLI::ParseError &error) {
        std::ostringstream capturedStandardOutput;
        std::ostringstream capturedStandardError;
        const int parserExit = app.exit(
            error,
            capturedStandardOutput,
            capturedStandardError
        );
        if (preparseIntent.suppressParseDiagnostics) {
            return parserExit == 0 ? 0 : 1;
        }
        emitCapturedParseDiagnostics(
            capturedStandardOutput.str(),
            capturedStandardError.str()
        );
        return parserExit == 0 ? 0 : 1;
    }

    if (eventsFileDescriptor == STDERR_FILENO) {
        std::cerr.rdbuf(std::cout.rdbuf());
    }

    std::optional<EventWriter> events;
    std::optional<BoundEventFileIdentity> boundEventFile;
    bool isolationEventEmissionSafe = true;
    int terminalIteration = 0;
    try {
        struct sigaction ignoreBrokenPipe {};
        ignoreBrokenPipe.sa_handler = SIG_IGN;
        sigemptyset(&ignoreBrokenPipe.sa_mask);
        ignoreBrokenPipe.sa_flags = 0;
        if (sigaction(SIGPIPE, &ignoreBrokenPipe, nullptr) != 0) {
            throw std::runtime_error("failed to configure event-pipe handling");
        }
        boundEventFile = boundEventFileIdentity(eventsFileDescriptor);
        if (isolate) {
            rejectEventDescriptorAliases(
                boundEventFile,
                {
                    fs::path(sourcePlyPath),
                    fs::path(maskManifestPath),
                    fs::path(analysisCachePath),
                    fs::path(outputPath),
                }
            );
        }
        events.emplace(eventsFileDescriptor);
        if (eventsFileDescriptor == STDOUT_FILENO) std::cout.rdbuf(std::cerr.rdbuf());

        const bool isolationOnlyArgumentProvided =
            sourcePlyOption->count() != 0 ||
            maskManifestOption->count() != 0 ||
            analysisCacheOption->count() != 0 ||
            expectedSourcePlyDigestOption->count() != 0 ||
            expectedSelectedFramesDigestOption->count() != 0 ||
            expectedTrainingManifestDigestOption->count() != 0 ||
            anchorImageOption->count() != 0 ||
            anchorInstanceOption->count() != 0;
        if (!isolate && isolationOnlyArgumentProvided) {
            throw std::runtime_error(
                "subject-isolation options require --isolate"
            );
        }

        const bool benchmarkDecodeRequested =
            benchmarkDecodeOption->count() != 0 || benchmarkDecodeOutputOption->count() != 0;
        if (isolate) {
            if (isolateOption->count() != 1) {
                throw std::runtime_error("--isolate must be provided exactly once");
            }
            if (profileOption->count() != 0 ||
                iterationLimitOption->count() != 0 ||
                plateauWindowOption->count() != 0 ||
                seedOption->count() != 0 ||
                checkpointOption->count() != 0 ||
                resumeOption->count() != 0) {
                throw std::runtime_error(
                    "--isolate cannot be combined with training-only options"
                );
            }
            if (selfCheckOption->count() != 0 ||
                validatePlyOption->count() != 0 ||
                benchmarkDecodeRequested) {
                throw std::runtime_error(
                    "--isolate cannot be combined with self-check, PLY validation, or benchmark mode"
                );
            }

            const std::array<std::pair<CLI::Option *, const char *>, 11>
                requiredIsolationOptions = {{
                    {datasetOption, "--dataset"},
                    {sourcePlyOption, "--source-ply"},
                    {maskManifestOption, "--mask-manifest"},
                    {analysisCacheOption, "--analysis-cache"},
                    {outputOption, "--output"},
                    {expectedSourcePlyDigestOption, "--expected-source-ply-digest"},
                    {expectedInputDigestOption, "--expected-input-digest"},
                    {expectedGeometryDigestOption, "--expected-geometry-digest"},
                    {expectedSelectedFramesDigestOption, "--expected-selected-frames-digest"},
                    {expectedTrainingManifestDigestOption, "--expected-training-manifest-digest"},
                    {memoryBudgetOption, "--memory-budget-bytes"},
                }};
            for (const auto &[option, name] : requiredIsolationOptions) {
                if (option->count() != 1) {
                    throw std::runtime_error(
                        std::string(name) + " is required exactly once with --isolate"
                    );
                }
            }
            if (eventsOption->count() != 1) {
                throw std::runtime_error(
                    "--events-fd is required exactly once with --isolate"
                );
            }
            if ((anchorImageOption->count() == 0) !=
                (anchorInstanceOption->count() == 0) ||
                anchorImageOption->count() > 1 ||
                anchorInstanceOption->count() > 1) {
                throw std::runtime_error(
                    "--anchor-image and --anchor-instance must be provided together at most once"
                );
            }
            if (anchorImageOption->count() == 1 &&
                (anchorImage.empty() || anchorInstance < 1 || anchorInstance > 255)) {
                throw std::runtime_error(
                    "--anchor-instance must be a nonzero 8-bit label and --anchor-image cannot be empty"
                );
            }
            const std::array<std::pair<const std::string *, const char *>, 5>
                requiredIsolationDigests = {{
                    {&expectedSourcePlyDigest, "--expected-source-ply-digest"},
                    {&expectedInputDigest, "--expected-input-digest"},
                    {&expectedGeometryDigest, "--expected-geometry-digest"},
                    {&expectedSelectedFramesDigest, "--expected-selected-frames-digest"},
                    {&expectedTrainingManifestDigest, "--expected-training-manifest-digest"},
                }};
            for (const auto &[digest, name] : requiredIsolationDigests) {
                if (!isLowercaseHex(*digest)) {
                    throw std::runtime_error(
                        std::string(name) + " must be a lowercase 64-character SHA-256 digest"
                    );
                }
            }
            if (memoryBudgetBytes == 0) {
                throw std::runtime_error(
                    "--memory-budget-bytes must be positive with --isolate"
                );
            }
            if (fs::path(outputPath).extension() != ".ply") {
                throw std::runtime_error("--output must end in .ply");
            }
            isolationEventEmissionSafe = false;

            struct sigaction action {};
            action.sa_handler = observeCancellation;
            sigemptyset(&action.sa_mask);
            action.sa_flags = 0;
            if (sigaction(SIGINT, &action, nullptr) != 0 ||
                sigaction(SIGTERM, &action, nullptr) != 0) {
                throw std::runtime_error("failed to install cancellation handlers");
            }
            auto throwIfIsolationCancelled = []() {
                if (cancellationSignal != 0) {
                    throw easysplat::isolation::CancellationError();
                }
            };
            throwIfIsolationCancelled();

            const fs::path isolationDataset(datasetPath);
            const fs::path canonicalSparse =
                isolationDataset / "sparse" / "0";
            const fs::path canonicalImages =
                isolationDataset / "images";
            requirePlainDirectory(isolationDataset);
            requirePlainDirectory(isolationDataset / "sparse");
            requirePlainDirectory(canonicalSparse);
            requirePlainDirectory(canonicalImages);
            msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);

            const OrientationOverlay orientation = readOrientationOverlay(datasetPath);
            throwIfIsolationCancelled();
            const TrainingIdentity identity = computeTrainingIdentity(
                datasetPath,
                orientation.contentDigest
            );
            throwIfIsolationCancelled();
            if (identity.inputDigest != expectedInputDigest ||
                identity.geometryDigest != expectedGeometryDigest) {
                throw std::runtime_error(
                    "prepared dataset identity does not match the expected digests"
                );
            }

            IsolationDatasetSnapshot snapshot(isolationDataset);
            const OrientationOverlay snapshotOrientation =
                readOrientationOverlay(snapshot.rootPath());
            if (snapshotOrientation.contentDigest != orientation.contentDigest) {
                throw std::runtime_error(
                    "orientation changed while creating the isolation dataset snapshot"
                );
            }
            snapshot.verifySnapshotIdentity(
                identity,
                snapshotOrientation.contentDigest
            );
            enforceIsolationColmapLoadBudget(
                snapshot.sparsePath(),
                memoryBudgetBytes
            );
            InputData inputData = loaders::loadColmap(
                snapshot.sparsePath().string(),
                snapshot.imagesPath().string()
            );
            applyOrientationOverlay(inputData, snapshotOrientation);
            throwIfIsolationCancelled();
            const TrainingIdentity loadedIdentity = computeTrainingIdentity(
                snapshot.rootPath(),
                snapshotOrientation.contentDigest
            );
            if (loadedIdentity.inputDigest != expectedInputDigest ||
                loadedIdentity.geometryDigest != expectedGeometryDigest) {
                throw std::runtime_error(
                    "private dataset snapshot changed while loading isolation cameras"
                );
            }
            snapshot.verifySnapshotIdentity(
                identity,
                snapshotOrientation.contentDigest
            );
            snapshot.verifyCameraResources(inputData);
            if (inputData.cameras.empty()) {
                throw std::runtime_error("input dataset contains no isolation cameras");
            }
            inputData.points = Points {};

            easysplat::isolation::IsolationRequest request {
                fs::path(sourcePlyPath),
                fs::path(maskManifestPath),
                fs::path(analysisCachePath),
                fs::path(outputPath),
                expectedSourcePlyDigest,
                expectedInputDigest,
                expectedGeometryDigest,
                expectedSelectedFramesDigest,
                expectedTrainingManifestDigest,
                static_cast<std::size_t>(memoryBudgetBytes),
                std::nullopt,
                boundEventFile,
            };
            if (anchorImageOption->count() == 1) {
                request.anchor = easysplat::isolation::Anchor {
                    anchorImage,
                    static_cast<std::uint16_t>(anchorInstance),
                };
            }
            const easysplat::isolation::IsolationRunResult result =
                easysplat::isolation::runIsolation(
                    request,
                    inputData,
                    [&](const std::string &event, json fields) {
                        isolationEventEmissionSafe = true;
                        events->emit(event, std::move(fields));
                    },
                    []() { return cancellationSignal != 0; }
                );
            if (!events->enabled()) {
                switch (result.outcome) {
                case easysplat::isolation::IsolationRunOutcome::completed:
                    std::cout << "EasySplat subject isolation completed: " << outputPath << '\n';
                    break;
                case easysplat::isolation::IsolationRunOutcome::ambiguous:
                    std::cout << "EasySplat subject isolation requires an anchor\n";
                    break;
                case easysplat::isolation::IsolationRunOutcome::noSubject:
                    std::cout << "EasySplat subject isolation found no subject\n";
                    break;
                case easysplat::isolation::IsolationRunOutcome::heldOutRejected:
                    std::cout << "EasySplat subject isolation failed held-out validation\n";
                    break;
                }
            }
            return 0;
        }

        if (benchmarkDecodeRequested) {
            if (benchmarkDecodeOption->count() != 1 ||
                benchmarkDecodeOutputOption->count() != 1) {
                throw std::runtime_error(
                    "--benchmark-decode and --benchmark-decode-output must be provided together"
                );
            }
            if (datasetOption->count() != 0 || outputOption->count() != 0 ||
                profileOption->count() != 0 || seedOption->count() != 0 ||
                memoryBudgetOption->count() != 0 || checkpointOption->count() != 0 ||
                !resumePath.empty() || !plyToValidate.empty() || selfCheck ||
                eventsOption->count() != 0) {
                throw std::runtime_error(
                    "benchmark decode mode cannot be combined with another trainer mode"
                );
            }
            const fs::path source(benchmarkDecodePath);
            const fs::path output(benchmarkDecodeOutputPath);
            (void)requireRegularFile(source, true);
            if (output.extension() != ".rgb8") {
                throw std::runtime_error("--benchmark-decode-output must end in .rgb8");
            }
            if (fs::exists(output) || fs::is_symlink(output)) {
                throw std::runtime_error("benchmark decode output already exists");
            }
            const fs::path outputParent = output.parent_path().empty()
                ? fs::current_path()
                : output.parent_path();
            requirePlainDirectory(outputParent);

            const auto [sourceDigestBefore, sourceBytes] = hashFileContent(source, true);
            const Image decoded = imreadRGB(source.string());
            const auto [sourceDigestAfter, sourceBytesAfter] = hashFileContent(source, true);
            if (sourceDigestAfter != sourceDigestBefore || sourceBytesAfter != sourceBytes) {
                throw std::runtime_error("benchmark decode source changed during native decoding");
            }
            const fs::path executable = trainerExecutablePath();
            const auto [executableDigest, executableBytes] = hashFileContent(executable, true);
            const auto [metallibDigest, metallibBytes] = hashFileContent(
                executable.parent_path() / "default.metallib",
                true
            );
            const std::string trainerBuildDigest = computeTrainerBuildDigest();
            const BenchmarkDecodeOutput outputReceipt = writeRGB8Atomically(output, decoded);
            const json receipt = {
                {"contract", "native_coregraphics_imageio_srgb8_v2"},
                {"executable_bytes", executableBytes},
                {"executable_sha256", "sha256:" + executableDigest},
                {"height", decoded.height},
                {"mode", "benchmark_decode"},
                {"mode_version", 2},
                {"metallib_bytes", metallibBytes},
                {"metallib_sha256", "sha256:" + metallibDigest},
                {"msplat_source_commit", std::string(msplatSourceCommit)},
                {"output_bytes", outputReceipt.bytes},
                {"output_sha256", outputReceipt.sha256},
                {"pixel_sha256", outputReceipt.sha256},
                {"schema_version", 1},
                {"source_bytes", sourceBytes},
                {"source_sha256", "sha256:" + sourceDigestBefore},
                {"status", "completed"},
                {"trainer_build_digest", "sha256:" + trainerBuildDigest},
                {"width", decoded.width},
            };
            std::cout << receipt.dump() << '\n';
            return 0;
        }

        if (!plyToValidate.empty()) {
            const PlyValidation validation = validateBinaryPly(plyToValidate);
            events->emit("output_validation", {{"output_bytes", validation.bytes},
                                                {"status", "ok"},
                                                {"vertex_count", validation.vertices}});
            if (!events->enabled()) std::cout << "PLY validation passed\n";
            return 0;
        }
        if (selfCheck) {
            if (msplat_device() == nullptr) {
                throw std::runtime_error("Metal device initialization returned null");
            }
            msplat_gpu_sync();
            verifyOrientationOverlaySelfCheck();
            verifySceneBoundsSelfCheck();
            events->emit("self_check", {
                {"isolation_mode_version", 1},
                {"scene_bounds_status", "ok"},
                {"status", "ok"},
                {"version", APP_VERSION},
            });
            if (!events->enabled()) std::cout << "Metal self-check passed\n";
            return 0;
        }

        if (datasetOption->count() == 0) throw std::runtime_error("--dataset is required for training");
        if (outputOption->count() == 0) throw std::runtime_error("--output is required for training");
        if (profileOption->count() == 0) throw std::runtime_error("--profile is required for training");
        if (seedOption->count() == 0) throw std::runtime_error("--seed is required for training");
        if (memoryBudgetOption->count() == 0 || memoryBudgetBytes == 0) {
            throw std::runtime_error(
                "--memory-budget-bytes is required for training and must be positive"
            );
        }
        if (checkpointOption->count() == 0) {
            throw std::runtime_error("--checkpoint is required for training");
        }
        if (expectedInputDigest.empty() != expectedGeometryDigest.empty() ||
            (!expectedInputDigest.empty() &&
             (!isLowercaseHex(expectedInputDigest) ||
              !isLowercaseHex(expectedGeometryDigest)))) {
            throw std::runtime_error(
                "expected dataset digests must be paired lowercase SHA-256 values"
            );
        }
        if (eventsOption->count() == 0) throw std::runtime_error("--events-fd is required for training");
        TrainingProfileConfig profile = trainingProfileNamed(profileName);
        if (iterationLimitOption->count() != 0) {
            profile.iterationLimit = iterationLimitOverride;
        }
        if (plateauWindowOption->count() != 0) {
            profile.plateauWindow = plateauWindowOverride;
        }
        if (profile.plateauWindow > profile.iterationLimit) {
            throw std::runtime_error("--plateau-window cannot exceed --iteration-limit");
        }
        if (!fs::is_directory(datasetPath)) throw std::runtime_error("dataset directory does not exist");
        if (fs::path(outputPath).extension() != ".ply") throw std::runtime_error("--output must end in .ply");
        msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);

        struct sigaction action {};
        action.sa_handler = observeCancellation;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0;
        if (sigaction(SIGINT, &action, nullptr) != 0 || sigaction(SIGTERM, &action, nullptr) != 0) {
            throw std::runtime_error("failed to install cancellation handlers");
        }

        // Reject the unsupported combination before touching the dataset or allocating
        // Metal state, so an unrelated input error cannot mask the contract violation.
        if (holdoutEvery > 1 && !resumePath.empty()) {
            throw std::runtime_error(
                "--resume cannot be combined with --holdout-every; the checkpoint "
                "contract does not yet identify the held-out camera split"
            );
        }

        const OrientationOverlay orientation = readOrientationOverlay(datasetPath);
        const TrainingIdentity identity = computeTrainingIdentity(
            datasetPath,
            orientation.contentDigest
        );
        if (!expectedInputDigest.empty() &&
            (identity.inputDigest != expectedInputDigest ||
             identity.geometryDigest != expectedGeometryDigest)) {
            throw std::runtime_error(
                "prepared dataset identity does not match the expected digests"
            );
        }
        const std::string trainerBuildDigest = computeTrainerBuildDigest();

        InputData inputData = inputDataFromX(datasetPath);
        applyOrientationOverlay(inputData, orientation);

        // Hold out every Nth camera so novel-view quality can be measured. Training
        // loss cannot detect a model that fits its own views while degrading between
        // them, which is precisely the failure this trainer had no signal for.
        std::vector<Camera> heldOutCameras;
        if (holdoutEvery > 1) {
            auto split = inputData.splitTrainTest(holdoutEvery);
            heldOutCameras = std::move(std::get<1>(split));
            inputData.cameras = std::move(std::get<0>(split));
        }

        std::vector<Camera> &cameras = inputData.cameras;
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
        // Screen-size splitting is an early-densification heuristic. The shipped literal
        // 4000 was tuned against the built-in profiles (3000/7000/15000 iterations), so
        // raising the budget silently shrank its share of the run: at 40000 it covered
        // 10% instead of the ~27% it had at 15000. Express it as that same fraction of
        // the growth window so every budget gets equivalent treatment.
        const int stopScreenSizeAt =
            (std::max)(refineEvery * 2, (profile.iterationLimit * 4000) / 15000);
        constexpr float splitScreenSize = 0.05f;
        constexpr float ssimWeight = 0.2f;
        constexpr float background[3] = {0.0f, 0.0f, 0.0f};
        constexpr int cameraReuseCount = 2;

        Model model(inputData, static_cast<int>(cameras.size()), profile.numDownscales,
                    resolutionSchedule, shDegree, shDegreeInterval, refineEvery,
                    warmupLength, resetAlphaEvery, densifyGradThreshold,
                    densifySizeThreshold, stopScreenSizeAt, splitScreenSize,
                    profile.iterationLimit, true, background);

        // Bound the gaussian population to what the admitted memory can hold. The
        // binding constraint is not parameter storage but a single exact-raster
        // allocation, which scales with tile intersections and so with scene density:
        // mip-NeRF 360 treehill demanded 38.2 GB at 4.52M gaussians while flowers ran
        // to 2.7M inside 14.8 GB. 10 KB per gaussian is the conservative empirical
        // envelope across both, tuned in both directions - 8000 aborted treehill, and
        // 6000 aborted it again while making flowers 30% slower for no quality gain.
        // It is calibrated, not derived: driving it from live raster pressure would be
        // the principled version. Without any bound the run aborts mid-training
        // instead of simply ceasing to grow.
        constexpr std::uint64_t kEstimatedBytesPerGaussian = 10000;
        // Never bind below this. The per-gaussian estimate is calibrated against
        // multi-gigabyte training budgets; applied to a small one it yields an absurd
        // ceiling - a 96 MB budget admits about 10k gaussians - and throttles work that
        // memory was never going to constrain. Below this floor the ceiling is inert.
        constexpr std::uint64_t kMinimumPopulationCeiling = 500000;
        if (memoryBudgetBytes > 0) {
            // Part of the budget is spent before a single gaussian exists. The raster
            // keeps six full-resolution image buffers (31 floats per pixel: colour,
            // transmittance, final index, loss intermediates, the SSIM row buffer and
            // the rendered-image gradient) plus one tile-local intersection arena of
            // MAX_TILE_ELEMS 64-bit keys per 16x16 tile. Both scale with resolution and
            // not at all with population, so charging them to the per-gaussian estimate
            // overstated the headroom - at 2304x1296 by roughly 560 MB.
            constexpr std::uint64_t kBytesPerPixel = 31 * sizeof(float);
            constexpr std::uint64_t kTileSide = 16;
            // Queried rather than duplicated: a literal here would drift silently the
            // first time MAX_TILE_ELEMS changes in the kernels.
            const std::uint64_t bytesPerTile =
                msplat_max_tile_elements() * sizeof(std::uint64_t) + 4 * sizeof(std::int32_t);
            std::uint64_t largestFixed = 0;
            bool mixedResolutions = false;
            int firstWidth = 0;
            int firstHeight = 0;
            for (const Camera &camera : cameras) {
                if (camera.width <= 0 || camera.height <= 0) continue;
                if (firstWidth == 0) {
                    firstWidth = camera.width;
                    firstHeight = camera.height;
                } else if (camera.width != firstWidth || camera.height != firstHeight) {
                    mixedResolutions = true;
                }
                const std::uint64_t w = static_cast<std::uint64_t>(camera.width);
                const std::uint64_t h = static_cast<std::uint64_t>(camera.height);
                const std::uint64_t tiles =
                    ((w + kTileSide - 1) / kTileSide) * ((h + kTileSide - 1) / kTileSide);
                largestFixed = (std::max<std::uint64_t>)(
                    largestFixed, w * h * kBytesPerPixel + tiles * bytesPerTile);
            }
            // The raster reserves the new resolution's image and tile buffers while the
            // previous ones are still resident, so a capture that alternates between
            // resolutions - portrait stills among landscape video, say - transiently
            // needs two of these. Charge for both rather than let the ceiling promise
            // headroom that a resolution switch immediately spends.
            const std::uint64_t fixedBytes =
                mixedResolutions ? 2 * largestFixed : largestFixed;
            const std::uint64_t gaussianBudget =
                memoryBudgetBytes > fixedBytes ? memoryBudgetBytes - fixedBytes : 0;
            const std::uint64_t population = (std::max<std::uint64_t>)(
                kMinimumPopulationCeiling,
                gaussianBudget / kEstimatedBytesPerGaussian
            );
            // The model bounds allocated slots, not the population, because a densify
            // pass can triple its input and the buffers never shrink. Three slots per
            // admitted gaussian preserves the calibrated ceiling above while making the
            // worst case bounded rather than open-ended.
            const std::uint64_t slots = (std::min<std::uint64_t>)(
                3 * population,
                static_cast<std::uint64_t>(std::numeric_limits<int>::max() / 4)
            );
            model.maxCapacity = static_cast<int>(slots);
        }

        std::vector<size_t> camIndices(cameras.size());
        std::iota(camIndices.begin(), camIndices.end(), 0);
        InfiniteRandomIterator<size_t> camsIter(camIndices, seed);

        const fs::path requestedCheckpointRoot(checkpointPath);
        const fs::path checkpointParent = requestedCheckpointRoot.parent_path().empty()
            ? fs::current_path()
            : requestedCheckpointRoot.parent_path();
        const fs::path checkpointRoot = fs::canonical(checkpointParent) /
            requestedCheckpointRoot.filename();
        if (!resumePath.empty()) {
            requirePlainDirectory(resumePath);
            if (fs::canonical(resumePath) != fs::canonical(checkpointRoot)) {
                throw std::runtime_error("--resume must identify the --checkpoint directory");
            }
            // The checkpoint contract records the training-camera count but not which
            // cameras were held out, and two different strides can leave the same count
            // while selecting different subsets. Until the split is versioned into the
            // manifest, refuse the combination rather than silently resume against a
            // different set of views.
            if (holdoutEvery > 1) {
                throw std::runtime_error(
                    "--resume cannot be combined with --holdout-every; the checkpoint "
                    "contract does not yet identify the held-out camera split"
                );
            }
        }
        const CheckpointContext checkpointContext {
            profile,
            seed,
            cameras.size(),
            identity,
            trainerBuildDigest,
            memoryBudgetBytes,
        };

        const auto startedAt = std::chrono::steady_clock::now();
        int plateauSampleCount = 0;
        std::vector<float> plateauLosses(lossSyncBatch);
        std::vector<std::size_t> plateauCameraIndices(lossSyncBatch);
        std::vector<double> bestCameraLosses(
            cameras.size(),
            std::numeric_limits<double>::infinity()
        );
        int lastImprovementIteration = warmupLength;
        double latestWindowLoss = std::numeric_limits<double>::quiet_NaN();
        double latestHeldOutPsnr = std::numeric_limits<double>::quiet_NaN();
        int latestHeldOutIteration = 0;
        int latestLossIteration = 0;
        int completedIteration = 0;
        double priorElapsedSeconds = 0;
        std::uint64_t restoredRasterFallbackCount = 0;
        double restoredRasterExactFallbackElapsedSeconds = 0;
        std::uint64_t restoredRasterExactBufferGrowthCount = 0;
        std::uint64_t restoredRasterExactBufferBytesAdded = 0;
        std::uint64_t restoredRasterPeakExactIntersectionCapacity = 0;
        double rasterReplayElapsedSeconds = 0;
        std::optional<CheckpointReceipt> lastCheckpoint;
        const bool resumed = !resumePath.empty();

        auto preflightRasterMemory = [&]() {
            const auto largestCamera = std::max_element(
                cameras.begin(),
                cameras.end(),
                [](const Camera &left, const Camera &right) {
                    const std::uint64_t leftPixels =
                        static_cast<std::uint64_t>(std::max(0, left.width)) *
                        static_cast<std::uint64_t>(std::max(0, left.height));
                    const std::uint64_t rightPixels =
                        static_cast<std::uint64_t>(std::max(0, right.width)) *
                        static_cast<std::uint64_t>(std::max(0, right.height));
                    return leftPixels < rightPixels;
                }
            );
            if (largestCamera == cameras.end() || largestCamera->width <= 0 ||
                largestCamera->height <= 0) {
                throw std::runtime_error("input camera dimensions are invalid");
            }
            msplat_preflight_raster_memory(
                model.num_active,
                largestCamera->height,
                largestCamera->width,
                static_cast<int>(model.featuresRest.size(-2))
            );
        };

        if (resumed) {
            std::optional<ValidatedCheckpoint> validatedCheckpoint;
            try {
                validatedCheckpoint = loadCheckpoint(model, checkpointRoot, checkpointContext);
            } catch (const CheckpointCompatibilityError &error) {
                events->emit("resume_rejected", {{"reason", error.reason()}});
                std::cerr << error.what() << '\n';
                return 78;
            }
            ValidatedCheckpoint checkpoint = std::move(*validatedCheckpoint);
            completedIteration = checkpoint.trainerState.iteration;
            lastImprovementIteration = checkpoint.trainerState.lastImprovementIteration;
            bestCameraLosses = std::move(checkpoint.trainerState.bestCameraLosses);
            if (checkpoint.trainerState.latestLoss) {
                latestWindowLoss = *checkpoint.trainerState.latestLoss;
            }
            latestLossIteration = checkpoint.trainerState.latestLossIteration;
            priorElapsedSeconds = checkpoint.trainerState.elapsedSeconds;
            restoredRasterFallbackCount = checkpoint.trainerState.rasterFallbackCount;
            restoredRasterExactFallbackElapsedSeconds =
                checkpoint.trainerState.rasterExactFallbackElapsedSeconds;
            restoredRasterExactBufferGrowthCount =
                checkpoint.trainerState.rasterExactBufferGrowthCount;
            restoredRasterExactBufferBytesAdded =
                checkpoint.trainerState.rasterExactBufferBytesAdded;
            restoredRasterPeakExactIntersectionCapacity =
                checkpoint.trainerState.rasterPeakExactIntersectionCapacity;
            rasterReplayElapsedSeconds = checkpoint.trainerState.rasterReplayElapsedSeconds;
            msplat_restore_raster_metrics(
                restoredRasterFallbackCount,
                restoredRasterExactFallbackElapsedSeconds,
                restoredRasterExactBufferGrowthCount,
                restoredRasterExactBufferBytesAdded,
                restoredRasterPeakExactIntersectionCapacity
            );
            lastCheckpoint = checkpoint.receipt;
            for (int draw = 0; draw < completedIteration / cameraReuseCount; ++draw) {
                (void)camsIter.next();
            }
        }
        const int startingIteration = completedIteration;
        std::uint64_t lastReportedFallbackCount = restoredRasterFallbackCount;
        std::uint64_t durableRasterFallbackCount = restoredRasterFallbackCount;
        double durableRasterExactFallbackElapsedSeconds =
            restoredRasterExactFallbackElapsedSeconds;
        std::uint64_t durableRasterExactBufferGrowthCount =
            restoredRasterExactBufferGrowthCount;
        std::uint64_t durableRasterExactBufferBytesAdded =
            restoredRasterExactBufferBytesAdded;
        double durableRasterReplayElapsedSeconds = rasterReplayElapsedSeconds;
        std::uint64_t durableRasterPeakExactIntersectionCapacity =
            restoredRasterPeakExactIntersectionCapacity;

        auto checkedRasterStats = [&]() {
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (stats.capacity_exceeded) {
                throw std::runtime_error(
                    "native raster capacity overflow was not replayed"
                );
            }
            if (stats.dropped_intersection_count != 0) {
                throw std::runtime_error(
                    "native raster reported dropped intersections; output publication is blocked"
                );
            }
            return stats;
        };

        auto emitRasterFallbackIfNeeded = [&](int iteration) {
            const MsplatRasterStats stats = checkedRasterStats();
            if (stats.fallback_count > lastReportedFallbackCount) {
                events->emit("raster_fallback", {
                    {"allocation_bytes", stats.allocation_bytes},
                    {"fallback_count", stats.fallback_count},
                    {"intersection_count", stats.latest_intersection_count},
                    {"iteration", iteration},
                    {"raster_exact_buffer_bytes_added", stats.exact_buffer_bytes_added},
                    {"raster_exact_buffer_growth_count", stats.exact_buffer_growth_count},
                    {"raster_exact_fallback_elapsed_seconds",
                     stats.exact_fallback_elapsed_seconds},
                    {"raster_peak_exact_intersection_capacity",
                     stats.peak_exact_intersection_capacity},
                    {"raster_replay_elapsed_seconds", rasterReplayElapsedSeconds},
                });
                lastReportedFallbackCount = stats.fallback_count;
            }
            return stats;
        };

        auto emitCheckpoint = [&](const char *eventName, const CheckpointReceipt &receipt) {
            const MsplatRasterStats stats = checkedRasterStats();
            events->emit(eventName, {
                {"checkpoint_generation", receipt.generation},
                {"checkpoint_payload_bytes", receipt.payloadBytes},
                {"checkpoint_payload_sha256", receipt.payloadDigest},
                {"gaussian_count", model.num_active},
                {"geometry_digest", identity.geometryDigest},
                {"input_digest", identity.inputDigest},
                {"iteration", receipt.iteration},
                {"memory_budget_bytes", memoryBudgetBytes},
                {"peak_memory_bytes", peakResidentMemoryBytes()},
                {"profile", profile.name},
                {"raster_exact_buffer_bytes_added", stats.exact_buffer_bytes_added},
                {"raster_exact_buffer_growth_count", stats.exact_buffer_growth_count},
                {"raster_exact_fallback_elapsed_seconds",
                 stats.exact_fallback_elapsed_seconds},
                {"raster_fallback_count", stats.fallback_count},
                {"raster_peak_exact_intersection_capacity",
                 stats.peak_exact_intersection_capacity},
                {"raster_replay_elapsed_seconds", rasterReplayElapsedSeconds},
                {"dropped_intersection_count", stats.dropped_intersection_count},
                {"seed", seed},
                {"trainer_build_digest", trainerBuildDigest},
                {"version", APP_VERSION},
            });
        };

        preflightRasterMemory();
        if (resumed && restoredRasterPeakExactIntersectionCapacity != 0) {
            msplat_restore_exact_raster_capacity(
                restoredRasterPeakExactIntersectionCapacity
            );
            const MsplatRasterStats restoredCapacity = checkedRasterStats();
            if (restoredCapacity.fallback_count != restoredRasterFallbackCount ||
                restoredCapacity.exact_fallback_elapsed_seconds !=
                    restoredRasterExactFallbackElapsedSeconds ||
                restoredCapacity.exact_buffer_growth_count !=
                    restoredRasterExactBufferGrowthCount ||
                restoredCapacity.exact_buffer_bytes_added !=
                    restoredRasterExactBufferBytesAdded ||
                restoredCapacity.peak_exact_intersection_capacity !=
                    restoredRasterPeakExactIntersectionCapacity) {
                throw std::runtime_error(
                    "restored exact raster capacity changed durable checkpoint metrics"
                );
            }
        }

        events->emit("started", {{"camera_count", cameras.size()},
                                {"checkpoint_schema", 3},
                                {"geometry_digest", identity.geometryDigest},
                                {"initial_gaussian_count", model.num_active},
                                {"input_digest", identity.inputDigest},
                                {"iteration", completedIteration},
                                {"iteration_limit", profile.iterationLimit},
                                {"memory_budget_bytes", memoryBudgetBytes},
                                {"payload_schema", 2},
                                {"plateau_window", profile.plateauWindow},
                                {"profile", profile.name},
                                {"raster_exact_buffer_bytes_added",
                                 restoredRasterExactBufferBytesAdded},
                                {"raster_exact_buffer_growth_count",
                                 restoredRasterExactBufferGrowthCount},
                                {"raster_exact_fallback_elapsed_seconds",
                                 restoredRasterExactFallbackElapsedSeconds},
                                {"raster_fallback_count", restoredRasterFallbackCount},
                                {"raster_peak_exact_intersection_capacity",
                                 restoredRasterPeakExactIntersectionCapacity},
                                {"raster_replay_elapsed_seconds", rasterReplayElapsedSeconds},
                                {"dropped_intersection_count", 0},
                                {"resumed", resumed},
                                {"seed", seed},
                                {"trainer_build_digest", trainerBuildDigest},
                                {"version", APP_VERSION}});
        terminalIteration = completedIteration;
        if (!resumed) {
            lastCheckpoint = saveCheckpoint(
                model,
                checkpointRoot,
                checkpointContext,
                TrainerCheckpointState {
                    0,
                    warmupLength,
                    bestCameraLosses,
                    std::nullopt,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                }
            );
        }
        if (!lastCheckpoint) {
            throw std::runtime_error("training did not establish a durable checkpoint");
        }
        emitCheckpoint(resumed ? "checkpoint_loaded" : "checkpoint_completed", *lastCheckpoint);

        auto lastProgressAt = startedAt;
        auto cumulativeElapsed = [&]() {
            return priorElapsedSeconds + std::chrono::duration<double>(
                std::chrono::steady_clock::now() - startedAt
            ).count();
        };
        auto handleCancellation = [&]() {
            if (cancellationSignal == 0) return false;
            events->emit("cancellation_requested", {{"iteration", completedIteration},
                                                    {"signal", cancellationSignal}});
            msplat_gpu_sync_for_raster_replay();
            events->emit("cancelled", {
                {"checkpoint_generation", lastCheckpoint->generation},
                {"checkpoint_iteration", lastCheckpoint->iteration},
                {"checkpoint_payload_sha256", lastCheckpoint->payloadDigest},
                {"geometry_digest", identity.geometryDigest},
                {"input_digest", identity.inputDigest},
                {"iteration", completedIteration},
                {"memory_budget_bytes", memoryBudgetBytes},
                {"raster_exact_buffer_bytes_added", durableRasterExactBufferBytesAdded},
                {"raster_exact_buffer_growth_count", durableRasterExactBufferGrowthCount},
                {"raster_exact_fallback_elapsed_seconds",
                 durableRasterExactFallbackElapsedSeconds},
                {"raster_fallback_count", durableRasterFallbackCount},
                {"raster_peak_exact_intersection_capacity",
                 durableRasterPeakExactIntersectionCapacity},
                {"raster_replay_elapsed_seconds", durableRasterReplayElapsedSeconds},
                {"dropped_intersection_count", 0},
            });
            return true;
        };

        if (handleCancellation()) return 130;
        std::string stopReason = "iteration_limit";
        std::size_t residentCameraIndex = std::numeric_limits<std::size_t>::max();
        int residentUsesRemaining = 0;

        auto rewindTrainingState = [&](int iteration) {
            if (iteration < 0 || iteration > profile.iterationLimit) {
                throw std::runtime_error("raster replay iteration is invalid");
            }
            if (residentCameraIndex != std::numeric_limits<std::size_t>::max()) {
                releaseCameraResources(cameras[residentCameraIndex]);
            }
            camsIter = InfiniteRandomIterator<size_t>(camIndices, seed);
            for (int draw = 0; draw < iteration / cameraReuseCount; ++draw) {
                (void)camsIter.next();
            }
            residentCameraIndex = std::numeric_limits<std::size_t>::max();
            residentUsesRemaining = 0;
            const int partialCameraGroup = iteration % cameraReuseCount;
            if (partialCameraGroup != 0) {
                residentCameraIndex = camsIter.next();
                residentUsesRemaining = cameraReuseCount - partialCameraGroup;
            }
            model.adam_step_count = iteration;
            model.schedulersStep(iteration);
            plateauSampleCount = iteration > warmupLength
                ? (iteration - warmupLength) % lossSyncBatch
                : 0;
            completedIteration = iteration;
            terminalIteration = iteration;
        };

        rewindTrainingState(completedIteration);

        auto enqueueIteration = [&](int step) {
            if (residentUsesRemaining == 0) {
                if (residentCameraIndex != std::numeric_limits<std::size_t>::max()) {
                    releaseCameraResources(cameras[residentCameraIndex]);
                }
                residentCameraIndex = camsIter.next();
                residentUsesRemaining = cameraReuseCount;
            }
            const std::size_t cameraIndex = residentCameraIndex;
            Camera &camera = cameras[cameraIndex];
            if (camera.image.empty()) {
                camera.loadImage(1.0f);
                if (camera.image.empty()) {
                    throw std::runtime_error("cannot decode training image: " + camera.filePath);
                }
            }
            --residentUsesRemaining;
            MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
            msplat_set_raster_iteration_context(step, cameraIndex);
            model.fullIteration(camera, step, target, ssimWeight);
            model.schedulersStep(step);
            if (step > warmupLength) {
                const int lossSlot = (step - warmupLength - 1) % lossSyncBatch;
                const float normalization = 1.0f /
                    static_cast<float>(model.lastHeight * model.lastWidth);
                plateauCameraIndices[lossSlot] = cameraIndex;
                msplat_record_last_loss(lossSlot, lossSyncBatch, normalization);
                plateauSampleCount = lossSlot + 1;
            }
            msplat_commit();
        };

        // Held-out evaluation. Runs only at a drained pipeline boundary, and resolves
        // any raster capacity failure inline so no evidence from a non-training camera
        // index reaches synchronizeWindow's rewind logic.
        auto evaluateHeldOut = [&](int step,
                                   std::size_t *evaluatedOut,
                                   std::string *failureOut) -> double {
            if (heldOutCameras.empty()) return std::numeric_limits<double>::quiet_NaN();
            const std::size_t count = heldOutCameras.size();
            double total = 0;
            int counted = 0;
            for (std::size_t index = 0; index < count; ++index) {
                Camera &camera = heldOutCameras[index];
                // Contained per camera: one view that cannot be rendered costs its own
                // measurement, not every measurement gathered before it. Only a pending
                // capacity failure is cleared, so an unrelated GPU or synchronization
                // fault is still visible to whatever runs next.
                try {
                    if (camera.image.empty()) {
                        camera.loadImage(1.0f);
                        if (camera.image.empty()) continue;
                    }
                    MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
                    bool measured = false;
                    for (int attempt = 0; attempt < 2 && !measured; ++attempt) {
                        MTensor rendered = model.render(camera, step);
                        msplat_commit();
                        msplat_gpu_sync_for_raster_replay();
                        const MsplatRasterStats stats = msplat_get_raster_stats();
                        if (stats.capacity_exceeded) {
                            msplat_grow_exact_raster_capacity(stats.latest_intersection_count);
                            msplat_clear_raster_capacity_failure();
                            continue;
                        }
                        total += psnr(rendered, target);
                        ++counted;
                        measured = true;
                    }
                } catch (const std::exception &error) {
                    if (failureOut && failureOut->empty()) *failureOut = error.what();
                    if (msplat_raster_memory_budget_was_exceeded()) {
                        msplat_clear_raster_capacity_failure();
                    }
                }
                releaseCameraResources(camera);
            }
            if (evaluatedOut) *evaluatedOut = static_cast<std::size_t>(counted);
            return counted > 0
                ? total / static_cast<double>(counted)
                : std::numeric_limits<double>::quiet_NaN();
        };

        auto synchronizeWindow = [&](int windowEnd) {
            int attemptEnd = windowEnd;
            bool cancellationObserved = false;
            std::optional<std::chrono::steady_clock::time_point> replayStartedAt;
            while (true) {
                msplat_gpu_sync_for_raster_replay();
                const MsplatRasterStats stats = msplat_get_raster_stats();
                if (stats.dropped_intersection_count != 0) {
                    throw std::runtime_error(
                        "native raster reported dropped intersections; output publication is blocked"
                    );
                }
                if (!stats.capacity_exceeded) {
                    if (replayStartedAt) {
                        rasterReplayElapsedSeconds += std::chrono::duration<double>(
                            std::chrono::steady_clock::now() - *replayStartedAt
                        ).count();
                    }
                    completedIteration = attemptEnd;
                    terminalIteration = attemptEnd;
                    return !cancellationObserved && attemptEnd == windowEnd;
                }
                if (stats.first_overflow_iteration == 0 ||
                    stats.first_overflow_iteration > static_cast<std::uint64_t>(attemptEnd) ||
                    stats.first_overflow_iteration <= static_cast<std::uint64_t>(completedIteration) ||
                    stats.first_overflow_camera >= cameras.size() ||
                    stats.latest_intersection_count == 0) {
                    throw std::runtime_error("native raster overflow evidence is inconsistent");
                }

                const int firstOverflow = static_cast<int>(stats.first_overflow_iteration);
                const int successfulPrefix = firstOverflow - 1;
                if (!replayStartedAt) replayStartedAt = std::chrono::steady_clock::now();
                rewindTrainingState(successfulPrefix);
                if (cancellationSignal != 0 || cancellationObserved) {
                    return false;
                }

                // Growth performs the authoritative budget and Metal-buffer checks.
                // No optimizer state after successfulPrefix was mutated: the GPU fatal
                // flag guards the failed step and every later command in this window.
                msplat_grow_exact_raster_capacity(stats.latest_intersection_count);
                const MsplatRasterStats replayStats = msplat_get_raster_stats();
                if (replayStats.required_bytes == 0 ||
                    replayStats.required_bytes > replayStats.budget_bytes) {
                    throw std::runtime_error(
                        "native raster grow returned invalid allocation evidence"
                    );
                }
                events->emit("raster_replay", {
                    {"budget_bytes", replayStats.budget_bytes},
                    {"camera_index", stats.first_overflow_camera},
                    {"first_overflow_iteration", stats.first_overflow_iteration},
                    {"intersection_count", stats.latest_intersection_count},
                    {"iteration", successfulPrefix},
                    {"required_bytes", replayStats.required_bytes},
                });
                msplat_clear_raster_capacity_failure();

                attemptEnd = successfulPrefix;
                for (int replayStep = firstOverflow; replayStep <= windowEnd; ++replayStep) {
                    if (cancellationSignal != 0) {
                        cancellationObserved = true;
                        break;
                    }
                    enqueueIteration(replayStep);
                    attemptEnd = replayStep;
                }
                if (attemptEnd == successfulPrefix) {
                    return false;
                }
            }
        };

        for (int step = completedIteration + 1; step <= profile.iterationLimit; ++step) {
            enqueueIteration(step);

            const bool windowComplete = step % refineEvery == 0 ||
                step == profile.iterationLimit;
            if (!windowComplete) continue;
            if (!synchronizeWindow(step)) {
                if (handleCancellation()) return 130;
                throw std::runtime_error("raster replay stopped before completing its window");
            }
            model.afterTrain(step);

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

            if (handleCancellation()) return 130;

            auto now = std::chrono::steady_clock::now();
            if (step == profile.iterationLimit || now - lastProgressAt >= std::chrono::seconds(1)) {
                emitRasterFallbackIfNeeded(step);
                now = std::chrono::steady_clock::now();
                const double sessionElapsed = std::chrono::duration<double>(now - startedAt).count();
                const double elapsed = priorElapsedSeconds + sessionElapsed;
                const int sessionIterations = step - startingIteration;
                const double rate = sessionElapsed > 0
                    ? static_cast<double>(sessionIterations) / sessionElapsed
                    : 0;
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
                events->emit("progress", std::move(progress));
                lastProgressAt = now;
            }

            if (plateauReached && step < profile.iterationLimit) {
                stopReason = "plateau";
                events->emit("early_stop", {{"iteration", step},
                                           {"last_improvement_iteration", lastImprovementIteration},
                                           {"loss", latestWindowLoss},
                                           {"loss_iteration", latestLossIteration},
                                           {"plateau_window", profile.plateauWindow},
                                           {"reason", stopReason}});
                break;
            }

            constexpr int checkpointInterval = 500;
            if (step < profile.iterationLimit && step % checkpointInterval == 0) {
                if (plateauSampleCount != 0) {
                    throw std::runtime_error("checkpoint cadence split a pending loss batch");
                }
                const MsplatRasterStats stats = emitRasterFallbackIfNeeded(step);
                lastCheckpoint = saveCheckpoint(
                    model,
                    checkpointRoot,
                    checkpointContext,
                    TrainerCheckpointState {
                        step,
                        lastImprovementIteration,
                        bestCameraLosses,
                        std::isfinite(latestWindowLoss)
                            ? std::optional<double>(latestWindowLoss)
                            : std::nullopt,
                        latestLossIteration,
                        cumulativeElapsed(),
                        stats.fallback_count,
                        stats.dropped_intersection_count,
                        stats.exact_fallback_elapsed_seconds,
                        stats.exact_buffer_growth_count,
                        stats.exact_buffer_bytes_added,
                        rasterReplayElapsedSeconds,
                        stats.peak_exact_intersection_capacity,
                    }
                );
                durableRasterFallbackCount = stats.fallback_count;
                durableRasterExactFallbackElapsedSeconds =
                    stats.exact_fallback_elapsed_seconds;
                durableRasterExactBufferGrowthCount = stats.exact_buffer_growth_count;
                durableRasterExactBufferBytesAdded = stats.exact_buffer_bytes_added;
                durableRasterReplayElapsedSeconds = rasterReplayElapsedSeconds;
                durableRasterPeakExactIntersectionCapacity =
                    stats.peak_exact_intersection_capacity;
                emitCheckpoint("checkpoint_completed", *lastCheckpoint);
                if (handleCancellation()) return 130;
            }
        }

        if (handleCancellation()) return 130;

        const SceneBounds sceneBounds = robustSceneBounds(model);
        if (!savePlyAtomically(model, outputPath, completedIteration)) {
            if (handleCancellation()) return 130;
            throw std::runtime_error("final output was not published");
        }
        // Snapshot training raster telemetry before any validation render, so held-out
        // work cannot inflate the fallback counts the completed event reports. Those
        // counts must never regress below the last checkpoint's, and a validation
        // render after the snapshot would attribute non-training work to training.
        const MsplatRasterStats finalRasterStats =
            emitRasterFallbackIfNeeded(completedIteration);

        // Validation is a measurement and must never fail the thing it measures. A
        // held-out view can demand exact-raster growth that throws on the memory
        // budget; the model is already published, so swallow it and report what was
        // actually evaluated rather than losing a finished run.
        if (!heldOutCameras.empty()) {
            std::size_t evaluated = 0;
            std::string failure;
            double heldOutPsnr = std::numeric_limits<double>::quiet_NaN();
            try {
                heldOutPsnr = evaluateHeldOut(completedIteration, &evaluated, &failure);
            } catch (const std::exception &error) {
                if (failure.empty()) failure = error.what();
                if (msplat_raster_memory_budget_was_exceeded()) {
                    msplat_clear_raster_capacity_failure();
                }
            }
            const bool usable = std::isfinite(heldOutPsnr) && evaluated > 0;
            if (usable) {
                latestHeldOutPsnr = heldOutPsnr;
                latestHeldOutIteration = completedIteration;
            }
            if (!failure.empty()) {
                fprintf(stderr, "held-out evaluation incomplete (%zu of %zu views): %s\n",
                        evaluated, heldOutCameras.size(), failure.c_str());
            }
            // Emitted unconditionally. A missing event would be indistinguishable from
            // validation never having been requested, which is the one thing a quality
            // signal must not be ambiguous about.
            json holdout = {
                {"iteration", completedIteration},
                {"holdout_camera_count", static_cast<int>(heldOutCameras.size())},
                {"holdout_evaluated", static_cast<int>(evaluated)},
                {"full_set", evaluated == heldOutCameras.size()},
                {"status", failure.empty() ? (usable ? "ok" : "empty") : "partial"}
            };
            if (usable) holdout["holdout_psnr"] = heldOutPsnr;
            if (!failure.empty()) holdout["failure"] = failure;
            events->emit("holdout_eval", holdout);
        }

        const std::uintmax_t outputBytes = fs::file_size(outputPath);
        const double elapsed = cumulativeElapsed();

        json completed = {{"elapsed_seconds", elapsed},
                          {"gaussian_count", model.num_active},
                          {"geometry_digest", identity.geometryDigest},
                          {"input_digest", identity.inputDigest},
                          {"iteration", completedIteration},
                          {"iteration_limit", profile.iterationLimit},
                          {"memory_budget_bytes", memoryBudgetBytes},
                          {"output_bytes", outputBytes},
                          {"peak_memory_bytes", peakResidentMemoryBytes()},
                          {"plateau_window", profile.plateauWindow},
                          {"profile", profile.name},
                          {"raster_exact_buffer_bytes_added",
                           finalRasterStats.exact_buffer_bytes_added},
                          {"raster_exact_buffer_growth_count",
                           finalRasterStats.exact_buffer_growth_count},
                          {"raster_exact_fallback_elapsed_seconds",
                           finalRasterStats.exact_fallback_elapsed_seconds},
                          {"raster_fallback_count", finalRasterStats.fallback_count},
                          {"raster_peak_exact_intersection_capacity",
                           finalRasterStats.peak_exact_intersection_capacity},
                          {"raster_replay_elapsed_seconds", rasterReplayElapsedSeconds},
                          {"dropped_intersection_count",
                           finalRasterStats.dropped_intersection_count},
                          {"scene_center", sceneBounds.center},
                          {"scene_radius", sceneBounds.radius},
                          {"seed", seed},
                          {"stop_reason", stopReason},
                          {"trainer_build_digest", trainerBuildDigest},
                          {"version", APP_VERSION}};
        if (std::isfinite(latestHeldOutPsnr)) {
            completed["holdout_psnr"] = latestHeldOutPsnr;
            completed["holdout_psnr_iteration"] = latestHeldOutIteration;
            completed["holdout_camera_count"] = static_cast<int>(heldOutCameras.size());
        }
        events->emit("completed", completed);
        if (!events->enabled()) std::cout << "EasySplat training completed: " << outputPath << '\n';
        return 0;
    } catch (const easysplat::isolation::CancellationError &error) {
        if (events && isolationEventEmissionSafe) {
            try {
                events->emit("isolation_cancelled", {
                    {"signal", cancellationSignal},
                    {"status", "cancelled"},
                });
            } catch (const std::exception &eventError) {
                std::cerr << "easysplat-train: cannot report subject-isolation cancellation: "
                          << eventError.what() << '\n';
            }
        }
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return 130;
    } catch (const easysplat::isolation::MemoryLimitError &error) {
        if (isolate && events && isolationEventEmissionSafe) {
            try {
                events->emit("isolation_memory_refused", {
                    {"budget_bytes", memoryBudgetBytes},
                    {"reason", "working_set"},
                    {"status", "refused"},
                });
            } catch (const std::exception &eventError) {
                std::cerr << "easysplat-train: cannot report subject-isolation memory refusal: "
                          << eventError.what() << '\n';
            }
        }
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return isolate ? 75 : 1;
    } catch (const std::exception &error) {
        if (isolate &&
            (msplat_raster_resource_limit_was_exceeded() ||
             msplat_raster_memory_budget_was_exceeded())) {
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (events && isolationEventEmissionSafe) {
                try {
                    json fields = {
                        {"allocation_bytes", stats.allocation_bytes},
                        {"budget_bytes", memoryBudgetBytes},
                        {"reason",
                         msplat_raster_resource_limit_was_exceeded()
                             ? "resource_limit"
                             : "memory_budget"},
                        {"required_bytes", stats.required_bytes},
                        {"status", "refused"},
                    };
                    if (stats.latest_intersection_count > 0) {
                        fields["intersection_count"] = stats.latest_intersection_count;
                    }
                    events->emit("isolation_memory_refused", std::move(fields));
                } catch (const std::exception &eventError) {
                    std::cerr << "easysplat-train: cannot report subject-isolation memory refusal: "
                              << eventError.what() << '\n';
                }
            }
            std::cerr << "easysplat-train: " << error.what() << '\n';
            return 75;
        }
        if (isolate) {
            if (events && isolationEventEmissionSafe) {
                try {
                    events->emit("isolation_failed", {
                        {"message", error.what()},
                        {"status", "failed"},
                    });
                } catch (const std::exception &eventError) {
                    std::cerr << "easysplat-train: cannot report subject-isolation failure: "
                              << eventError.what() << '\n';
                }
            }
            std::cerr << "easysplat-train: " << error.what() << '\n';
            return 1;
        }
        if (msplat_raster_resource_limit_was_exceeded()) {
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (events) {
                try {
                    json fields = {
                        {"allocation_bytes", stats.allocation_bytes},
                        {"iteration", terminalIteration},
                        {"max_buffer_bytes", stats.max_buffer_bytes},
                        {"required_bytes", stats.required_bytes},
                    };
                    if (stats.latest_intersection_count > 0) {
                        fields["intersection_count"] = stats.latest_intersection_count;
                    }
                    events->emit("raster_resource_limit_exceeded", std::move(fields));
                } catch (const std::exception &eventError) {
                    std::cerr << "easysplat-train: cannot report raster resource failure: "
                              << eventError.what() << '\n';
                }
            }
            std::cerr << "easysplat-train: " << error.what() << '\n';
            return 75;
        }
        if (msplat_raster_memory_budget_was_exceeded()) {
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (events) {
                try {
                    json fields = {
                        {"allocation_bytes", stats.allocation_bytes},
                        {"budget_bytes", stats.budget_bytes},
                        {"iteration", terminalIteration},
                        {"required_bytes", stats.required_bytes},
                    };
                    if (stats.latest_intersection_count > 0) {
                        fields["intersection_count"] = stats.latest_intersection_count;
                    }
                    events->emit("raster_memory_budget_exceeded", std::move(fields));
                } catch (const std::exception &eventError) {
                    std::cerr << "easysplat-train: cannot report raster budget failure: "
                              << eventError.what() << '\n';
                }
            }
            std::cerr << "easysplat-train: " << error.what() << '\n';
            return 75;
        }
        std::cerr << "easysplat-train: " << error.what() << '\n';
        return 1;
    }
}
