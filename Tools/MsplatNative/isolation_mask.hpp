// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#ifndef EASYSPLAT_ISOLATION_MASK_HPP
#define EASYSPLAT_ISOLATION_MASK_HPP

#include "isolation.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace easysplat::isolation {

inline constexpr std::uint32_t kMaskManifestSchemaVersion = 1;
inline constexpr std::uint32_t kIsolationModeVersion = 1;
inline constexpr std::size_t kMaximumMaskViews = 24;
inline constexpr std::uint64_t kMaximumMaskManifestBytes = 1024 * 1024;
inline constexpr std::uint32_t kMaximumMaskDimension = 4096;
inline constexpr std::uint64_t kMaximumDecodedMaskPixelCount = 16'777'216;
inline constexpr std::uint64_t kMaximumEncodedMaskBytes = 64ULL * 1024 * 1024;
inline constexpr std::size_t kMaximumMaskIdentityBytes = 1024;
inline constexpr std::uint64_t kDefaultMaximumDecodedMaskBytes =
    kMaximumEncodedMaskBytes + kMaximumDecodedMaskPixelCount;

class MaskValidationError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct MaskExpectedDigests {
    std::string sourcePly;
    std::string input;
    std::string geometry;
    std::string selectedFrames;
    std::string trainingManifest;
};

struct ExpectedMaskView {
    std::string identity;
    std::size_t cameraIndex = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
};

struct MaskView {
    std::string identity;
    std::size_t cameraIndex = 0;
    bool heldOut = false;
    std::filesystem::path relativePath;
    std::string sha256;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
};

struct MaskManifest {
    std::filesystem::path path;
    std::filesystem::path root;
    MaskExpectedDigests digests;
    std::vector<std::string> selectedImageOrder;
    std::vector<MaskView> views;
};

struct DecodedMask {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::vector<std::uint8_t> pixels;
    std::vector<std::uint8_t> labels;
};

MaskManifest loadMaskManifest(
    const std::filesystem::path &path,
    const MaskExpectedDigests &expectedDigests,
    const std::function<bool()> &isCancelled
);

void validateMaskManifestViews(
    const MaskManifest &manifest,
    const std::vector<ExpectedMaskView> &expectedViews
);

DecodedMask decodeMask(
    const MaskManifest &manifest,
    const MaskView &view,
    const std::function<bool()> &isCancelled,
    std::uint64_t maximumEncodedAndDecodedBytes = kDefaultMaximumDecodedMaskBytes
);

} // namespace easysplat::isolation

#endif
