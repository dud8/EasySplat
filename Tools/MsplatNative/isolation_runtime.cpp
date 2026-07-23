// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include "isolation_runtime.hpp"

#include "bindings.h"
#include "isolation_mask.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <limits>
#include <numeric>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <tuple>
#include <unistd.h>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace easysplat::isolation {
namespace {

constexpr std::size_t kMaximumViewCount = 24;
constexpr std::size_t kMaximumMaskPixels = 4096U * 4096U;
constexpr std::size_t kStripeTargetBytes = 64U * 1024U * 1024U;
constexpr std::size_t kStripeBytesPerPixel =
    sizeof(MsplatIsolationContributionRecord) *
        MSPLAT_ISOLATION_RECORDS_PER_PIXEL +
    sizeof(std::uint32_t) +
    sizeof(float);

struct FileIdentity {
    std::uint64_t device = 0;
    std::uint64_t inode = 0;
    std::uint64_t bytes = 0;
    std::int64_t modificationSeconds = 0;
    std::int64_t modificationNanoseconds = 0;
    std::int64_t changeSeconds = 0;
    std::int64_t changeNanoseconds = 0;
};

struct FileDigest {
    std::string sha256;
    FileIdentity identity;
};

struct IsolationPath {
    fs::path path;
    std::string description;
};

struct InferenceGaussians {
    BinaryPly source;
    std::vector<Point3> positions;
    std::vector<Point3> outputPositions;
    std::vector<std::array<float, 3>> outputLogScales;
    std::vector<float> opacityLogits;
    MTensor means;
    MTensor scales;
    MTensor quaternions;
    MTensor featuresDc;
    MTensor featuresRest;
    MTensor opacities;
    MTensor background;
};

struct PreparedCamera {
    MTensor viewMatrix;
    MTensor projectionViewMatrix;
    float fx = 0;
    float fy = 0;
    float cx = 0;
    float cy = 0;
    unsigned width = 0;
    unsigned height = 0;
    std::tuple<int, int, int> tileBounds;
    std::array<float, 3> position {};
};

struct StripeBuffers {
    std::size_t rowCapacity = 0;
    MTensor records;
    MTensor counts;
    MTensor alpha;
    MTensor status;
};

void checkCancellation(const std::function<bool()> &isCancelled) {
    if (isCancelled && isCancelled()) throw CancellationError();
}

void closeDescriptor(int &descriptor) noexcept {
    if (descriptor < 0) return;
    const int openDescriptor = descriptor;
    descriptor = -1;
    (void)::close(openDescriptor);
}

std::size_t checkedAdd(
    std::size_t left,
    std::size_t right,
    const char *description
) {
    if (right > std::numeric_limits<std::size_t>::max() - left) {
        throw MemoryLimitError(std::string(description) + " exceeds the native range");
    }
    return left + right;
}

std::size_t checkedMultiply(
    std::size_t left,
    std::size_t right,
    const char *description
) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) {
        throw MemoryLimitError(std::string(description) + " exceeds the native range");
    }
    return left * right;
}

bool isLowercaseDigest(const std::string &value) {
    return value.size() == 64 &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f');
        });
}

bool stableFileIdentity(
    const FileIdentity &identity,
    const struct stat &status
) {
    return S_ISREG(status.st_mode) &&
        status.st_nlink == 1 &&
        static_cast<std::uint64_t>(status.st_dev) == identity.device &&
        static_cast<std::uint64_t>(status.st_ino) == identity.inode &&
        status.st_size >= 0 &&
        static_cast<std::uint64_t>(status.st_size) == identity.bytes &&
        status.st_mtimespec.tv_sec == identity.modificationSeconds &&
        status.st_mtimespec.tv_nsec == identity.modificationNanoseconds &&
        status.st_ctimespec.tv_sec == identity.changeSeconds &&
        status.st_ctimespec.tv_nsec == identity.changeNanoseconds;
}

FileIdentity fileIdentity(const struct stat &status) {
    if (!S_ISREG(status.st_mode) || status.st_nlink != 1 || status.st_size < 0) {
        throw std::runtime_error("isolation input must be a regular single-link file");
    }
    return FileIdentity {
        static_cast<std::uint64_t>(status.st_dev),
        static_cast<std::uint64_t>(status.st_ino),
        static_cast<std::uint64_t>(status.st_size),
        status.st_mtimespec.tv_sec,
        status.st_mtimespec.tv_nsec,
        status.st_ctimespec.tv_sec,
        status.st_ctimespec.tv_nsec,
    };
}

fs::path resolvedPathKey(const fs::path &path) {
    if (path.empty() || path.filename().empty()) {
        throw std::invalid_argument("isolation path is empty or has no filename");
    }
    const fs::path absolute = fs::absolute(path).lexically_normal();
    const fs::path parent = absolute.parent_path();
    if (parent.empty()) {
        throw std::invalid_argument("isolation path has no parent directory");
    }
    try {
        return (fs::canonical(parent) / absolute.filename()).lexically_normal();
    } catch (const fs::filesystem_error &) {
        throw std::invalid_argument(
            "isolation path parent is unavailable: " + path.string()
        );
    }
}

void requireDistinctIsolationPaths(
    const std::vector<IsolationPath> &paths,
    const std::optional<std::pair<std::uint64_t, std::uint64_t>>
        &eventFileIdentity
) {
    struct CheckedPath {
        fs::path resolved;
        std::optional<std::pair<std::uint64_t, std::uint64_t>> identity;
        std::string description;
    };

    std::vector<CheckedPath> checked;
    checked.reserve(paths.size());
    for (const IsolationPath &candidate : paths) {
        CheckedPath value;
        value.resolved = resolvedPathKey(candidate.path);
        value.description = candidate.description;
        struct stat status {};
        if (::lstat(candidate.path.c_str(), &status) == 0) {
            value.identity = std::make_pair(
                static_cast<std::uint64_t>(status.st_dev),
                static_cast<std::uint64_t>(status.st_ino)
            );
        } else if (errno != ENOENT) {
            throw std::invalid_argument(
                "cannot inspect " + candidate.description + " path"
            );
        }
        checked.push_back(std::move(value));
    }

    for (std::size_t left = 0; left < checked.size(); ++left) {
        if (eventFileIdentity.has_value() &&
            checked[left].identity == eventFileIdentity) {
            throw std::invalid_argument(
                "event file descriptor and " +
                checked[left].description +
                " must be distinct"
            );
        }
        for (std::size_t right = left + 1; right < checked.size(); ++right) {
            const bool sameResolvedPath =
                checked[left].resolved == checked[right].resolved;
            const bool sameExistingFile =
                checked[left].identity.has_value() &&
                checked[right].identity.has_value() &&
                checked[left].identity == checked[right].identity;
            if (sameResolvedPath || sameExistingFile) {
                throw std::invalid_argument(
                    checked[left].description + " and " +
                    checked[right].description + " must be distinct"
                );
            }
        }
    }
}

std::string finishSha256(CC_SHA256_CTX &context) {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CC_SHA256_Final(digest.data(), &context) != 1) {
        throw std::runtime_error("cannot finish isolation SHA-256");
    }
#pragma clang diagnostic pop
    std::ostringstream encoded;
    encoded << std::hex << std::setfill('0');
    for (unsigned char byte : digest) {
        encoded << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return encoded.str();
}

FileDigest hashRegularFile(
    const fs::path &path,
    const std::function<bool()> &isCancelled
) {
    checkCancellation(isCancelled);
    int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        throw std::runtime_error(
            "cannot open isolation input: " + std::string(std::strerror(errno))
        );
    }
    try {
        struct stat initial {};
        struct stat pathInitial {};
        if (::fstat(descriptor, &initial) != 0 ||
            ::lstat(path.c_str(), &pathInitial) != 0) {
            throw std::runtime_error("cannot inspect isolation input");
        }
        const FileIdentity identity = fileIdentity(initial);
        if (!stableFileIdentity(identity, pathInitial)) {
            throw std::runtime_error("isolation input changed while opening");
        }

        CC_SHA256_CTX context {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (CC_SHA256_Init(&context) != 1) {
            throw std::runtime_error("cannot initialize isolation SHA-256");
        }
#pragma clang diagnostic pop
        std::array<std::uint8_t, 1024 * 1024> bytes {};
        std::uint64_t consumed = 0;
        while (true) {
            checkCancellation(isCancelled);
            const ssize_t count = ::read(descriptor, bytes.data(), bytes.size());
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) throw std::runtime_error("cannot hash isolation input");
            if (count == 0) break;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (CC_SHA256_Update(
                    &context,
                    bytes.data(),
                    static_cast<CC_LONG>(count)
                ) != 1) {
                throw std::runtime_error("cannot update isolation SHA-256");
            }
#pragma clang diagnostic pop
            consumed += static_cast<std::uint64_t>(count);
        }
        if (consumed != identity.bytes) {
            throw std::runtime_error("isolation input changed while hashing");
        }
        struct stat finalStatus {};
        struct stat pathFinal {};
        if (::fstat(descriptor, &finalStatus) != 0 ||
            ::lstat(path.c_str(), &pathFinal) != 0 ||
            !stableFileIdentity(identity, finalStatus) ||
            !stableFileIdentity(identity, pathFinal)) {
            throw std::runtime_error("isolation input changed while hashing");
        }
        const std::string digest = finishSha256(context);
        closeDescriptor(descriptor);
        checkCancellation(isCancelled);
        return {digest, identity};
    } catch (...) {
        closeDescriptor(descriptor);
        throw;
    }
}

void requireUnchangedFile(
    const fs::path &path,
    const FileDigest &expected,
    const std::function<bool()> &isCancelled
) {
    const FileDigest actual = hashRegularFile(path, isCancelled);
    if (actual.sha256 != expected.sha256 ||
        actual.identity.device != expected.identity.device ||
        actual.identity.inode != expected.identity.inode ||
        actual.identity.bytes != expected.identity.bytes ||
        actual.identity.modificationSeconds !=
            expected.identity.modificationSeconds ||
        actual.identity.modificationNanoseconds !=
            expected.identity.modificationNanoseconds ||
        actual.identity.changeSeconds != expected.identity.changeSeconds ||
        actual.identity.changeNanoseconds != expected.identity.changeNanoseconds) {
        throw std::runtime_error("source PLY changed during subject isolation");
    }
}

void readExactAt(
    int descriptor,
    void *destination,
    std::size_t count,
    std::uint64_t offset,
    const std::function<bool()> &isCancelled
) {
    auto *bytes = static_cast<std::uint8_t *>(destination);
    std::size_t completed = 0;
    while (completed < count) {
        checkCancellation(isCancelled);
        const ssize_t amount = ::pread(
            descriptor,
            bytes + completed,
            count - completed,
            static_cast<off_t>(offset + completed)
        );
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) throw PlyValidationError("source PLY ended during inference load");
        completed += static_cast<std::size_t>(amount);
    }
}

float rowFloat(const std::vector<std::uint8_t> &row, std::size_t offset) {
    float result = 0;
    std::memcpy(&result, row.data() + offset, sizeof(result));
    return result;
}

std::string cameraIdentity(const Camera &camera) {
    return fs::path(camera.filePath).filename().string();
}

PreparedCamera prepareCamera(const Camera &camera) {
    if (camera.width <= 0 || camera.height <= 0 ||
        camera.width > 4096 || camera.height > 4096 ||
        !std::isfinite(camera.fx) || camera.fx <= 0 ||
        !std::isfinite(camera.fy) || camera.fy <= 0 ||
        !std::isfinite(camera.cx) || !std::isfinite(camera.cy)) {
        throw std::runtime_error("isolation camera intrinsics are invalid");
    }
    for (float value : camera.camToWorld) {
        if (!std::isfinite(value)) {
            throw std::runtime_error("isolation camera pose is not finite");
        }
    }
    if (camera.camToWorld[12] != 0 || camera.camToWorld[13] != 0 ||
        camera.camToWorld[14] != 0 || camera.camToWorld[15] != 1) {
        throw std::runtime_error("isolation camera pose is not affine");
    }

    PreparedCamera result;
    result.width = static_cast<unsigned>(camera.width);
    result.height = static_cast<unsigned>(camera.height);
    result.fx = camera.fx;
    result.fy = camera.fy;
    result.cx = camera.cx;
    result.cy = camera.cy;
    const float fovX =
        2.0f * std::atan(static_cast<float>(camera.width) / (2.0f * camera.fx));
    const float fovY =
        2.0f * std::atan(static_cast<float>(camera.height) / (2.0f * camera.fy));
    if (!std::isfinite(fovX) || !std::isfinite(fovY) ||
        fovX <= 0 || fovY <= 0) {
        throw std::runtime_error("isolation camera field of view is invalid");
    }

    const float *source = camera.camToWorld;
    float rotation[3][3] {};
    float inverseRotation[3][3] {};
    float translation[3] {};
    float inverseTranslation[3] {};
    for (int row = 0; row < 3; ++row) {
        rotation[row][0] = source[row * 4];
        rotation[row][1] = -source[row * 4 + 1];
        rotation[row][2] = -source[row * 4 + 2];
        translation[row] = source[row * 4 + 3];
    }
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            inverseRotation[row][column] = rotation[column][row];
        }
        inverseTranslation[row] = -(
            inverseRotation[row][0] * translation[0] +
            inverseRotation[row][1] * translation[1] +
            inverseRotation[row][2] * translation[2]
        );
    }
    const float view[16] = {
        inverseRotation[0][0], inverseRotation[0][1],
        inverseRotation[0][2], inverseTranslation[0],
        inverseRotation[1][0], inverseRotation[1][1],
        inverseRotation[1][2], inverseTranslation[1],
        inverseRotation[2][0], inverseRotation[2][1],
        inverseRotation[2][2], inverseTranslation[2],
        0, 0, 0, 1,
    };
    constexpr float nearPlane = 0.001f;
    constexpr float farPlane = 1000.0f;
    const float top = nearPlane * std::tan(0.5f * fovY);
    const float right = nearPlane * std::tan(0.5f * fovX);
    if (!std::isfinite(top) || top <= 0 ||
        !std::isfinite(right) || right <= 0) {
        throw std::runtime_error("isolation camera projection is invalid");
    }
    const float projection[16] = {
        nearPlane / right, 0, 0, 0,
        0, nearPlane / top, 0, 0,
        0, 0, (farPlane + nearPlane) / (farPlane - nearPlane),
        -farPlane * nearPlane / (farPlane - nearPlane),
        0, 0, 1, 0,
    };
    float projectionView[16] {};
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            for (int inner = 0; inner < 4; ++inner) {
                projectionView[row * 4 + column] +=
                    projection[row * 4 + inner] *
                    view[inner * 4 + column];
            }
        }
    }
    result.viewMatrix = gpu_empty({4, 4}, DType::Float32);
    result.projectionViewMatrix = gpu_empty({4, 4}, DType::Float32);
    std::memcpy(result.viewMatrix.data_ptr(), view, sizeof(view));
    std::memcpy(
        result.projectionViewMatrix.data_ptr(),
        projectionView,
        sizeof(projectionView)
    );
    result.position = {translation[0], translation[1], translation[2]};
    result.tileBounds = std::make_tuple(
        (camera.width + 15) / 16,
        (camera.height + 15) / 16,
        1
    );
    return result;
}

InferenceGaussians loadInferenceGaussians(
    const BinaryPly &source,
    const FileDigest &authenticatedSource,
    const InputData &inputData,
    const std::function<bool()> &isCancelled
) {
    if (source.vertexCount == 0 ||
        source.vertexCount >
            static_cast<std::uint64_t>(std::numeric_limits<int>::max()) ||
        source.finiteFloatOffsets.size() != 14 ||
        !std::isfinite(inputData.scale) || inputData.scale <= 0) {
        throw PlyValidationError("source PLY cannot be loaded for isolation inference");
    }
    for (float value : inputData.translation) {
        if (!std::isfinite(value)) {
            throw PlyValidationError("dataset normalization is invalid");
        }
    }
    const std::size_t count = static_cast<std::size_t>(source.vertexCount);
    InferenceGaussians result;
    result.source = source;
    result.positions.resize(count);
    result.outputPositions.resize(count);
    result.outputLogScales.resize(count);
    result.opacityLogits.resize(count);
    result.means = gpu_empty(
        {static_cast<std::int64_t>(count), 3},
        DType::Float32
    );
    result.scales = gpu_empty(
        {static_cast<std::int64_t>(count), 3},
        DType::Float32
    );
    result.quaternions = gpu_empty(
        {static_cast<std::int64_t>(count), 4},
        DType::Float32
    );
    result.featuresDc = gpu_empty(
        {static_cast<std::int64_t>(count), 3},
        DType::Float32
    );
    result.featuresRest = gpu_zeros(
        {static_cast<std::int64_t>(count), 0, 3},
        DType::Float32
    );
    result.opacities = gpu_empty(
        {static_cast<std::int64_t>(count), 1},
        DType::Float32
    );
    result.background = gpu_zeros({3}, DType::Float32);

    float *means = result.means.data<float>();
    float *scales = result.scales.data<float>();
    float *quaternions = result.quaternions.data<float>();
    float *featuresDc = result.featuresDc.data<float>();
    float *opacities = result.opacities.data<float>();
    const float logScale = std::log(inputData.scale);
    if (!std::isfinite(logScale)) {
        throw PlyValidationError("dataset normalization scale is invalid");
    }

    int descriptor =
        ::open(source.path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        throw PlyValidationError("cannot reopen source PLY for inference");
    }
    try {
        struct stat status {};
        if (::fstat(descriptor, &status) != 0 ||
            !stableFileIdentity(authenticatedSource.identity, status) ||
            static_cast<std::uint64_t>(status.st_dev) != source.sourceDevice ||
            static_cast<std::uint64_t>(status.st_ino) != source.sourceInode ||
            static_cast<std::uint64_t>(status.st_size) != source.sourceBytes) {
            throw PlyValidationError("source PLY changed before inference load");
        }
        std::vector<std::uint8_t> row(source.rowBytes);
        for (std::size_t index = 0; index < count; ++index) {
            readExactAt(
                descriptor,
                row.data(),
                row.size(),
                source.vertexDataOffset +
                    static_cast<std::uint64_t>(index) * source.rowBytes,
                isCancelled
            );
            for (std::size_t axis = 0; axis < 3; ++axis) {
                const float raw = rowFloat(
                    row,
                    source.finiteFloatOffsets[axis]
                );
                const float normalized =
                    (raw - inputData.translation[axis]) * inputData.scale;
                if (!std::isfinite(normalized)) {
                    throw PlyValidationError(
                        "normalized source PLY position is invalid"
                    );
                }
                means[index * 3 + axis] = normalized;
                if (axis == 0) result.outputPositions[index].x = raw;
                if (axis == 1) result.outputPositions[index].y = raw;
                if (axis == 2) result.outputPositions[index].z = raw;
            }
            result.positions[index] = {
                means[index * 3],
                means[index * 3 + 1],
                means[index * 3 + 2],
            };
            for (std::size_t channel = 0; channel < 3; ++channel) {
                featuresDc[index * 3 + channel] = rowFloat(
                    row,
                    source.finiteFloatOffsets[3 + channel]
                );
            }
            opacities[index] = rowFloat(
                row,
                source.finiteFloatOffsets[6]
            );
            result.opacityLogits[index] = opacities[index];
            for (std::size_t axis = 0; axis < 3; ++axis) {
                const float raw = rowFloat(
                    row,
                    source.finiteFloatOffsets[7 + axis]
                );
                result.outputLogScales[index][axis] = raw;
                const float normalized = raw + logScale;
                if (!std::isfinite(normalized)) {
                    throw PlyValidationError(
                        "normalized source PLY scale is invalid"
                    );
                }
                scales[index * 3 + axis] = normalized;
            }
            for (std::size_t component = 0; component < 4; ++component) {
                quaternions[index * 4 + component] = rowFloat(
                    row,
                    source.finiteFloatOffsets[10 + component]
                );
            }
        }
        struct stat finalStatus {};
        if (::fstat(descriptor, &finalStatus) != 0 ||
            !stableFileIdentity(authenticatedSource.identity, finalStatus)) {
            throw PlyValidationError("source PLY changed during inference load");
        }
        closeDescriptor(descriptor);
        return result;
    } catch (...) {
        closeDescriptor(descriptor);
        throw;
    }
}

void prepareExactView(
    InferenceGaussians &gaussians,
    PreparedCamera &camera,
    std::size_t cameraIndex,
    const std::function<bool()> &isCancelled
) {
    checkCancellation(isCancelled);
    msplat_set_raster_iteration_context(
        static_cast<std::uint64_t>(cameraIndex) + 1,
        static_cast<std::uint64_t>(cameraIndex)
    );
    constexpr unsigned maximumAttempts = 16;
    for (unsigned attempt = 0; attempt < maximumAttempts; ++attempt) {
        checkCancellation(isCancelled);
        msplat_prepare_isolation_view(
            static_cast<int>(gaussians.source.vertexCount),
            gaussians.means,
            gaussians.scales,
            1.0f,
            gaussians.quaternions,
            camera.viewMatrix,
            camera.projectionViewMatrix,
            camera.fx,
            camera.fy,
            camera.cx,
            camera.cy,
            camera.height,
            camera.width,
            camera.tileBounds,
            0.01f,
            0,
            0,
            camera.position.data(),
            gaussians.featuresDc,
            gaussians.featuresRest,
            gaussians.opacities,
            gaussians.background
        );
        msplat_commit();
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (stats.capacity_exceeded) {
            if (stats.latest_intersection_count == 0) {
                throw std::runtime_error(
                    "exact isolation raster reported an empty capacity request"
                );
            }
            msplat_grow_exact_raster_capacity(stats.latest_intersection_count);
            msplat_clear_raster_capacity_failure();
            continue;
        }
        if (stats.memory_budget_exceeded ||
            stats.resource_limit_exceeded ||
            stats.allocation_unavailable) {
            throw MemoryLimitError(
                "exact isolation raster cannot fit the memory budget"
            );
        }
        msplat_gpu_sync();
        if (msplat_get_dropped_intersection_count() != 0) {
            throw std::runtime_error(
                "exact isolation raster dropped Gaussian intersections"
            );
        }
        checkCancellation(isCancelled);
        return;
    }
    throw MemoryLimitError("exact isolation raster capacity did not converge");
}

std::size_t stripeRowCapacity(
    std::size_t width,
    std::size_t height,
    std::size_t memoryBudgetBytes
) {
    const std::size_t oneRow = checkedMultiply(
        width,
        kStripeBytesPerPixel,
        "sizing isolation raster stripe"
    );
    if (oneRow > memoryBudgetBytes) {
        throw MemoryLimitError(
            "memory budget cannot contain one isolation raster stripe"
        );
    }
    const std::size_t target = std::min(
        kStripeTargetBytes,
        std::max(oneRow, memoryBudgetBytes / 8)
    );
    return std::max<std::size_t>(
        1,
        std::min(height, target / oneRow)
    );
}

StripeBuffers makeStripeBuffers(
    std::size_t width,
    std::size_t height,
    std::size_t memoryBudgetBytes
) {
    StripeBuffers result;
    result.rowCapacity = stripeRowCapacity(width, height, memoryBudgetBytes);
    const std::size_t pixels = checkedMultiply(
        width,
        result.rowCapacity,
        "allocating isolation raster stripe"
    );
    const std::size_t recordBytes = checkedMultiply(
        checkedMultiply(
            pixels,
            MSPLAT_ISOLATION_RECORDS_PER_PIXEL,
            "allocating isolation contribution records"
        ),
        sizeof(MsplatIsolationContributionRecord),
        "allocating isolation contribution records"
    );
    result.records = gpu_empty(
        {static_cast<std::int64_t>(recordBytes)},
        DType::UInt8
    );
    result.counts = gpu_empty(
        {static_cast<std::int64_t>(pixels)},
        DType::Int32
    );
    result.alpha = gpu_empty(
        {static_cast<std::int64_t>(pixels)},
        DType::Float32
    );
    result.status = gpu_zeros({1}, DType::Int32);
    return result;
}

MTensor uploadMask(const DecodedMask &mask) {
    if (mask.width == 0 || mask.height == 0 ||
        mask.pixels.size() !=
            static_cast<std::size_t>(mask.width) * mask.height) {
        throw MaskValidationError("decoded mask storage is inconsistent");
    }
    MTensor result = gpu_empty(
        {
            static_cast<std::int64_t>(mask.height),
            static_cast<std::int64_t>(mask.width),
        },
        DType::UInt8
    );
    std::memcpy(result.data_ptr(), mask.pixels.data(), mask.pixels.size());
    return result;
}

template <typename Consumer>
void liftStripes(
    unsigned width,
    unsigned height,
    MTensor &mask,
    MTensor &selected,
    bool useSelection,
    StripeBuffers &buffers,
    const std::function<bool()> &isCancelled,
    Consumer consume
) {
    *buffers.status.data<std::int32_t>() = 0;
    for (std::size_t rowStart = 0; rowStart < height;
         rowStart += buffers.rowCapacity) {
        checkCancellation(isCancelled);
        const std::size_t rowCount = std::min(
            buffers.rowCapacity,
            static_cast<std::size_t>(height) - rowStart
        );
        msplat_lift_isolation_stripe(
            height,
            width,
            mask,
            selected,
            useSelection,
            static_cast<unsigned>(rowStart),
            static_cast<unsigned>(rowCount),
            buffers.records,
            buffers.counts,
            buffers.alpha,
            buffers.status
        );
        msplat_gpu_sync();
        if (*buffers.status.data<std::int32_t>() != 0) {
            throw std::runtime_error(
                "isolation contribution stripe exceeded its exact record bound"
            );
        }
        const std::size_t pixelCount =
            checkedMultiply(width, rowCount, "reading isolation raster stripe");
        consume(rowStart, rowCount, pixelCount);
        checkCancellation(isCancelled);
    }
}

ReducedView reduceWorkView(
    const MaskView &view,
    const DecodedMask &decoded,
    const Camera &sourceCamera,
    InferenceGaussians &gaussians,
    MTensor &selectedScratch,
    std::size_t memoryBudgetBytes,
    const std::function<bool()> &isCancelled
) {
    std::array<int, 256> labelIndex {};
    labelIndex.fill(-1);
    std::vector<std::uint16_t> labels {0};
    for (std::uint8_t label : decoded.labels) {
        if (label != 0) labels.push_back(label);
    }
    std::sort(labels.begin() + 1, labels.end());
    labels.erase(std::unique(labels.begin(), labels.end()), labels.end());
    if (labels.size() < 2) {
        throw MaskValidationError(
            "work-view mask must contain background and a nonzero instance"
        );
    }
    for (std::size_t index = 0; index < labels.size(); ++index) {
        labelIndex[labels[index]] = static_cast<int>(index);
    }

    const std::size_t gaussianCount =
        static_cast<std::size_t>(gaussians.source.vertexCount);
    const std::size_t weightCount = checkedMultiply(
        gaussianCount,
        labels.size(),
        "allocating one-view isolation label evidence"
    );
    std::vector<double> weights(weightCount, 0);
    std::vector<double> centralityWeights(gaussianCount, 0);
    PreparedCamera camera = prepareCamera(sourceCamera);
    prepareExactView(
        gaussians,
        camera,
        view.cameraIndex,
        isCancelled
    );
    MTensor mask = uploadMask(decoded);
    StripeBuffers buffers = makeStripeBuffers(
        decoded.width,
        decoded.height,
        memoryBudgetBytes
    );
    liftStripes(
        decoded.width,
        decoded.height,
        mask,
        selectedScratch,
        false,
        buffers,
        isCancelled,
        [&](std::size_t, std::size_t, std::size_t pixelCount) {
            const auto *records =
                static_cast<const MsplatIsolationContributionRecord *>(
                    buffers.records.data_ptr()
                );
            const auto *counts = buffers.counts.data<std::int32_t>();
            for (std::size_t pixel = 0; pixel < pixelCount; ++pixel) {
                if (counts[pixel] < 0 ||
                    counts[pixel] >
                        static_cast<std::int32_t>(
                            MSPLAT_ISOLATION_RECORDS_PER_PIXEL
                        )) {
                    throw std::runtime_error(
                        "isolation raster returned an invalid record count"
                    );
                }
                for (std::int32_t depth = 0; depth < counts[pixel]; ++depth) {
                    const MsplatIsolationContributionRecord &record =
                        records[
                            pixel * MSPLAT_ISOLATION_RECORDS_PER_PIXEL +
                            static_cast<std::size_t>(depth)
                        ];
                    if (record.gaussian_id >= gaussianCount ||
                        record.label > 255 ||
                        record.reserved != 0 ||
                        labelIndex[record.label] < 0 ||
                        !std::isfinite(record.weight) ||
                        record.weight < kContributionFloor ||
                        record.weight > 1 ||
                        !std::isfinite(record.centrality_weight) ||
                        record.centrality_weight < 0 ||
                        record.centrality_weight > record.weight) {
                        throw std::runtime_error(
                            "isolation raster returned an invalid contribution"
                        );
                    }
                    const std::size_t weightIndex =
                        static_cast<std::size_t>(record.gaussian_id) *
                            labels.size() +
                        static_cast<std::size_t>(labelIndex[record.label]);
                    weights[weightIndex] += record.weight;
                    centralityWeights[record.gaussian_id] +=
                        record.centrality_weight;
                    if (!std::isfinite(weights[weightIndex]) ||
                        !std::isfinite(
                            centralityWeights[record.gaussian_id]
                        )) {
                        throw std::runtime_error(
                            "isolation contribution reduction overflowed"
                        );
                    }
                }
            }
        }
    );

    ReducedView reduced;
    reduced.identity = view.identity;
    reduced.heldOut = false;
    reduced.gaussians.resize(gaussianCount);
    for (std::size_t gaussianIndex = 0;
         gaussianIndex < gaussianCount;
         ++gaussianIndex) {
        GaussianViewObservation &observation =
            reduced.gaussians[gaussianIndex];
        double bestWeight = 0;
        std::uint16_t bestLabel = 0;
        for (std::size_t currentLabel = 0;
             currentLabel < labels.size();
             ++currentLabel) {
            const double weight =
                weights[gaussianIndex * labels.size() + currentLabel];
            observation.visibleWeight += weight;
            if (labels[currentLabel] != 0) {
                observation.foregroundWeight += weight;
                if (weight > bestWeight ||
                    (weight == bestWeight &&
                     labels[currentLabel] < bestLabel)) {
                    bestWeight = weight;
                    bestLabel = labels[currentLabel];
                }
            }
        }
        if (!std::isfinite(observation.visibleWeight) ||
            !std::isfinite(observation.foregroundWeight) ||
            observation.foregroundWeight > observation.visibleWeight) {
            throw std::runtime_error(
                "reduced isolation view contains invalid evidence"
            );
        }
        observation.sufficientlyObserved =
            observation.visibleWeight >= kContributionFloor;
        if (observation.sufficientlyObserved &&
            bestLabel != 0 &&
            bestWeight >=
                kViewAssignmentThreshold * observation.visibleWeight) {
            observation.assignedInstance = bestLabel;
            observation.assignedInstanceWeight = bestWeight;
        }
        if (observation.visibleWeight > 0) {
            observation.projectionCentrality = std::clamp(
                centralityWeights[gaussianIndex] /
                    observation.visibleWeight,
                0.0,
                1.0
            );
        }
    }
    return reduced;
}

std::vector<double> resolveAnchorComponentWeights(
    const Anchor &anchor,
    const MaskView &view,
    const DecodedMask &decoded,
    const Camera &sourceCamera,
    const std::vector<ComponentEvidence> &components,
    InferenceGaussians &gaussians,
    MTensor &selectedScratch,
    std::size_t memoryBudgetBytes,
    const std::function<bool()> &isCancelled
) {
    if (anchor.instance == 0 || anchor.instance > 255 ||
        anchor.imageIdentity != view.identity) {
        throw std::invalid_argument("anchor does not match its work view");
    }
    if (!std::binary_search(
            decoded.labels.begin(),
            decoded.labels.end(),
            static_cast<std::uint8_t>(anchor.instance)
        )) {
        throw std::invalid_argument(
            "anchor instance is absent from the authenticated work mask"
        );
    }
    if (components.empty()) {
        throw std::invalid_argument(
            "anchor cannot resolve an empty deterministic component graph"
        );
    }

    const std::size_t gaussianCount =
        static_cast<std::size_t>(gaussians.source.vertexCount);
    const std::size_t noComponent = std::numeric_limits<std::size_t>::max();
    std::vector<std::size_t> componentForGaussian(gaussianCount, noComponent);
    for (std::size_t componentIndex = 0;
         componentIndex < components.size();
         ++componentIndex) {
        for (std::size_t gaussianIndex : components[componentIndex].indices) {
            if (gaussianIndex >= gaussianCount ||
                componentForGaussian[gaussianIndex] != noComponent) {
                throw std::runtime_error(
                    "anchor component mapping is invalid"
                );
            }
            componentForGaussian[gaussianIndex] = componentIndex;
        }
    }

    PreparedCamera camera = prepareCamera(sourceCamera);
    prepareExactView(
        gaussians,
        camera,
        view.cameraIndex,
        isCancelled
    );
    MTensor mask = uploadMask(decoded);
    StripeBuffers buffers = makeStripeBuffers(
        decoded.width,
        decoded.height,
        memoryBudgetBytes
    );
    std::vector<double> weights(components.size(), 0);
    liftStripes(
        decoded.width,
        decoded.height,
        mask,
        selectedScratch,
        false,
        buffers,
        isCancelled,
        [&](std::size_t, std::size_t, std::size_t pixelCount) {
            const auto *records =
                static_cast<const MsplatIsolationContributionRecord *>(
                    buffers.records.data_ptr()
                );
            const auto *counts = buffers.counts.data<std::int32_t>();
            for (std::size_t pixel = 0; pixel < pixelCount; ++pixel) {
                if (counts[pixel] < 0 ||
                    counts[pixel] >
                        static_cast<std::int32_t>(
                            MSPLAT_ISOLATION_RECORDS_PER_PIXEL
                        )) {
                    throw std::runtime_error(
                        "anchor raster returned an invalid record count"
                    );
                }
                for (std::int32_t depth = 0; depth < counts[pixel]; ++depth) {
                    const MsplatIsolationContributionRecord &record =
                        records[
                            pixel * MSPLAT_ISOLATION_RECORDS_PER_PIXEL +
                            static_cast<std::size_t>(depth)
                        ];
                    if (record.gaussian_id >= gaussianCount ||
                        record.label > 255 ||
                        record.reserved != 0 ||
                        !std::binary_search(
                            decoded.labels.begin(),
                            decoded.labels.end(),
                            static_cast<std::uint8_t>(record.label)
                        ) ||
                        !std::isfinite(record.weight) ||
                        record.weight < kContributionFloor ||
                        record.weight > 1 ||
                        !std::isfinite(record.centrality_weight) ||
                        record.centrality_weight < 0 ||
                        record.centrality_weight > record.weight) {
                        throw std::runtime_error(
                            "anchor raster returned an invalid contribution"
                        );
                    }
                    if (record.label != anchor.instance) continue;
                    const std::size_t component =
                        componentForGaussian[record.gaussian_id];
                    if (component == noComponent) continue;
                    weights[component] += record.weight;
                    if (!std::isfinite(weights[component])) {
                        throw std::runtime_error(
                            "anchor contribution reduction overflowed"
                        );
                    }
                }
            }
        }
    );
    return weights;
}

struct HeldOutResult {
    std::string imageIdentity;
    std::uint16_t bestLabel = 0;
    double softIoU = 0;
};

struct RobustBounds {
    std::array<double, 3> center {};
    double radius = 0;
};

struct RobustBoundsSample {
    std::array<double, 3> position {};
    double largestPhysicalScale = 0;
    double alpha = 0;
};

double sigmoid(double value) {
    if (value >= 0) {
        return 1.0 / (1.0 + std::exp(-value));
    }
    const double exponential = std::exp(value);
    return exponential / (1.0 + exponential);
}

double sortedMedian(std::vector<double> values) {
    if (values.empty()) {
        throw std::runtime_error("isolated PLY has no scene-bounds samples");
    }
    std::sort(values.begin(), values.end());
    const std::size_t middle = values.size() / 2;
    return values.size() % 2 == 0
        ? values[middle - 1] +
            (values[middle] - values[middle - 1]) * 0.5
        : values[middle];
}

RobustBounds robustOutputBounds(
    const InferenceGaussians &gaussians,
    const std::vector<std::size_t> &selectedIndices
) {
    std::vector<RobustBoundsSample> finiteSamples;
    finiteSamples.reserve(selectedIndices.size());
    for (std::size_t index : selectedIndices) {
        if (index >= gaussians.outputPositions.size() ||
            index >= gaussians.outputLogScales.size() ||
            index >= gaussians.opacityLogits.size()) {
            throw std::runtime_error(
                "isolated PLY scene-bounds index is out of range"
            );
        }
        const Point3 &point = gaussians.outputPositions[index];
        RobustBoundsSample sample;
        sample.position = {point.x, point.y, point.z};
        for (float logScale : gaussians.outputLogScales[index]) {
            const double physicalScale =
                std::exp(static_cast<double>(logScale));
            if (!std::isfinite(physicalScale) || physicalScale <= 0 ||
                physicalScale >
                    static_cast<double>(
                        std::numeric_limits<float>::max()
                    )) {
                throw std::runtime_error(
                    "isolated PLY has an invalid physical scale"
                );
            }
            sample.largestPhysicalScale = std::max(
                sample.largestPhysicalScale,
                physicalScale
            );
        }
        sample.alpha = sigmoid(gaussians.opacityLogits[index]);
        if (!std::isfinite(sample.position[0]) ||
            !std::isfinite(sample.position[1]) ||
            !std::isfinite(sample.position[2]) ||
            !std::isfinite(sample.alpha)) {
            throw std::runtime_error(
                "isolated PLY has a non-finite scene-bounds sample"
            );
        }
        finiteSamples.push_back(sample);
    }
    if (finiteSamples.empty()) {
        throw std::runtime_error(
            "isolated PLY has no finite scene-bounds samples"
        );
    }
    std::vector<RobustBoundsSample> opaqueSamples;
    opaqueSamples.reserve(finiteSamples.size());
    for (const RobustBoundsSample &sample : finiteSamples) {
        if (sample.alpha >= 0.01) opaqueSamples.push_back(sample);
    }
    const std::size_t minimumOpaqueCount = std::min(
        finiteSamples.size(),
        std::max<std::size_t>(
            8,
            (finiteSamples.size() + 999) / 1000
        )
    );
    const std::vector<RobustBoundsSample> &samples =
        opaqueSamples.size() >= minimumOpaqueCount
        ? opaqueSamples
        : finiteSamples;
    RobustBounds bounds;
    for (std::size_t axis = 0; axis < 3; ++axis) {
        std::vector<double> coordinates;
        coordinates.reserve(samples.size());
        for (const RobustBoundsSample &sample : samples) {
            coordinates.push_back(sample.position[axis]);
        }
        bounds.center[axis] = sortedMedian(std::move(coordinates));
    }
    std::vector<double> extents;
    extents.reserve(samples.size());
    for (const RobustBoundsSample &sample : samples) {
        const double x = sample.position[0] - bounds.center[0];
        const double y = sample.position[1] - bounds.center[1];
        const double z = sample.position[2] - bounds.center[2];
        const double extent =
            std::hypot(std::hypot(x, y), z) +
            3.0 * sample.largestPhysicalScale;
        if (std::isfinite(extent) && extent > 0) {
            extents.push_back(extent);
        }
    }
    if (extents.empty()) {
        throw std::runtime_error(
            "isolated PLY has no finite positive scene extent"
        );
    }
    std::sort(extents.begin(), extents.end());
    const std::size_t rank = std::max<std::size_t>(
        1,
        (995 * extents.size() + 999) / 1000
    );
    bounds.radius = extents[std::min(rank, extents.size()) - 1];
    if (!std::isfinite(bounds.center[0]) ||
        !std::isfinite(bounds.center[1]) ||
        !std::isfinite(bounds.center[2]) ||
        !std::isfinite(bounds.radius) ||
        bounds.radius <= 0) {
        throw std::runtime_error(
            "isolated PLY scene bounds are invalid"
        );
    }
    return bounds;
}

HeldOutResult validateHeldOutView(
    const MaskView &view,
    const DecodedMask &decoded,
    const Camera &sourceCamera,
    InferenceGaussians &gaussians,
    MTensor &selected,
    std::size_t memoryBudgetBytes,
    const std::function<bool()> &isCancelled
) {
    if (std::none_of(
            decoded.labels.begin(),
            decoded.labels.end(),
            [](std::uint8_t label) { return label != 0; }
        )) {
        throw MaskValidationError(
            "held-out mask must contain a nonzero instance"
        );
    }
    PreparedCamera camera = prepareCamera(sourceCamera);
    prepareExactView(
        gaussians,
        camera,
        view.cameraIndex,
        isCancelled
    );
    MTensor mask = uploadMask(decoded);
    StripeBuffers buffers = makeStripeBuffers(
        decoded.width,
        decoded.height,
        memoryBudgetBytes
    );
    std::array<std::uint64_t, 256> labelPixelCounts {};
    std::array<double, 256> alphaInsideLabel {};
    double totalAlpha = 0;
    liftStripes(
        decoded.width,
        decoded.height,
        mask,
        selected,
        true,
        buffers,
        isCancelled,
        [&](std::size_t rowStart, std::size_t, std::size_t pixelCount) {
            const float *alpha = buffers.alpha.data<float>();
            const std::size_t firstPixel =
                checkedMultiply(
                    rowStart,
                    decoded.width,
                    "indexing held-out mask"
                );
            for (std::size_t localPixel = 0;
                 localPixel < pixelCount;
                 ++localPixel) {
                const float value = alpha[localPixel];
                if (!std::isfinite(value) || value < 0 || value > 1) {
                    throw std::runtime_error(
                        "isolation raster returned invalid soft alpha"
                    );
                }
                const std::uint8_t label =
                    decoded.pixels[firstPixel + localPixel];
                ++labelPixelCounts[label];
                totalAlpha += value;
                if (label != 0) alphaInsideLabel[label] += value;
            }
        }
    );
    if (!std::isfinite(totalAlpha) || totalAlpha < 0) {
        throw std::runtime_error("held-out soft alpha reduction overflowed");
    }

    HeldOutResult result;
    result.imageIdentity = view.identity;
    for (std::size_t label = 1; label < labelPixelCounts.size(); ++label) {
        if (labelPixelCounts[label] == 0) continue;
        const double unionWeight =
            static_cast<double>(labelPixelCounts[label]) +
            totalAlpha -
            alphaInsideLabel[label];
        const double softIoU = unionWeight > 0
            ? alphaInsideLabel[label] / unionWeight
            : 0;
        if (!std::isfinite(softIoU) || softIoU < 0 || softIoU > 1) {
            throw std::runtime_error("held-out soft IoU is invalid");
        }
        if (softIoU > result.softIoU ||
            (softIoU == result.softIoU &&
             (result.bestLabel == 0 || label < result.bestLabel))) {
            result.bestLabel = static_cast<std::uint16_t>(label);
            result.softIoU = softIoU;
        }
    }
    if (result.bestLabel == 0) {
        throw MaskValidationError(
            "held-out mask contains no matchable nonzero instance"
        );
    }
    return result;
}

json componentJson(const ComponentEvidence &component) {
    json keyframes = json::array();
    for (const KeyframeContribution &keyframe :
         component.keyframeContributions) {
        keyframes.push_back({
            {"fraction", keyframe.fraction},
            {"image_identity", keyframe.imageIdentity},
            {"instance", keyframe.instance},
            {"weight", keyframe.weight},
        });
    }
    return {
        {"component_identity", component.identity},
        {"gaussian_count", component.indices.size()},
        {"keyframe_contributions", std::move(keyframes)},
        {"projection_centrality", component.projectionCentrality},
        {"score", component.score},
        {"view_coverage", component.viewCoverage},
        {"visible_support", component.visibleSupport},
    };
}

json componentListJson(const std::vector<ComponentEvidence> &components) {
    json encoded = json::array();
    for (const ComponentEvidence &component : components) {
        encoded.push_back(componentJson(component));
    }
    return encoded;
}

std::vector<std::string> viewIdentities(
    const MaskManifest &manifest,
    bool heldOut
) {
    std::vector<std::string> identities;
    for (const MaskView &view : manifest.views) {
        if (view.heldOut == heldOut) identities.push_back(view.identity);
    }
    return identities;
}

std::size_t runtimeWorkingSetBytes(
    std::size_t gaussianCount,
    std::size_t labelCount,
    std::size_t workViewCount,
    std::size_t maximumWidth,
    std::size_t maximumHeight,
    std::size_t plyRowBytes
) {
    std::size_t bytes = requiredWorkingSetBytes(
        gaussianCount,
        labelCount,
        maximumWidth,
        maximumHeight,
        plyRowBytes
    );
    // The pure estimator reserves float label evidence. Runtime deliberately
    // reduces one view with double accumulators in stable pixel/depth order.
    bytes = checkedAdd(
        bytes,
        checkedMultiply(
            checkedMultiply(
                gaussianCount,
                labelCount,
                "sizing deterministic double label reduction"
            ),
            sizeof(double) - sizeof(float),
            "sizing deterministic double label reduction"
        ),
        "sizing isolation runtime"
    );
    // One durable reduced copy, one cache-reader payload copy, and one
    // cross-view classification copy can coexist during a resumed analysis.
    const std::size_t allViewObservations = checkedMultiply(
        checkedMultiply(
            gaussianCount,
            workViewCount,
            "sizing cross-view isolation evidence"
        ),
        sizeof(GaussianViewObservation),
        "sizing cross-view isolation evidence"
    );
    bytes = checkedAdd(bytes, allViewObservations, "sizing isolation runtime");
    bytes = checkedAdd(bytes, allViewObservations, "sizing isolation runtime");
    bytes = checkedAdd(
        bytes,
        checkedMultiply(
            gaussianCount,
            sizeof(GaussianEvidence) + sizeof(bool) + sizeof(std::size_t),
            "sizing isolation classification"
        ),
        "sizing isolation runtime"
    );
    const std::size_t stripeRows = stripeRowCapacity(
        maximumWidth,
        maximumHeight,
        std::numeric_limits<std::size_t>::max()
    );
    bytes = checkedAdd(
        bytes,
        checkedMultiply(
            checkedMultiply(
                maximumWidth,
                stripeRows,
                "sizing isolation stripe"
            ),
            kStripeBytesPerPixel,
            "sizing isolation stripe"
        ),
        "sizing isolation runtime"
    );
    return bytes;
}

void removeIfSameFile(
    const fs::path &path,
    const FilteredPlyReceipt &receipt
) noexcept {
    struct stat status {};
    if (::lstat(path.c_str(), &status) == 0 &&
        S_ISREG(status.st_mode) &&
        static_cast<std::uint64_t>(status.st_dev) == receipt.outputDevice &&
        static_cast<std::uint64_t>(status.st_ino) == receipt.outputInode &&
        status.st_size >= 0 &&
        static_cast<std::uint64_t>(status.st_size) == receipt.outputBytes) {
        (void)::unlink(path.c_str());
    }
}

} // namespace

IsolationRunResult runIsolation(
    const IsolationRequest &request,
    InputData &inputData,
    const IsolationEventEmitter &emit,
    const std::function<bool()> &isCancelled
) {
    checkCancellation(isCancelled);
    if (!emit) throw std::invalid_argument("isolation event emitter is required");
    const std::array<const std::string *, 5> digests = {
        &request.expectedSourcePlyDigest,
        &request.expectedInputDigest,
        &request.expectedGeometryDigest,
        &request.expectedSelectedFramesDigest,
        &request.expectedTrainingManifestDigest,
    };
    if (request.memoryBudgetBytes == 0 ||
        std::any_of(
            digests.begin(),
            digests.end(),
            [](const std::string *digest) {
                return !isLowercaseDigest(*digest);
            }
        )) {
        throw std::invalid_argument(
            "isolation request has an invalid memory budget or digest"
        );
    }
    if (inputData.cameras.empty()) {
        throw std::invalid_argument("isolation dataset has no cameras");
    }
    struct stat outputStatus {};
    if (::lstat(request.output.c_str(), &outputStatus) == 0 ||
        errno != ENOENT) {
        throw PlyValidationError("isolated PLY output already exists");
    }

    const MaskExpectedDigests expectedDigests {
        request.expectedSourcePlyDigest,
        request.expectedInputDigest,
        request.expectedGeometryDigest,
        request.expectedSelectedFramesDigest,
        request.expectedTrainingManifestDigest,
    };
    const MaskManifest manifest = loadMaskManifest(
        request.maskManifest,
        expectedDigests,
        isCancelled
    );
    std::vector<IsolationPath> isolationPaths = {
        {request.sourcePly, "source PLY"},
        {request.maskManifest, "mask manifest"},
        {request.analysisCache, "analysis cache"},
        {request.output, "isolated PLY output"},
    };
    isolationPaths.reserve(isolationPaths.size() + manifest.views.size());
    for (const MaskView &view : manifest.views) {
        isolationPaths.push_back({
            manifest.root / view.relativePath,
            "mask for " + view.identity,
        });
    }
    requireDistinctIsolationPaths(
        isolationPaths,
        request.eventFileIdentity
    );
    if (manifest.views.size() < 2 ||
        manifest.views.size() > kMaximumViewCount) {
        throw MaskValidationError("isolation mask view count is invalid");
    }
    std::vector<ExpectedMaskView> expectedViews;
    expectedViews.reserve(manifest.views.size());
    for (const MaskView &view : manifest.views) {
        if (view.cameraIndex >= inputData.cameras.size()) {
            throw MaskValidationError(
                "mask camera index is outside the authenticated dataset"
            );
        }
        const Camera &camera = inputData.cameras[view.cameraIndex];
        if (camera.width <= 0 || camera.height <= 0 ||
            camera.width > 4096 || camera.height > 4096) {
            throw MaskValidationError(
                "mask camera render dimensions exceed the supported bound"
            );
        }
        expectedViews.push_back({
            cameraIdentity(camera),
            view.cameraIndex,
            static_cast<std::uint32_t>(camera.width),
            static_cast<std::uint32_t>(camera.height),
        });
    }
    validateMaskManifestViews(manifest, expectedViews);

    const FileDigest sourceDigest = hashRegularFile(
        request.sourcePly,
        isCancelled
    );
    if (sourceDigest.sha256 != request.expectedSourcePlyDigest) {
        throw PlyValidationError(
            "source PLY digest does not match the authenticated request"
        );
    }
    const BinaryPly source = inspectBinaryPlyHeader(
        request.sourcePly,
        request.memoryBudgetBytes
    );
    if (source.sourceDevice != sourceDigest.identity.device ||
        source.sourceInode != sourceDigest.identity.inode ||
        source.sourceBytes != sourceDigest.identity.bytes) {
        throw PlyValidationError("source PLY changed before schema inspection");
    }

    std::size_t maximumWidth = 0;
    std::size_t maximumHeight = 0;
    std::size_t maximumLabelCount = 0;
    std::size_t workViewCount = 0;
    std::size_t heldOutViewCount = 0;
    for (const MaskView &view : manifest.views) {
        checkCancellation(isCancelled);
        const DecodedMask decoded = decodeMask(
            manifest,
            view,
            isCancelled,
            request.memoryBudgetBytes
        );
        if (decoded.width != view.width ||
            decoded.height != view.height ||
            decoded.pixels.size() >
                kMaximumMaskPixels) {
            throw MaskValidationError(
                "decoded mask dimensions do not match the authenticated view"
            );
        }
        if (std::none_of(
                decoded.labels.begin(),
                decoded.labels.end(),
                [](std::uint8_t label) { return label != 0; }
            )) {
            throw MaskValidationError(
                "every isolation mask must contain a nonzero instance"
            );
        }
        maximumWidth = std::max<std::size_t>(maximumWidth, decoded.width);
        maximumHeight = std::max<std::size_t>(maximumHeight, decoded.height);
        maximumLabelCount = std::max(
            maximumLabelCount,
            decoded.labels.size()
        );
        if (view.heldOut) {
            ++heldOutViewCount;
        } else {
            ++workViewCount;
        }
    }
    if (workViewCount == 0 || heldOutViewCount == 0 ||
        maximumLabelCount < 2) {
        throw MaskValidationError(
            "isolation requires work and held-out masks with instances"
        );
    }
    const std::size_t gaussianCount =
        static_cast<std::size_t>(source.vertexCount);
    const std::size_t requiredBytes = runtimeWorkingSetBytes(
        gaussianCount,
        maximumLabelCount,
        workViewCount,
        maximumWidth,
        maximumHeight,
        source.rowBytes
    );
    enforceMemoryBudget(requiredBytes, request.memoryBudgetBytes);
    validateBinaryPlyRows(source, isCancelled);
    requireUnchangedFile(request.sourcePly, sourceDigest, isCancelled);

    const std::vector<std::string> workIdentities =
        viewIdentities(manifest, false);
    const std::vector<std::string> heldOutIdentities =
        viewIdentities(manifest, true);
    std::vector<std::string> workMaskDigests;
    workMaskDigests.reserve(workViewCount);
    for (const MaskView &view : manifest.views) {
        if (!view.heldOut) workMaskDigests.push_back(view.sha256);
    }
    AnalysisCache cache {
        request.expectedSourcePlyDigest,
        request.expectedInputDigest,
        request.expectedGeometryDigest,
        request.expectedSelectedFramesDigest,
        request.expectedTrainingManifestDigest,
        workIdentities,
        workMaskDigests,
        gaussianCount,
        {},
    };
    struct stat cacheStatus {};
    if (::lstat(request.analysisCache.c_str(), &cacheStatus) == 0) {
        cache = readAnalysisCache(
            request.analysisCache,
            request.expectedSourcePlyDigest,
            request.expectedInputDigest,
            request.expectedGeometryDigest,
            request.expectedSelectedFramesDigest,
            request.expectedTrainingManifestDigest,
            workIdentities,
            workMaskDigests,
            gaussianCount,
            request.memoryBudgetBytes
        );
        if (cache.gaussianCount != gaussianCount) {
            throw CacheValidationError(
                "analysis cache Gaussian count is stale"
            );
        }
    } else if (errno != ENOENT) {
        throw CacheValidationError("analysis cache path cannot be inspected");
    }

    emit("isolation_started", {
        {"cached_work_view_count", cache.views.size()},
        {"held_out_view_count", heldOutViewCount},
        {"memory_budget_bytes", request.memoryBudgetBytes},
        {"source_gaussian_count", gaussianCount},
        {"status", "running"},
        {"work_view_count", workViewCount},
    });
    const std::size_t reusedWorkViewCount = cache.views.size();
    const std::size_t filteringUnitTotal =
        workViewCount + 1 + (request.anchor.has_value() ? 1 : 0);

    InferenceGaussians gaussians = loadInferenceGaussians(
        source,
        sourceDigest,
        inputData,
        isCancelled
    );
    MTensor selected = gpu_zeros(
        {static_cast<std::int64_t>(gaussianCount)},
        DType::UInt8
    );

    std::size_t workIndex = 0;
    for (const MaskView &view : manifest.views) {
        if (view.heldOut) continue;
        checkCancellation(isCancelled);
        if (workIndex < cache.views.size()) {
            if (cache.views[workIndex].identity != view.identity ||
                cache.views[workIndex].heldOut) {
                throw CacheValidationError(
                    "analysis cache completed view prefix is invalid"
                );
            }
            emit("isolation_progress", {
                {"cache_reused", true},
                {"completed_unit_count", workIndex + 1},
                {"image_identity", view.identity},
                {"phase", "filtering"},
                {"status", "running"},
                {"total_unit_count", filteringUnitTotal},
            });
            ++workIndex;
            continue;
        }
        const DecodedMask decoded = decodeMask(
            manifest,
            view,
            isCancelled,
            request.memoryBudgetBytes
        );
        ReducedView reduced = reduceWorkView(
            view,
            decoded,
            inputData.cameras[view.cameraIndex],
            gaussians,
            selected,
            request.memoryBudgetBytes,
            isCancelled
        );
        checkCancellation(isCancelled);
        cache.views.push_back(std::move(reduced));
        requireUnchangedFile(request.sourcePly, sourceDigest, isCancelled);
        writeAnalysisCacheAtomically(request.analysisCache, cache);
        checkCancellation(isCancelled);
        emit("isolation_progress", {
            {"cache_reused", false},
            {"completed_unit_count", workIndex + 1},
            {"image_identity", view.identity},
            {"phase", "filtering"},
            {"status", "running"},
            {"total_unit_count", filteringUnitTotal},
        });
        ++workIndex;
    }
    if (cache.views.size() != workViewCount) {
        throw CacheValidationError(
            "analysis cache did not complete the work-view prefix"
        );
    }
    requireUnchangedFile(request.sourcePly, sourceDigest, isCancelled);
    checkCancellation(isCancelled);
    const std::vector<GaussianEvidence> evidence =
        classifyGaussians(cache.views);
    checkCancellation(isCancelled);
    SelectionResult selection = selectSubject(
        gaussians.positions,
        evidence,
        cache.views,
        std::nullopt
    );
    checkCancellation(isCancelled);
    emit("isolation_progress", {
        {"cache_reused", reusedWorkViewCount > 0},
        {"completed_unit_count", workViewCount + 1},
        {"image_identity", ""},
        {"phase", "filtering"},
        {"status", "running"},
        {"total_unit_count", filteringUnitTotal},
    });
    if (selection.outcome == SelectionOutcome::noSubject) {
        if (request.anchor.has_value()) {
            emit("isolation_progress", {
                {"cache_reused", true},
                {"completed_unit_count", filteringUnitTotal},
                {"image_identity", request.anchor->imageIdentity},
                {"phase", "filtering"},
                {"status", "running"},
                {"total_unit_count", filteringUnitTotal},
            });
        }
        emit("isolation_no_subject", {
            {"components", componentListJson(selection.components)},
            {"source_gaussian_count", gaussianCount},
            {"status", "no_subject"},
        });
        return {IsolationRunOutcome::noSubject};
    }
    if (request.anchor.has_value()) {
        const auto anchorView = std::find_if(
            manifest.views.begin(),
            manifest.views.end(),
            [&](const MaskView &view) {
                return !view.heldOut &&
                    view.identity == request.anchor->imageIdentity;
            }
        );
        if (anchorView == manifest.views.end()) {
            throw std::invalid_argument(
                "anchor image is not an authenticated work view"
            );
        }
        const DecodedMask anchorMask = decodeMask(
            manifest,
            *anchorView,
            isCancelled,
            request.memoryBudgetBytes
        );
        const std::vector<double> anchorWeights =
            resolveAnchorComponentWeights(
                *request.anchor,
                *anchorView,
                anchorMask,
                inputData.cameras[anchorView->cameraIndex],
                selection.components,
                gaussians,
                selected,
                request.memoryBudgetBytes,
                isCancelled
            );
        checkCancellation(isCancelled);
        selection = selectSubject(
            gaussians.positions,
            evidence,
            cache.views,
            request.anchor,
            anchorWeights
        );
        checkCancellation(isCancelled);
        emit("isolation_progress", {
            {"cache_reused", true},
            {"completed_unit_count", filteringUnitTotal},
            {"image_identity", request.anchor->imageIdentity},
            {"phase", "filtering"},
            {"status", "running"},
            {"total_unit_count", filteringUnitTotal},
        });
    }
    if (selection.outcome == SelectionOutcome::ambiguous) {
        emit("isolation_ambiguity", {
            {"anchor_allowed", true},
            {"components", componentListJson(selection.components)},
            {"source_gaussian_count", gaussianCount},
            {"status", "ambiguity"},
        });
        return {IsolationRunOutcome::ambiguous};
    }
    if (selection.selectedIndices.empty() ||
        !selection.selectedComponent.has_value()) {
        throw std::runtime_error(
            "selected isolation component has no Gaussian rows"
        );
    }

    auto *selectedBytes = selected.data<std::uint8_t>();
    std::fill(selectedBytes, selectedBytes + gaussianCount, 0);
    for (std::size_t index : selection.selectedIndices) {
        if (index >= gaussianCount) {
            throw std::runtime_error(
                "selected isolation Gaussian is out of range"
            );
        }
        selectedBytes[index] = 1;
    }

    std::vector<HeldOutResult> heldOutResults;
    heldOutResults.reserve(heldOutViewCount);
    std::size_t heldOutIndex = 0;
    for (const MaskView &view : manifest.views) {
        if (!view.heldOut) continue;
        const DecodedMask decoded = decodeMask(
            manifest,
            view,
            isCancelled,
            request.memoryBudgetBytes
        );
        heldOutResults.push_back(validateHeldOutView(
            view,
            decoded,
            inputData.cameras[view.cameraIndex],
            gaussians,
            selected,
            request.memoryBudgetBytes,
            isCancelled
        ));
        ++heldOutIndex;
        emit("isolation_progress", {
            {"cache_reused", false},
            {"completed_unit_count", heldOutIndex},
            {"image_identity", view.identity},
            {"phase", "validating"},
            {"status", "running"},
            {"total_unit_count", heldOutViewCount},
        });
    }
    std::vector<double> heldOutIoUs;
    heldOutIoUs.reserve(heldOutResults.size());
    json heldOutEvidence = json::array();
    double heldOutSum = 0;
    for (const HeldOutResult &result : heldOutResults) {
        heldOutIoUs.push_back(result.softIoU);
        heldOutSum += result.softIoU;
        heldOutEvidence.push_back({
            {"best_instance", result.bestLabel},
            {"image_identity", result.imageIdentity},
            {"soft_iou", result.softIoU},
        });
    }
    const double heldOutMedian = median(heldOutIoUs);
    const double heldOutQ1 = firstQuartile(heldOutIoUs);
    const double heldOutMean =
        heldOutSum / static_cast<double>(heldOutIoUs.size());
    if (!heldOutValidationPasses(heldOutIoUs)) {
        emit("isolation_held_out_rejected", {
            {"held_out_evidence", heldOutEvidence},
            {"held_out_mean_soft_iou", heldOutMean},
            {"held_out_median_soft_iou", heldOutMedian},
            {"held_out_q1_soft_iou", heldOutQ1},
            {"status", "rejected"},
        });
        return {IsolationRunOutcome::heldOutRejected};
    }

    requireUnchangedFile(request.sourcePly, sourceDigest, isCancelled);
    checkCancellation(isCancelled);
    const RobustBounds robustBounds = robustOutputBounds(
        gaussians,
        selection.selectedIndices
    );
    std::optional<FilteredPlyReceipt> installedOutput;
    FileDigest outputDigest;
    try {
        const FilteredPlyReceipt receipt = writeFilteredBinaryPly(
            source,
            request.output,
            selection.selectedIndices,
            isCancelled
        );
        installedOutput = receipt;
        outputDigest = hashRegularFile(request.output, isCancelled);
        if (outputDigest.identity.device != receipt.outputDevice ||
            outputDigest.identity.inode != receipt.outputInode ||
            outputDigest.identity.bytes != receipt.outputBytes) {
            throw PlyValidationError(
                "installed isolated PLY identity changed before completion"
            );
        }
        requireUnchangedFile(request.sourcePly, sourceDigest, isCancelled);
        requireUnchangedFile(request.output, outputDigest, isCancelled);
        const double retainedFraction =
            static_cast<double>(selection.selectedIndices.size()) /
            static_cast<double>(gaussianCount);
        const ComponentEvidence &selectedComponent =
            selection.components[*selection.selectedComponent];
        emit("isolation_completed", {
            {"bounds_maximum", {
                receipt.bounds.maximum.x,
                receipt.bounds.maximum.y,
                receipt.bounds.maximum.z,
            }},
            {"bounds_minimum", {
                receipt.bounds.minimum.x,
                receipt.bounds.minimum.y,
                receipt.bounds.minimum.z,
            }},
            {"gaussian_count", selection.selectedIndices.size()},
            {"held_out_evidence", heldOutEvidence},
            {"held_out_mean_soft_iou", heldOutMean},
            {"held_out_median_soft_iou", heldOutMedian},
            {"held_out_q1_soft_iou", heldOutQ1},
            {"held_out_view_identities", heldOutIdentities},
            {"output_bytes", outputDigest.identity.bytes},
            {"output_sha256", outputDigest.sha256},
            {"retained_gaussian_fraction", retainedFraction},
            {"scene_center", {
                robustBounds.center[0],
                robustBounds.center[1],
                robustBounds.center[2],
            }},
            {"scene_radius", robustBounds.radius},
            {"selected_component", componentJson(selectedComponent)},
            {"selected_view_identities", workIdentities},
            {"source_gaussian_count", gaussianCount},
            {"source_ply_sha256", sourceDigest.sha256},
            {"status", "completed"},
        });
        installedOutput.reset();
    } catch (...) {
        if (installedOutput.has_value()) {
            removeIfSameFile(request.output, *installedOutput);
        }
        throw;
    }
    return {IsolationRunOutcome::completed};
}

} // namespace easysplat::isolation
