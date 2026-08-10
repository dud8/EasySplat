// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include "isolation_mask.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace easysplat::isolation;

namespace {

constexpr std::array<std::uint8_t, 71> grayMask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xdd, 0x52, 0xf8, 0x00, 0x00, 0x00,
    0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x60, 0x67, 0xf8,
    0xcf, 0x08, 0x00, 0x02, 0x21, 0x01, 0x08, 0x40, 0xfa, 0x6b, 0x86, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

constexpr std::array<std::uint8_t, 69> rgbMask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
    0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x64, 0x62, 0x06,
    0x00, 0x00, 0x0e, 0x00, 0x07, 0xd7, 0x6f, 0xe4, 0x78, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

constexpr std::array<std::uint8_t, 68> gray16Mask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x6a, 0xee, 0x47, 0x16, 0x00, 0x00, 0x00,
    0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x10, 0x32, 0x01, 0x00,
    0x00, 0x5b, 0x00, 0x47, 0x96, 0xfb, 0x1b, 0x65, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

constexpr std::array<std::uint8_t, 67> interlacedMask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x00, 0x00, 0x00, 0x01, 0x4d, 0x79, 0xab, 0xc3, 0x00, 0x00, 0x00,
    0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xe0, 0x04, 0x00, 0x00,
    0x0b, 0x00, 0x0a, 0xc3, 0x2b, 0xee, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

constexpr std::array<std::uint8_t, 109> orientedMask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x57, 0xdd, 0x52, 0xf8, 0x00, 0x00, 0x00,
    0x1a, 0x65, 0x58, 0x49, 0x66, 0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb7, 0x48, 0x11, 0x29, 0x00,
    0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x60,
    0x67, 0xf8, 0xcf, 0x08, 0x00, 0x02, 0x21, 0x01, 0x08, 0x40, 0xfa, 0x6b,
    0x86, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
    0x82,
};

constexpr std::array<std::uint8_t, 67> foregroundOnlyMask = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x3a, 0x7e, 0x9b, 0x55, 0x00, 0x00, 0x00,
    0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xe0, 0x04, 0x00, 0x00,
    0x0b, 0x00, 0x0a, 0xc3, 0x2b, 0xee, 0x92, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

template <typename Function>
void requireRejected(Function &&function, const std::string &message) {
    try {
        function();
    } catch (const MaskValidationError &) {
        return;
    }
    throw std::runtime_error(message);
}

struct TemporaryDirectory {
    TemporaryDirectory() {
        std::array<char, 256> pattern {};
        const std::string value =
            (fs::temp_directory_path() / "easysplat-mask-tests-XXXXXX").string();
        require(value.size() < pattern.size(), "temporary path is too long");
        std::copy(value.begin(), value.end(), pattern.begin());
        const char *created = ::mkdtemp(pattern.data());
        require(created != nullptr, "cannot create temporary directory");
        path = created;
    }

    ~TemporaryDirectory() {
        std::error_code ignored;
        fs::remove_all(path, ignored);
    }

    fs::path path;
};

template <std::size_t Size>
void writeBytes(const fs::path &path, const std::array<std::uint8_t, Size> &bytes) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    require(output.good(), "cannot create fixture");
    output.write(
        reinterpret_cast<const char *>(bytes.data()),
        static_cast<std::streamsize>(bytes.size())
    );
    require(output.good(), "cannot write fixture");
}

void writeText(const fs::path &path, const std::string &contents) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    require(output.good(), "cannot create manifest fixture");
    output << contents;
    require(output.good(), "cannot write manifest fixture");
}

MaskExpectedDigests expectedDigests() {
    return {
        std::string(64, '1'),
        std::string(64, '2'),
        std::string(64, '3'),
        std::string(64, '4'),
        std::string(64, '5'),
    };
}

std::vector<ExpectedMaskView> expectedViews(
    std::uint32_t width = 2,
    std::uint32_t height = 2
) {
    return {
        {"frame-0001.png", 3, width, height},
        {"frame-0002.png", 8, width, height},
    };
}

std::string manifestText(
    const std::string &relativePath = "masks/frame-0001.png",
    const std::string &maskDigest =
        "239351054a77834fe0ac416b1bc4e946743f58f65d73fff42b3928b440b825cd",
    std::uint32_t width = 2,
    std::uint32_t height = 2
) {
    return
        "{"
        "\"schema_version\":1,"
        "\"isolation_mode_version\":1,"
        "\"source_ply_digest\":\"" + std::string(64, '1') + "\","
        "\"input_digest\":\"" + std::string(64, '2') + "\","
        "\"geometry_digest\":\"" + std::string(64, '3') + "\","
        "\"selected_frames_digest\":\"" + std::string(64, '4') + "\","
        "\"training_manifest_digest\":\"" + std::string(64, '5') + "\","
        "\"selected_image_order\":[\"frame-0001.png\",\"frame-0002.png\"],"
        "\"views\":["
        "{"
        "\"image_identity\":\"frame-0001.png\","
        "\"camera_index\":3,"
        "\"role\":\"work\","
        "\"relative_mask_path\":\"" + relativePath + "\","
        "\"mask_sha256\":\"" + maskDigest + "\","
        "\"width\":" + std::to_string(width) + ","
        "\"height\":" + std::to_string(height) +
        "},"
        "{"
        "\"image_identity\":\"frame-0002.png\","
        "\"camera_index\":8,"
        "\"role\":\"held_out\","
        "\"relative_mask_path\":\"masks/frame-0002.png\","
        "\"mask_sha256\":\"" + maskDigest + "\","
        "\"width\":" + std::to_string(width) + ","
        "\"height\":" + std::to_string(height) +
        "}"
        "]"
        "}";
}

void testStrictManifestAndExactDecode() {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", grayMask);
    writeText(temporary.path / "manifest.json", manifestText());

    const MaskManifest manifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(manifest, expectedViews());
    require(manifest.views.size() == 2, "manifest view count changed");
    require(!manifest.views[0].heldOut, "work role changed");
    require(manifest.views[1].heldOut, "held-out role changed");

    const DecodedMask decoded =
        decodeMask(manifest, manifest.views[0], [] { return false; }, 1024 * 1024);
    require(decoded.width == 2 && decoded.height == 2, "decoded dimensions changed");
    require(
        decoded.pixels == std::vector<std::uint8_t>({0, 7, 255, 1}),
        "lossless label bytes changed"
    );
    require(
        decoded.labels == std::vector<std::uint8_t>({0, 1, 7, 255}),
        "labels are not unique and canonical"
    );
}

void testClosedSchemaAndAuthenticatedOrder() {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", grayMask);

    std::string unexpected = manifestText();
    unexpected.insert(unexpected.size() - 1, ",\"unexpected\":true");
    writeText(temporary.path / "manifest.json", unexpected);
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "unexpected top-level field was accepted"
    );

    std::string wrongOrder = manifestText();
    const std::string declared =
        "\"selected_image_order\":[\"frame-0001.png\",\"frame-0002.png\"]";
    const std::string reversed =
        "\"selected_image_order\":[\"frame-0002.png\",\"frame-0001.png\"]";
    wrongOrder.replace(wrongOrder.find(declared), declared.size(), reversed);
    writeText(temporary.path / "manifest.json", wrongOrder);
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "selected image order mismatch was accepted"
    );

    std::string uppercaseDigest = manifestText();
    uppercaseDigest.replace(uppercaseDigest.find(std::string(64, '1')), 1, "A");
    writeText(temporary.path / "manifest.json", uppercaseDigest);
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "uppercase digest was accepted"
    );

    std::string duplicateViewKey = manifestText();
    const std::string cameraIndex = "\"camera_index\":3";
    duplicateViewKey.replace(
        duplicateViewKey.find(cameraIndex),
        cameraIndex.size(),
        "\"image_identity\":\"duplicate.png\",\"camera_index\":3"
    );
    writeText(temporary.path / "manifest.json", duplicateViewKey);
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "duplicate view key was accepted"
    );

    std::string floatingVersion = manifestText();
    const std::string integerVersion = "\"schema_version\":1";
    floatingVersion.replace(
        floatingVersion.find(integerVersion),
        integerVersion.size(),
        "\"schema_version\":1.0"
    );
    writeText(temporary.path / "manifest.json", floatingVersion);
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "floating-point schema version was accepted"
    );

    writeText(
        temporary.path / "manifest.json",
        manifestText("masks/frame-0001.png", std::string(64, 'a'), 4097, 1)
    );
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "oversized mask dimensions were accepted"
    );
}

void testSafePathsAndStableFiles() {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", grayMask);
    writeText(
        temporary.path / "manifest.json",
        manifestText("masks/../frame-0001.png")
    );
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "parent traversal was accepted"
    );

    writeText(temporary.path / "manifest.json", manifestText());
    fs::create_hard_link(
        temporary.path / "manifest.json",
        temporary.path / "manifest-hard-link.json"
    );
    requireRejected(
        [&] {
            (void)loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
        },
        "multiply linked manifest was accepted"
    );

    fs::remove(temporary.path / "manifest-hard-link.json");
    writeText(temporary.path / "manifest.json", manifestText());
    fs::create_hard_link(
        temporary.path / "masks/frame-0001.png",
        temporary.path / "masks/frame-0001-hard-link.png"
    );
    const auto manifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(manifest, expectedViews());
    requireRejected(
        [&] {
            (void)decodeMask(
                manifest,
                manifest.views[0],
                [] { return false; },
                1024 * 1024
            );
        },
        "multiply linked mask was accepted"
    );
}

template <std::size_t Size>
void requireMaskRejected(
    const std::array<std::uint8_t, Size> &bytes,
    const std::string &digest,
    std::uint32_t width,
    std::uint32_t height,
    const std::string &message
) {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", bytes);
    writeText(
        temporary.path / "manifest.json",
        manifestText("masks/frame-0001.png", digest, width, height)
    );
    const auto manifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(manifest, expectedViews(width, height));
    requireRejected(
        [&] {
            (void)decodeMask(
                manifest,
                manifest.views[0],
                [] { return false; },
                1024 * 1024
            );
        },
        message
    );
}

void testRejectsConvertedAndTransformedMasks() {
    requireMaskRejected(
        rgbMask,
        "f8b784c85c7c8173fdcfc74daee9fc36f7f209d8b145abd05e2918619420edae",
        1,
        1,
        "RGB mask was silently converted"
    );
    requireMaskRejected(
        gray16Mask,
        "96fc54ae18eaf857ab48e9ab378a985a97bc70b59496e1aab3f70348780d256b",
        1,
        1,
        "16-bit mask was silently converted"
    );
    requireMaskRejected(
        interlacedMask,
        "21270464da8c9ee76e07cc03da388f3b2f722d4ea7d99f61784a7e35484ffbef",
        1,
        1,
        "interlaced mask was accepted"
    );
    requireMaskRejected(
        orientedMask,
        "f41562c28de158fa9b59672b5123715c05c208b2a0569aa9acb1d5281ffd3655",
        2,
        2,
        "oriented mask was accepted without refusing the transform"
    );
}

void testLabelZeroIsAlwaysDeclared() {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", foregroundOnlyMask);
    writeText(
        temporary.path / "manifest.json",
        manifestText(
            "masks/frame-0001.png",
            "746dc489db4febabdf6b5f6e8fc44b0bf44343be023e8c58926eeb41e64f3b82",
            1,
            1
        )
    );
    const auto manifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(manifest, expectedViews(1, 1));
    const auto decoded = decodeMask(
        manifest,
        manifest.views[0],
        [] { return false; },
        1024 * 1024
    );
    require(decoded.pixels == std::vector<std::uint8_t>({9}), "mask byte changed");
    require(
        decoded.labels == std::vector<std::uint8_t>({0, 9}),
        "background label zero was not declared"
    );
}

void testDigestDimensionAndBudgetRefusals() {
    TemporaryDirectory temporary;
    fs::create_directory(temporary.path / "masks");
    writeBytes(temporary.path / "masks/frame-0001.png", grayMask);

    writeText(temporary.path / "manifest.json", manifestText());
    const auto manifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(manifest, expectedViews());
    requireRejected(
        [&] {
            (void)decodeMask(
                manifest,
                manifest.views[0],
                [] { return false; },
                grayMask.size()
            );
        },
        "encoded-plus-decoded mask exceeded the byte budget"
    );

    writeText(
        temporary.path / "manifest.json",
        manifestText(
            "masks/frame-0001.png",
            std::string(64, 'a')
        )
    );
    const auto staleManifest = loadMaskManifest(
        temporary.path / "manifest.json",
        expectedDigests(),
        [] { return false; }
    );
    validateMaskManifestViews(staleManifest, expectedViews());
    requireRejected(
        [&] {
            (void)decodeMask(
                staleManifest,
                staleManifest.views[0],
                [] { return false; },
                1024 * 1024
            );
        },
        "mask digest mismatch was accepted"
    );

    writeText(temporary.path / "manifest.json", manifestText());
    requireRejected(
        [&] {
            const auto mismatched = loadMaskManifest(
                temporary.path / "manifest.json",
                expectedDigests(),
                [] { return false; }
            );
            validateMaskManifestViews(mismatched, expectedViews(3, 2));
        },
        "dataset-to-mask dimension mismatch was accepted"
    );
}

} // namespace

int main() {
    try {
        testStrictManifestAndExactDecode();
        testClosedSchemaAndAuthenticatedOrder();
        testSafePathsAndStableFiles();
        testRejectsConvertedAndTransformedMasks();
        testLabelZeroIsAlwaysDeclared();
        testDigestDimensionAndBudgetRefusals();
        std::cout << "native isolation mask fixtures passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "native isolation mask fixture failed: " << error.what() << '\n';
        return 1;
    }
}
