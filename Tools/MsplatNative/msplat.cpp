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
#include <cstring>
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

std::string computeTrainerBuildDigest() {
    std::uint32_t capacity = 0;
    if (_NSGetExecutablePath(nullptr, &capacity) != -1 || capacity == 0 || capacity > 1024 * 1024) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    std::vector<char> buffer(capacity);
    if (_NSGetExecutablePath(buffer.data(), &capacity) != 0) {
        throw std::runtime_error("cannot resolve trainer executable path");
    }
    const fs::path executable = fs::canonical(fs::path(buffer.data()));
    const fs::path directory = executable.parent_path();
    return digestFiles(
        directory,
        {executable.filename().string(), "default.metallib"}
    );
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
        "[0.9238795325112867,0,0,0.3826834323650898]}"
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

    InputData inputData;
    inputData.scale = 2;
    inputData.translation[0] = 3;
    inputData.translation[1] = 4;
    inputData.translation[2] = 5;
    inputData.points.count = 1;
    inputData.points.xyz = {1, 0, 0};
    inputData.points.rgb = {0, 0, 0};
    for (float centerSign : {1.0f, -1.0f}) {
        Camera camera;
        camera.camToWorld[0] = 1;
        camera.camToWorld[5] = 1;
        camera.camToWorld[10] = 1;
        camera.camToWorld[15] = 1;
        camera.camToWorld[3] = centerSign;
        camera.camToWorld[7] = centerSign;
        inputData.cameras.push_back(std::move(camera));
    }

    applyOrientationOverlay(inputData, orientation);
    const auto approximately = [](double actual, double expected) {
        return std::abs(actual - expected) <= 2.0e-6;
    };
    const double inverseRootTwo = 1.0 / std::sqrt(2.0);
    const Camera &camera = inputData.cameras.front();
    if (!approximately(camera.camToWorld[0], inverseRootTwo) ||
        !approximately(camera.camToWorld[1], -inverseRootTwo) ||
        !approximately(camera.camToWorld[4], inverseRootTwo) ||
        !approximately(camera.camToWorld[5], inverseRootTwo) ||
        !approximately(camera.camToWorld[3], 0) ||
        !approximately(camera.camToWorld[7], 1) ||
        !approximately(inputData.points.xyz[0], 0.5) ||
        !approximately(inputData.points.xyz[1], 0.5) ||
        !approximately(inputData.scale, std::sqrt(2.0)) ||
        !approximately(inputData.translation[0], -inverseRootTwo) ||
        !approximately(inputData.translation[1], 7.0 * inverseRootTwo) ||
        !approximately(inputData.translation[2], 5)) {
        throw std::runtime_error("orientation transform self-check failed");
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
    CLI::App app{"EasySplat native msplat trainer"};
    app.set_help_flag("-h,--help", "Show this help message");
    app.set_version_flag("--version", APP_VERSION);

    std::string datasetPath;
    std::string outputPath;
    std::string profileName;
    std::string checkpointPath;
    std::string resumePath;
    std::string expectedInputDigest;
    std::string expectedGeometryDigest;
    std::uint64_t seed = 42;
    std::uint64_t memoryBudgetBytes = 0;
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
    CLI::Option *memoryBudgetOption = app.add_option(
        "--memory-budget-bytes",
        memoryBudgetBytes,
        "Maximum bytes available to the native raster working set"
    );
    CLI::Option *checkpointOption = app.add_option(
        "--checkpoint", checkpointPath, "Atomic optimizer-checkpoint directory"
    );
    app.add_option(
        "--expected-input-digest",
        expectedInputDigest,
        "Expected SHA-256 digest of the prepared training images"
    );
    app.add_option(
        "--expected-geometry-digest",
        expectedGeometryDigest,
        "Expected SHA-256 digest of the prepared sparse geometry"
    );
    app.add_option("--resume", resumePath, "Validated optimizer-checkpoint directory");
    CLI::Option *eventsOption = app.add_option(
        "--events-fd", eventsFileDescriptor, "Descriptor for schema-v2 JSONL events"
    );
    eventsOption->check(CLI::Range(0, std::numeric_limits<int>::max()));
    app.add_flag("--self-check", selfCheck, "Initialize Metal and load the adjacent metallib");
    app.add_option("--validate-ply", plyToValidate, "Validate a binary Gaussian PLY")
        ->check(CLI::ExistingFile);

    CLI11_PARSE(app, argc, argv);

    std::optional<EventWriter> events;
    int terminalIteration = 0;
    try {
        struct sigaction ignoreBrokenPipe {};
        ignoreBrokenPipe.sa_handler = SIG_IGN;
        sigemptyset(&ignoreBrokenPipe.sa_mask);
        ignoreBrokenPipe.sa_flags = 0;
        if (sigaction(SIGPIPE, &ignoreBrokenPipe, nullptr) != 0) {
            throw std::runtime_error("failed to configure event-pipe handling");
        }
        events.emplace(eventsFileDescriptor);
        if (eventsFileDescriptor == STDOUT_FILENO) std::cout.rdbuf(std::cerr.rdbuf());

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
        const TrainingProfileConfig &profile = trainingProfileNamed(profileName);
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
        constexpr int stopScreenSizeAt = 4000;
        constexpr float splitScreenSize = 0.05f;
        constexpr float ssimWeight = 0.2f;
        constexpr float background[3] = {0.0f, 0.0f, 0.0f};
        constexpr int cameraReuseCount = 2;

        Model model(inputData, static_cast<int>(cameras.size()), profile.numDownscales,
                    resolutionSchedule, shDegree, shDegreeInterval, refineEvery,
                    warmupLength, resetAlphaEvery, densifyGradThreshold,
                    densifySizeThreshold, stopScreenSizeAt, splitScreenSize,
                    profile.iterationLimit, true, background);

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
        const MsplatRasterStats finalRasterStats =
            emitRasterFallbackIfNeeded(completedIteration);
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
        events->emit("completed", completed);
        if (!events->enabled()) std::cout << "EasySplat training completed: " << outputPath << '\n';
        return 0;
    } catch (const std::exception &error) {
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
