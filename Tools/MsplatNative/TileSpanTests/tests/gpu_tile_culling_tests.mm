#include "gpu_tile_culling.hpp"
#include "tile_culling.hpp"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

std::vector<culling::GPUCase> makeCases() {
    std::vector<culling::GPUCase> cases {
        {1.0f, 0.0f, 1.0f, 23.0f, 23.0f, 16.0f, 16.0f, 31.0f, 31.0f, 0.0f},
        {1.0f, 0.0f, 1.0f, 15.0f, 20.0f, 16.0f, 16.0f, 31.0f, 31.0f, 0.5f},
        {1.0f, 0.0f, 1.0f, 14.99f, 20.0f, 16.0f, 16.0f, 31.0f, 31.0f, 0.5f},
        {0.0f, 0.0f, 0.0f, 20.0f, 20.0f, 16.0f, 16.0f, 31.0f, 31.0f, 4.5f},
        {NAN, 0.0f, 1.0f, 20.0f, 20.0f, 16.0f, 16.0f, 31.0f, 31.0f, 4.5f},
    };

    std::mt19937 rng(0xC011u);
    std::uniform_real_distribution<float> center(-128.0f, 384.0f);
    std::uniform_real_distribution<float> angle(-3.14159265f, 3.14159265f);
    std::uniform_real_distribution<float> logEigen(-6.0f, 4.0f);
    std::uniform_real_distribution<float> limit(0.0f, 5.55f);
    std::uniform_int_distribution<int> tileIndex(0, 15);

    cases.reserve(200005);
    for (int sample = 0; sample < 200000; ++sample) {
        const float theta = angle(rng);
        const float cs = std::cos(theta);
        const float sn = std::sin(theta);
        const float e0 = std::exp(logEigen(rng));
        const float e1 = std::exp(logEigen(rng));
        const float a = cs * cs * e0 + sn * sn * e1;
        const float b = cs * sn * (e0 - e1);
        const float c = sn * sn * e0 + cs * cs * e1;
        const int tx = tileIndex(rng);
        const int ty = tileIndex(rng);
        cases.push_back({
            a, b, c, center(rng), center(rng),
            static_cast<float>(tx * 16), static_cast<float>(ty * 16),
            static_cast<float>(tx * 16 + 15), static_cast<float>(ty * 16 + 15),
            limit(rng)
        });
    }
    return cases;
}

std::vector<culling::GPURowCase> makeRowCases() {
    std::vector<culling::GPURowCase> cases;
    cases.reserve(200000);
    std::mt19937 rng(0x5A6B07u);
    std::uniform_real_distribution<float> center(-128.0f, 384.0f);
    std::uniform_real_distribution<float> angle(-3.14159265f, 3.14159265f);
    std::uniform_real_distribution<float> logEigen(-6.0f, 4.0f);
    std::uniform_real_distribution<float> limit(0.0f, 5.55f);
    std::uniform_int_distribution<std::uint32_t> row(0, 15);

    for (int sample = 0; sample < 200000; ++sample) {
        const float theta = angle(rng);
        const float cs = std::cos(theta);
        const float sn = std::sin(theta);
        const float e0 = std::exp(logEigen(rng));
        const float e1 = std::exp(logEigen(rng));
        cases.push_back({
            cs * cs * e0 + sn * sn * e1,
            cs * sn * (e0 - e1),
            sn * sn * e0 + cs * cs * e1,
            center(rng), center(rng), limit(rng), row(rng),
            256, 256, 0, 16
        });
    }
    return cases;
}

} // namespace

int main(int argc, char** argv) {
    try {
        require(argc == 2, "usage: gpu_tile_culling_tests <metallib>");
        const auto cases = makeCases();
        const auto actual = culling::evaluateOnGPU(cases, argv[1]);
        require(actual.size() == cases.size(), "GPU result count mismatch");

        std::uint64_t mismatchCount = 0;
        for (std::size_t index = 0; index < cases.size(); ++index) {
            const auto& item = cases[index];
            const bool expected = culling::ellipseIntersectsPixelTile(
                {item.a, item.b, item.c}, item.meanX, item.meanY,
                {item.minX, item.minY, item.maxX, item.maxY}, item.powerLimit);
            if (static_cast<bool>(actual[index]) != expected) {
                ++mismatchCount;
                if (mismatchCount <= 5) {
                    std::cerr << "mismatch at " << index << ": cpu=" << expected
                              << " gpu=" << actual[index] << '\n';
                }
            }
        }
        require(mismatchCount == 0,
                "GPU predicate disagreed with CPU predicate " +
                    std::to_string(mismatchCount) + " times");

        const auto rowCases = makeRowCases();
        const auto rowActual = culling::evaluateRowSpansOnGPU(rowCases, argv[1]);
        require(rowActual.size() == rowCases.size(), "GPU row result count mismatch");
        std::uint64_t rowMismatchCount = 0;
        std::uint64_t rowFalseNegativeCount = 0;
        for (std::size_t index = 0; index < rowCases.size(); ++index) {
            const auto& item = rowCases[index];
            const auto expected = culling::ellipseTileRowSpan(
                {item.a, item.b, item.c}, item.meanX, item.meanY,
                static_cast<int>(item.tileRow),
                static_cast<int>(item.imageWidth),
                static_cast<int>(item.imageHeight), item.powerLimit,
                static_cast<int>(item.broadBegin),
                static_cast<int>(item.broadEnd)
            );
            const auto& actualSpan = rowActual[index];
            const bool same = static_cast<bool>(actualSpan.included) == expected.has_value() &&
                (!expected ||
                 (actualSpan.begin == static_cast<std::uint32_t>(expected->begin) &&
                  actualSpan.end == static_cast<std::uint32_t>(expected->end)));
            rowMismatchCount += !same;

            for (std::uint32_t column = item.broadBegin;
                 column < item.broadEnd; ++column) {
                const bool exact = culling::ellipseIntersectsPixelTile(
                    {item.a, item.b, item.c}, item.meanX, item.meanY,
                    {
                        static_cast<float>(column * 16),
                        static_cast<float>(item.tileRow * 16),
                        static_cast<float>(column * 16 + 15),
                        static_cast<float>(item.tileRow * 16 + 15)
                    },
                    item.powerLimit
                );
                const bool included = actualSpan.included &&
                    column >= actualSpan.begin && column < actualSpan.end;
                rowFalseNegativeCount += exact && !included;
            }
        }
        require(rowMismatchCount == 0,
                "GPU row span disagreed with CPU row span " +
                    std::to_string(rowMismatchCount) + " times");
        require(rowFalseNegativeCount == 0,
                "GPU row span dropped " +
                    std::to_string(rowFalseNegativeCount) + " exact tiles");
        std::cout << "gpu_tile_culling_tests: PASS (" << cases.size()
                  << " predicates, " << rowCases.size() << " row spans)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "gpu_tile_culling_tests: FAIL: " << error.what() << '\n';
        return 1;
    }
}
