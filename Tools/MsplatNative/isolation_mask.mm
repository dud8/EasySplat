// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include "isolation_mask.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/CGImageProperties.h>
#include <ImageIO/CGImageSource.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <limits>
#include <memory>
#include <set>
#include <sstream>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace easysplat::isolation {
namespace {

constexpr std::array<std::string_view, 9> manifestKeys = {
    "schema_version",
    "isolation_mode_version",
    "source_ply_digest",
    "input_digest",
    "geometry_digest",
    "selected_frames_digest",
    "training_manifest_digest",
    "selected_image_order",
    "views",
};

constexpr std::array<std::string_view, 7> viewKeys = {
    "image_identity",
    "camera_index",
    "role",
    "relative_mask_path",
    "mask_sha256",
    "width",
    "height",
};

struct FileDescriptor {
    explicit FileDescriptor(int value = -1) : value(value) {}
    ~FileDescriptor() {
        if (value >= 0) (void)::close(value);
    }

    FileDescriptor(const FileDescriptor &) = delete;
    FileDescriptor &operator=(const FileDescriptor &) = delete;

    FileDescriptor(FileDescriptor &&other) noexcept : value(other.value) {
        other.value = -1;
    }

    FileDescriptor &operator=(FileDescriptor &&other) noexcept {
        if (this == &other) return *this;
        if (value >= 0) (void)::close(value);
        value = other.value;
        other.value = -1;
        return *this;
    }

    int value = -1;
};

template <typename Value>
class CFReference {
public:
    explicit CFReference(Value value = nullptr) : value_(value) {}
    ~CFReference() {
        if (value_ != nullptr) CFRelease(value_);
    }

    CFReference(const CFReference &) = delete;
    CFReference &operator=(const CFReference &) = delete;

    CFReference(CFReference &&other) noexcept : value_(other.value_) {
        other.value_ = nullptr;
    }

    CFReference &operator=(CFReference &&other) noexcept {
        if (this == &other) return *this;
        if (value_ != nullptr) CFRelease(value_);
        value_ = other.value_;
        other.value_ = nullptr;
        return *this;
    }

    Value get() const { return value_; }

private:
    Value value_;
};

[[noreturn]] void fail(const std::string &message) {
    throw MaskValidationError(message);
}

void checkCancellation(const std::function<bool()> &isCancelled) {
    if (isCancelled && isCancelled()) throw CancellationError();
}

std::string systemMessage(const std::string &operation) {
    return operation + ": " + std::strerror(errno);
}

bool isLowercaseDigest(const std::string &value) {
    return value.size() == 64 &&
        std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f');
        });
}

bool sameStableMetadata(const struct stat &left, const struct stat &right) {
    return S_ISREG(left.st_mode) && S_ISREG(right.st_mode) &&
        left.st_dev == right.st_dev &&
        left.st_ino == right.st_ino &&
        left.st_nlink == right.st_nlink &&
        left.st_size == right.st_size &&
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
        left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
        left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
        left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

std::vector<std::uint8_t> readStableFile(
    int descriptor,
    const struct stat &initialMetadata,
    std::uint64_t maximumBytes,
    const std::function<bool()> &isCancelled,
    const std::string &description
) {
    if (!S_ISREG(initialMetadata.st_mode) || initialMetadata.st_nlink != 1) {
        fail(description + " must be a regular, single-link file");
    }
    if (initialMetadata.st_size < 0 ||
        static_cast<std::uint64_t>(initialMetadata.st_size) > maximumBytes) {
        fail(description + " exceeds its byte limit");
    }

    std::vector<std::uint8_t> bytes(
        static_cast<std::size_t>(initialMetadata.st_size)
    );
    std::size_t consumed = 0;
    while (consumed < bytes.size()) {
        checkCancellation(isCancelled);
        const std::size_t request = std::min<std::size_t>(
            bytes.size() - consumed,
            1024 * 1024
        );
        const ssize_t count = ::read(descriptor, bytes.data() + consumed, request);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) fail(systemMessage("cannot read " + description));
        if (count == 0) fail(description + " was truncated while reading");
        consumed += static_cast<std::size_t>(count);
    }

    struct stat finalMetadata {};
    if (::fstat(descriptor, &finalMetadata) != 0) {
        fail(systemMessage("cannot inspect " + description));
    }
    if (!sameStableMetadata(initialMetadata, finalMetadata)) {
        fail(description + " changed while reading");
    }
    checkCancellation(isCancelled);
    return bytes;
}

std::vector<std::uint8_t> readManifestBytes(
    const fs::path &path,
    const std::function<bool()> &isCancelled
) {
    checkCancellation(isCancelled);
    FileDescriptor descriptor(::open(
        path.c_str(),
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
    ));
    if (descriptor.value < 0) fail(systemMessage("cannot open mask manifest"));

    struct stat metadata {};
    if (::fstat(descriptor.value, &metadata) != 0) {
        fail(systemMessage("cannot inspect mask manifest"));
    }
    return readStableFile(
        descriptor.value,
        metadata,
        kMaximumMaskManifestBytes,
        isCancelled,
        "mask manifest"
    );
}

std::vector<std::string> pathComponents(const std::string &relativePath) {
    if (relativePath.empty() || relativePath.front() == '/' ||
        relativePath.find('\\') != std::string::npos ||
        relativePath.find('\0') != std::string::npos) {
        fail("mask path must be a safe relative POSIX path");
    }

    std::vector<std::string> components;
    std::size_t start = 0;
    while (start <= relativePath.size()) {
        const std::size_t separator = relativePath.find('/', start);
        const std::size_t end =
            separator == std::string::npos ? relativePath.size() : separator;
        const std::string component = relativePath.substr(start, end - start);
        if (component.empty() || component == "." || component == "..") {
            fail("mask path contains an unsafe component");
        }
        components.push_back(component);
        if (separator == std::string::npos) break;
        start = separator + 1;
    }
    return components;
}

std::vector<std::uint8_t> readRelativeMaskBytes(
    const fs::path &root,
    const std::string &relativePath,
    std::uint64_t maximumBytes,
    const std::function<bool()> &isCancelled
) {
    const std::vector<std::string> components = pathComponents(relativePath);
    const fs::path normalizedRoot = root.empty() ? fs::path(".") : root;
    FileDescriptor current(::open(
        normalizedRoot.c_str(),
        O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    ));
    if (current.value < 0) fail(systemMessage("cannot open mask root"));

    for (std::size_t index = 0; index + 1 < components.size(); ++index) {
        checkCancellation(isCancelled);
        FileDescriptor next(::openat(
            current.value,
            components[index].c_str(),
            O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        ));
        if (next.value < 0) fail(systemMessage("cannot open mask path component"));
        current = std::move(next);
    }

    checkCancellation(isCancelled);
    FileDescriptor mask(::openat(
        current.value,
        components.back().c_str(),
        O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
    ));
    if (mask.value < 0) fail(systemMessage("cannot open mask"));

    struct stat metadata {};
    if (::fstat(mask.value, &metadata) != 0) {
        fail(systemMessage("cannot inspect mask"));
    }
    return readStableFile(
        mask.value,
        metadata,
        maximumBytes,
        isCancelled,
        "mask"
    );
}

std::string sha256(const std::vector<std::uint8_t> &bytes) {
    CC_SHA256_CTX context {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CC_SHA256_Init(&context) != 1) fail("cannot initialize mask SHA-256");
    const std::uint8_t *cursor = bytes.data();
    std::size_t remaining = bytes.size();
    while (remaining > 0) {
        const CC_LONG count = static_cast<CC_LONG>(std::min<std::size_t>(
            remaining,
            std::numeric_limits<CC_LONG>::max()
        ));
        if (CC_SHA256_Update(&context, cursor, count) != 1) {
            fail("cannot update mask SHA-256");
        }
        cursor += count;
        remaining -= count;
    }
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest {};
    if (CC_SHA256_Final(digest.data(), &context) != 1) {
        fail("cannot finish mask SHA-256");
    }
#pragma clang diagnostic pop

    std::ostringstream encoded;
    encoded << std::hex << std::setfill('0');
    for (const unsigned char byte : digest) {
        encoded << std::setw(2) << static_cast<unsigned int>(byte);
    }
    return encoded.str();
}

template <std::size_t Size>
void requireExactKeys(
    const json &object,
    const std::array<std::string_view, Size> &expected,
    const std::string &description
) {
    if (!object.is_object() || object.size() != expected.size()) {
        fail(description + " must contain exactly the documented fields");
    }
    for (const std::string_view key : expected) {
        if (!object.contains(std::string(key))) {
            fail(description + " is missing field " + std::string(key));
        }
    }
}

std::uint64_t requireUnsignedInteger(
    const json &value,
    const std::string &description
) {
    if (value.is_number_unsigned()) return value.get<std::uint64_t>();
    fail(description + " must be an unsigned integer");
}

std::string requireString(const json &value, const std::string &description) {
    if (!value.is_string()) fail(description + " must be a string");
    const std::string result = value.get<std::string>();
    if (result.find('\0') != std::string::npos) {
        fail(description + " contains a NUL byte");
    }
    return result;
}

json parseStrictJson(const std::vector<std::uint8_t> &bytes) {
    using Event = json::parse_event_t;
    std::vector<std::set<std::string>> objectKeys;
    const auto callback =
        [&](int depth, Event event, json &parsed) -> bool {
            if (depth < 0) fail("mask manifest JSON depth is invalid");
            if (depth > 32) fail("mask manifest JSON nesting is too deep");
            if (event == Event::object_start) {
                objectKeys.emplace_back();
            } else if (event == Event::key) {
                if (objectKeys.empty()) fail("mask manifest JSON object is malformed");
                const std::string key = parsed.get<std::string>();
                if (!objectKeys.back().insert(key).second) {
                    fail("mask manifest contains duplicate JSON key " + key);
                }
            } else if (event == Event::object_end) {
                if (objectKeys.empty()) fail("mask manifest JSON object is malformed");
                objectKeys.pop_back();
            }
            return true;
        };

    try {
        return json::parse(bytes.begin(), bytes.end(), callback, true, false);
    } catch (const MaskValidationError &) {
        throw;
    } catch (const std::exception &) {
        fail("mask manifest is not valid JSON");
    }
}

MaskExpectedDigests parseDigests(
    const json &document,
    const MaskExpectedDigests &expected
) {
    const auto validateExpected = [](const std::string &digest) {
        if (!isLowercaseDigest(digest)) {
            fail("expected isolation digest must be 64 lowercase hexadecimal characters");
        }
    };
    validateExpected(expected.sourcePly);
    validateExpected(expected.input);
    validateExpected(expected.geometry);
    validateExpected(expected.selectedFrames);
    validateExpected(expected.trainingManifest);

    MaskExpectedDigests actual {
        requireString(document.at("source_ply_digest"), "source_ply_digest"),
        requireString(document.at("input_digest"), "input_digest"),
        requireString(document.at("geometry_digest"), "geometry_digest"),
        requireString(
            document.at("selected_frames_digest"),
            "selected_frames_digest"
        ),
        requireString(
            document.at("training_manifest_digest"),
            "training_manifest_digest"
        ),
    };
    const std::array<std::string, 5> values = {
        actual.sourcePly,
        actual.input,
        actual.geometry,
        actual.selectedFrames,
        actual.trainingManifest,
    };
    if (!std::all_of(values.begin(), values.end(), isLowercaseDigest)) {
        fail("mask manifest digest must be 64 lowercase hexadecimal characters");
    }
    if (actual.sourcePly != expected.sourcePly ||
        actual.input != expected.input ||
        actual.geometry != expected.geometry ||
        actual.selectedFrames != expected.selectedFrames ||
        actual.trainingManifest != expected.trainingManifest) {
        fail("mask manifest digest does not match authenticated isolation inputs");
    }
    return actual;
}

std::uint32_t requireDimension(const json &value, const std::string &description) {
    const std::uint64_t dimension = requireUnsignedInteger(value, description);
    if (dimension == 0 || dimension > kMaximumMaskDimension) {
        fail(description + " is outside the supported range");
    }
    return static_cast<std::uint32_t>(dimension);
}

bool sameView(const MaskView &left, const MaskView &right) {
    return left.identity == right.identity &&
        left.cameraIndex == right.cameraIndex &&
        left.heldOut == right.heldOut &&
        left.relativePath == right.relativePath &&
        left.sha256 == right.sha256 &&
        left.width == right.width &&
        left.height == right.height;
}

std::uint32_t bigEndianUInt32(const std::uint8_t *bytes) {
    return
        (static_cast<std::uint32_t>(bytes[0]) << 24) |
        (static_cast<std::uint32_t>(bytes[1]) << 16) |
        (static_cast<std::uint32_t>(bytes[2]) << 8) |
        static_cast<std::uint32_t>(bytes[3]);
}

void inspectPngContainer(
    const std::vector<std::uint8_t> &bytes,
    const MaskView &view
) {
    constexpr std::array<std::uint8_t, 8> signature = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    };
    if (bytes.size() < 33 ||
        !std::equal(signature.begin(), signature.end(), bytes.begin())) {
        fail("mask is not a PNG");
    }
    if (bigEndianUInt32(bytes.data() + 8) != 13 ||
        std::memcmp(bytes.data() + 12, "IHDR", 4) != 0) {
        fail("mask PNG has no canonical leading IHDR");
    }
    if (bigEndianUInt32(bytes.data() + 16) != view.width ||
        bigEndianUInt32(bytes.data() + 20) != view.height) {
        fail("mask PNG dimensions do not match the authenticated view");
    }
    if (bytes[24] != 8 || bytes[25] != 0) {
        fail("mask PNG must be native 8-bit grayscale");
    }
    if (bytes[26] != 0 || bytes[27] != 0) {
        fail("mask PNG uses an unsupported compression or filter method");
    }
    if (bytes[28] != 0) {
        fail("interlaced mask PNGs are unsupported");
    }

    bool sawIdat = false;
    bool sawIend = false;
    std::size_t offset = 8;
    while (offset < bytes.size()) {
        if (bytes.size() - offset < 12) fail("mask PNG chunk is truncated");
        const std::uint32_t length = bigEndianUInt32(bytes.data() + offset);
        if (static_cast<std::uint64_t>(length) + 12 >
            static_cast<std::uint64_t>(bytes.size() - offset)) {
            fail("mask PNG chunk exceeds the file");
        }
        const std::uint8_t *type = bytes.data() + offset + 4;
        if (offset != 8 && std::memcmp(type, "IHDR", 4) == 0) {
            fail("mask PNG contains more than one IHDR");
        }
        if (std::memcmp(type, "IDAT", 4) == 0) sawIdat = true;
        if (std::memcmp(type, "tRNS", 4) == 0) {
            fail("mask PNG transparency would change label semantics");
        }
        if (std::memcmp(type, "acTL", 4) == 0 ||
            std::memcmp(type, "fcTL", 4) == 0 ||
            std::memcmp(type, "fdAT", 4) == 0) {
            fail("animated mask PNGs are unsupported");
        }
        if (std::memcmp(type, "IEND", 4) == 0) {
            if (length != 0 || offset + 12 != bytes.size()) {
                fail("mask PNG has a malformed or nonterminal IEND");
            }
            sawIend = true;
            break;
        }
        offset += static_cast<std::size_t>(length) + 12;
    }
    if (!sawIdat || !sawIend) {
        fail("mask PNG requires image data and a terminal IEND");
    }
}

template <typename Number>
Number dictionaryNumber(
    CFDictionaryRef properties,
    CFStringRef key,
    const std::string &description,
    bool required = true
) {
    const void *raw = CFDictionaryGetValue(properties, key);
    if (raw == nullptr) {
        if (!required) return Number {};
        fail(description + " is missing");
    }
    const CFTypeRef value = static_cast<CFTypeRef>(raw);
    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        fail(description + " has the wrong property type");
    }
    std::int64_t result = 0;
    if (!CFNumberGetValue(
            static_cast<CFNumberRef>(value),
            kCFNumberSInt64Type,
            &result
        ) ||
        result < 0 ||
        static_cast<std::uint64_t>(result) >
            static_cast<std::uint64_t>(std::numeric_limits<Number>::max())) {
        fail(description + " is outside the supported range");
    }
    return static_cast<Number>(result);
}

void validateImageProperties(
    CFDictionaryRef properties,
    const MaskView &view
) {
    if (dictionaryNumber<std::uint32_t>(
            properties,
            kCGImagePropertyPixelWidth,
            "mask pixel width"
        ) != view.width ||
        dictionaryNumber<std::uint32_t>(
            properties,
            kCGImagePropertyPixelHeight,
            "mask pixel height"
        ) != view.height) {
        fail("ImageIO mask dimensions do not match the authenticated view");
    }
    if (dictionaryNumber<std::uint32_t>(
            properties,
            kCGImagePropertyDepth,
            "mask bit depth"
        ) != 8) {
        fail("ImageIO mask depth is not 8-bit");
    }

    const void *rawModel =
        CFDictionaryGetValue(properties, kCGImagePropertyColorModel);
    if (rawModel == nullptr ||
        CFGetTypeID(static_cast<CFTypeRef>(rawModel)) != CFStringGetTypeID() ||
        !CFEqual(rawModel, kCGImagePropertyColorModelGray)) {
        fail("ImageIO mask color model is not grayscale");
    }

    const void *rawAlpha =
        CFDictionaryGetValue(properties, kCGImagePropertyHasAlpha);
    if (rawAlpha != nullptr) {
        if (CFGetTypeID(static_cast<CFTypeRef>(rawAlpha)) != CFBooleanGetTypeID()) {
            fail("ImageIO mask alpha property has the wrong type");
        }
        if (CFBooleanGetValue(static_cast<CFBooleanRef>(rawAlpha))) {
            fail("ImageIO mask unexpectedly has alpha");
        }
    }

    const void *rawOrientation =
        CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
    if (rawOrientation != nullptr &&
        dictionaryNumber<std::uint32_t>(
            properties,
            kCGImagePropertyOrientation,
            "mask orientation"
        ) != kCGImagePropertyOrientationUp) {
        fail("mask orientation metadata requires a transform");
    }

    const void *rawPng =
        CFDictionaryGetValue(properties, kCGImagePropertyPNGDictionary);
    if (rawPng != nullptr) {
        if (CFGetTypeID(static_cast<CFTypeRef>(rawPng)) != CFDictionaryGetTypeID()) {
            fail("ImageIO PNG properties have the wrong type");
        }
        const auto png = static_cast<CFDictionaryRef>(rawPng);
        if (CFDictionaryContainsKey(png, kCGImagePropertyPNGInterlaceType) &&
            dictionaryNumber<std::uint32_t>(
                png,
                kCGImagePropertyPNGInterlaceType,
                "mask PNG interlace type"
            ) != 0) {
            fail("interlaced mask PNGs are unsupported");
        }
    }
}

struct ProviderBytes {
    explicit ProviderBytes(std::vector<std::uint8_t> bytes)
        : bytes(std::move(bytes)) {}
    std::vector<std::uint8_t> bytes;
};

void releaseProviderBytes(void *info, const void *, std::size_t) {
    delete static_cast<ProviderBytes *>(info);
}

DecodedMask decodePng(
    std::vector<std::uint8_t> bytes,
    const MaskView &view,
    const std::function<bool()> &isCancelled
) {
    auto *providerBytes = new ProviderBytes(std::move(bytes));
    CGDataProviderRef rawProvider = CGDataProviderCreateWithData(
        providerBytes,
        providerBytes->bytes.data(),
        providerBytes->bytes.size(),
        releaseProviderBytes
    );
    if (rawProvider == nullptr) {
        delete providerBytes;
        fail("cannot create direct mask data provider");
    }
    CFReference<CGDataProviderRef> provider(rawProvider);

    CFReference<CGImageSourceRef> source(
        CGImageSourceCreateWithDataProvider(provider.get(), nullptr)
    );
    if (source.get() == nullptr ||
        CGImageSourceGetCount(source.get()) != 1 ||
        CGImageSourceGetStatus(source.get()) != kCGImageStatusComplete ||
        CGImageSourceGetStatusAtIndex(source.get(), 0) != kCGImageStatusComplete) {
        fail("ImageIO could not decode a complete single-image mask");
    }
    const CFStringRef type = CGImageSourceGetType(source.get());
    if (type == nullptr || !CFEqual(type, CFSTR("public.png"))) {
        fail("mask data provider did not decode as PNG");
    }

    CFReference<CFDictionaryRef> properties(
        CGImageSourceCopyPropertiesAtIndex(source.get(), 0, nullptr)
    );
    if (properties.get() == nullptr) fail("ImageIO mask properties are unavailable");
    validateImageProperties(properties.get(), view);
    checkCancellation(isCancelled);

    const void *optionKeys[] = {
        kCGImageSourceShouldCache,
        kCGImageSourceShouldCacheImmediately,
        kCGImageSourceShouldAllowFloat,
    };
    const void *optionValues[] = {
        kCFBooleanTrue,
        kCFBooleanTrue,
        kCFBooleanFalse,
    };
    CFReference<CFDictionaryRef> options(CFDictionaryCreate(
        kCFAllocatorDefault,
        optionKeys,
        optionValues,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    ));
    if (options.get() == nullptr) fail("cannot create ImageIO mask options");

    CFReference<CGImageRef> image(
        CGImageSourceCreateImageAtIndex(source.get(), 0, options.get())
    );
    if (image.get() == nullptr) fail("ImageIO could not create the mask image");
    if (CGImageGetWidth(image.get()) != view.width ||
        CGImageGetHeight(image.get()) != view.height ||
        CGImageGetBitsPerComponent(image.get()) != 8 ||
        CGImageGetBitsPerPixel(image.get()) != 8) {
        fail("decoded mask is not exact 8-bit grayscale");
    }
    const CGColorSpaceRef colorSpace = CGImageGetColorSpace(image.get());
    if (colorSpace == nullptr ||
        CGColorSpaceGetModel(colorSpace) != kCGColorSpaceModelMonochrome ||
        CGColorSpaceGetNumberOfComponents(colorSpace) != 1 ||
        CGImageIsMask(image.get()) ||
        CGImageGetAlphaInfo(image.get()) != kCGImageAlphaNone ||
        CGImageGetDecode(image.get()) != nullptr) {
        fail("decoded mask would require color, alpha, or sample conversion");
    }

    const std::size_t rowBytes = CGImageGetBytesPerRow(image.get());
    if (rowBytes < view.width ||
        view.height > std::numeric_limits<std::size_t>::max() / rowBytes) {
        fail("decoded mask row layout is invalid");
    }
    CGDataProviderRef decodedProvider = CGImageGetDataProvider(image.get());
    if (decodedProvider == nullptr) fail("decoded mask provider is unavailable");
    CFReference<CFDataRef> decodedData(CGDataProviderCopyData(decodedProvider));
    if (decodedData.get() == nullptr ||
        CFDataGetLength(decodedData.get()) <
            static_cast<CFIndex>(rowBytes * view.height)) {
        fail("decoded mask provider is truncated");
    }

    const auto *decodedBytes = CFDataGetBytePtr(decodedData.get());
    if (decodedBytes == nullptr) fail("decoded mask bytes are unavailable");
    DecodedMask result;
    result.width = view.width;
    result.height = view.height;
    result.pixels.resize(
        static_cast<std::size_t>(view.width) *
        static_cast<std::size_t>(view.height)
    );
    std::array<bool, 256> labels {};
    labels[0] = true;
    for (std::size_t row = 0; row < view.height; ++row) {
        checkCancellation(isCancelled);
        const auto *sourceRow = decodedBytes + row * rowBytes;
        auto *destination =
            result.pixels.data() + row * static_cast<std::size_t>(view.width);
        std::copy(sourceRow, sourceRow + view.width, destination);
        for (std::size_t column = 0; column < view.width; ++column) {
            labels[sourceRow[column]] = true;
        }
    }
    for (std::size_t label = 0; label < labels.size(); ++label) {
        if (labels[label]) result.labels.push_back(static_cast<std::uint8_t>(label));
    }
    checkCancellation(isCancelled);
    return result;
}

} // namespace

MaskManifest loadMaskManifest(
    const fs::path &path,
    const MaskExpectedDigests &expectedDigests,
    const std::function<bool()> &isCancelled
) {
    const std::vector<std::uint8_t> bytes = readManifestBytes(path, isCancelled);
    const json document = parseStrictJson(bytes);
    requireExactKeys(document, manifestKeys, "mask manifest");
    if (requireUnsignedInteger(
            document.at("schema_version"),
            "schema_version"
        ) != kMaskManifestSchemaVersion ||
        requireUnsignedInteger(
            document.at("isolation_mode_version"),
            "isolation_mode_version"
        ) != kIsolationModeVersion) {
        fail("mask manifest schema or isolation mode version is unsupported");
    }

    MaskManifest manifest;
    manifest.path = path;
    manifest.root = path.parent_path().empty() ? fs::path(".") : path.parent_path();
    manifest.digests = parseDigests(document, expectedDigests);

    const json &order = document.at("selected_image_order");
    const json &views = document.at("views");
    if (!order.is_array() || !views.is_array() ||
        views.size() < 2 || views.size() > kMaximumMaskViews ||
        order.size() != views.size()) {
        fail("mask manifest must contain two to 24 ordered views");
    }

    manifest.selectedImageOrder.reserve(order.size());
    for (std::size_t index = 0; index < order.size(); ++index) {
        const std::string identity = requireString(
            order.at(index),
            "selected_image_order identity"
        );
        if (identity.empty() ||
            identity.size() > kMaximumMaskIdentityBytes) {
            fail("selected image identity is outside the supported length");
        }
        manifest.selectedImageOrder.push_back(identity);
    }

    std::set<std::string> identities;
    std::set<std::size_t> cameraIndices;
    std::set<std::string> maskPaths;
    bool hasWork = false;
    bool hasHeldOut = false;
    manifest.views.reserve(views.size());
    for (std::size_t index = 0; index < views.size(); ++index) {
        checkCancellation(isCancelled);
        const json &record = views.at(index);
        requireExactKeys(record, viewKeys, "mask view");

        MaskView view;
        view.identity = requireString(
            record.at("image_identity"),
            "mask image_identity"
        );
        if (view.identity.empty() ||
            view.identity.size() > kMaximumMaskIdentityBytes) {
            fail("mask image_identity is outside the supported length");
        }
        const std::uint64_t cameraIndex = requireUnsignedInteger(
            record.at("camera_index"),
            "mask camera_index"
        );
        if (cameraIndex > std::numeric_limits<std::size_t>::max()) {
            fail("mask camera_index is outside the supported range");
        }
        view.cameraIndex = static_cast<std::size_t>(cameraIndex);

        const std::string role = requireString(record.at("role"), "mask role");
        if (role == "work") {
            hasWork = true;
        } else if (role == "held_out") {
            view.heldOut = true;
            hasHeldOut = true;
        } else {
            fail("mask role must be work or held_out");
        }

        const std::string relativePath = requireString(
            record.at("relative_mask_path"),
            "relative_mask_path"
        );
        (void)pathComponents(relativePath);
        view.relativePath = fs::path(relativePath);
        view.sha256 = requireString(record.at("mask_sha256"), "mask_sha256");
        if (!isLowercaseDigest(view.sha256)) {
            fail("mask_sha256 must be 64 lowercase hexadecimal characters");
        }
        view.width = requireDimension(record.at("width"), "mask width");
        view.height = requireDimension(record.at("height"), "mask height");
        if (static_cast<std::uint64_t>(view.width) * view.height >
            kMaximumDecodedMaskPixelCount) {
            fail("mask dimensions exceed the decoded pixel limit");
        }

        if (manifest.selectedImageOrder[index] != view.identity) {
            fail("selected_image_order does not exactly match mask view order");
        }
        if (!identities.insert(view.identity).second) {
            fail("mask image identities must be unique");
        }
        if (!cameraIndices.insert(view.cameraIndex).second) {
            fail("mask camera indexes must be unique");
        }
        if (!maskPaths.insert(relativePath).second) {
            fail("mask relative paths must be unique");
        }
        manifest.views.push_back(std::move(view));
    }
    if (!hasWork || !hasHeldOut) {
        fail("mask manifest requires at least one work and one held-out view");
    }
    checkCancellation(isCancelled);
    return manifest;
}

void validateMaskManifestViews(
    const MaskManifest &manifest,
    const std::vector<ExpectedMaskView> &expectedViews
) {
    if (expectedViews.size() != manifest.views.size()) {
        fail("mask view count does not match the authenticated dataset");
    }
    for (std::size_t index = 0; index < expectedViews.size(); ++index) {
        const ExpectedMaskView &expected = expectedViews[index];
        const MaskView &actual = manifest.views[index];
        if (expected.identity != actual.identity ||
            expected.cameraIndex != actual.cameraIndex ||
            expected.width != actual.width ||
            expected.height != actual.height) {
            fail("mask view order or dimensions do not match the authenticated dataset");
        }
    }
}

DecodedMask decodeMask(
    const MaskManifest &manifest,
    const MaskView &view,
    const std::function<bool()> &isCancelled,
    std::uint64_t maximumEncodedAndDecodedBytes
) {
    checkCancellation(isCancelled);
    if (std::none_of(
            manifest.views.begin(),
            manifest.views.end(),
            [&](const MaskView &candidate) { return sameView(candidate, view); }
        )) {
        fail("mask view does not belong to the authenticated manifest");
    }
    if (view.width > std::numeric_limits<std::uint64_t>::max() / view.height) {
        fail("mask dimensions overflow the decoder");
    }
    const std::uint64_t decodedBytes =
        static_cast<std::uint64_t>(view.width) * view.height;
    if (decodedBytes >= maximumEncodedAndDecodedBytes) {
        fail("decoded mask exceeds its byte budget");
    }
    const std::uint64_t maximumEncodedBytes = std::min(
        maximumEncodedAndDecodedBytes - decodedBytes,
        kMaximumEncodedMaskBytes
    );
    std::vector<std::uint8_t> bytes = readRelativeMaskBytes(
        manifest.root,
        view.relativePath.generic_string(),
        maximumEncodedBytes,
        isCancelled
    );
    if (sha256(bytes) != view.sha256) {
        fail("mask SHA-256 does not match the manifest");
    }
    inspectPngContainer(bytes, view);
    checkCancellation(isCancelled);
    return decodePng(std::move(bytes), view, isCancelled);
}

} // namespace easysplat::isolation
