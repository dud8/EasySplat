#include "tile_culling.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using culling::Conic;
using culling::Rect;

double powerAt(const Conic<double>& conic, double meanX, double meanY, double x, double y) {
    const double dx = x - meanX;
    const double dy = y - meanY;
    return 0.5 * conic.a * dx * dx + conic.b * dx * dy + 0.5 * conic.c * dy * dy;
}

double oracleMinimumPower(
    const Conic<double>& conic,
    double meanX,
    double meanY,
    const Rect<double>& rect
) {
    if (meanX >= rect.minX && meanX <= rect.maxX &&
        meanY >= rect.minY && meanY <= rect.maxY) {
        return 0.0;
    }

    double result = std::numeric_limits<double>::infinity();
    for (double x : {rect.minX, rect.maxX}) {
        const double dx = x - meanX;
        const double dy = std::clamp(-conic.b * dx / conic.c,
                                     rect.minY - meanY,
                                     rect.maxY - meanY);
        result = std::min(result, powerAt(conic, meanX, meanY, x, meanY + dy));
    }
    for (double y : {rect.minY, rect.maxY}) {
        const double dy = y - meanY;
        const double dx = std::clamp(-conic.b * dy / conic.a,
                                     rect.minX - meanX,
                                     rect.maxX - meanX);
        result = std::min(result, powerAt(conic, meanX, meanY, meanX + dx, y));
    }
    return result;
}

bool rasterHasContributingPixel(
    const Conic<double>& conic,
    double meanX,
    double meanY,
    const Rect<int>& rect,
    double powerLimit
) {
    for (int y = rect.minY; y <= rect.maxY; ++y) {
        for (int x = rect.minX; x <= rect.maxX; ++x) {
            const double power = powerAt(conic, meanX, meanY, x, y);
            if (power >= 0.0 && power <= powerLimit) {
                return true;
            }
        }
    }
    return false;
}

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

void testPowerLimit() {
    require(!culling::opacityPowerLimit(-20.0f).has_value(),
            "sub-threshold opacity must have empty support");
    const float expected = std::log((1.0f / (1.0f + std::exp(1.0f))) * 255.0f);
    require(std::abs(*culling::opacityPowerLimit(-1.0f) - expected) < 1e-6f,
            "low opacity must use log(opacity * 255)");
    require(*culling::opacityPowerLimit(20.0f) > 5.5f,
            "support must preserve every contribution accepted by the rasterizer");
}

void testThreeSigmaCapIsNotRasterExact() {
    // Projection rounds its three-sigma pixel AABB outward. That rounding can
    // admit an integer pixel whose power is above 4.5 but whose alpha still
    // clears the rasterizer's 1/255 threshold. Capping at 4.5 therefore cannot
    // satisfy the no-false-negative contract against the current raster path.
    const float variance = std::pow(6.1f / 3.0f, 2.0f);
    const Conic<float> conic {1.0f / variance, 0.0f, 1.0f / variance};
    const Conic<double> conic64 {conic.a, conic.b, conic.c};
    const Rect<float> tile {16.0f, 0.0f, 31.0f, 15.0f};
    const Rect<int> pixels {16, 0, 31, 15};
    const float meanX = 9.5f;
    const float meanY = 8.0f;
    const float uncapped = *culling::opacityPowerLimit(20.0f);

    require(rasterHasContributingPixel(conic64, meanX, meanY, pixels, uncapped),
            "counterexample must contribute under current raster semantics");
    require(!culling::ellipseIntersectsPixelTile(conic, meanX, meanY, tile, 4.5f),
            "counterexample must expose the three-sigma false negative");
    require(culling::ellipseIntersectsPixelTile(conic, meanX, meanY, tile, uncapped),
            "uncapped support must preserve the current raster contribution");
}

void testBoundariesAndTangency() {
    const Conic<float> isotropic {1.0f, 0.0f, 1.0f};
    const Rect<float> tile {16.0f, 16.0f, 31.0f, 31.0f};

    require(culling::ellipseIntersectsPixelTile(isotropic, 23.0f, 23.0f, tile, 0.0f),
            "mean inside tile must contribute");
    require(culling::ellipseIntersectsPixelTile(isotropic, 15.0f, 20.0f, tile, 0.5f),
            "exact edge tangency must contribute");
    require(!culling::ellipseIntersectsPixelTile(isotropic, 14.99f, 20.0f, tile, 0.5f),
            "separated ellipse must be rejected");

    const Conic<float> correlated {2.0f, 0.9f, 1.0f};
    const double expected = oracleMinimumPower(
        Conic<double> {2.0, 0.9, 1.0}, 11.0, 12.0,
        Rect<double> {16.0, 16.0, 31.0, 31.0});
    require(culling::ellipseIntersectsPixelTile(correlated, 11.0f, 12.0f, tile,
                                                static_cast<float>(expected)),
            "correlated tangent ellipse must not be rejected");
}

void testSubpixelOffscreenAndInvalidInputs() {
    const Conic<float> conic {0.75f, -0.2f, 1.25f};
    require(culling::ellipseIntersectsPixelTile(
                conic, 0.25f, 0.25f, Rect<float> {0.0f, 0.0f, 15.0f, 15.0f}, 0.01f),
            "subpixel mean in the first tile must contribute");
    require(!culling::ellipseIntersectsPixelTile(
                conic, -100.0f, -100.0f, Rect<float> {0.0f, 0.0f, 15.0f, 15.0f}, 4.5f),
            "far offscreen support must be rejected");

    require(culling::ellipseIntersectsPixelTile(
                Conic<float> {0.0f, 0.0f, 0.0f}, 20.0f, 20.0f,
                Rect<float> {16.0f, 16.0f, 31.0f, 31.0f}, 4.5f),
            "degenerate conics must conservatively survive");
    require(culling::ellipseIntersectsPixelTile(
                Conic<float> {NAN, 0.0f, 1.0f}, 20.0f, 20.0f,
                Rect<float> {16.0f, 16.0f, 31.0f, 31.0f}, 4.5f),
            "non-finite conics must conservatively survive");
}

void testRandomProperties() {
    std::mt19937 rng(0x5A17u);
    std::uniform_real_distribution<float> center(-48.0f, 176.0f);
    std::uniform_real_distribution<float> angle(-3.14159265f, 3.14159265f);
    std::uniform_real_distribution<float> logEigen(-4.0f, 2.0f);
    std::uniform_real_distribution<float> rawOpacity(-5.4f, 8.0f);
    std::uniform_int_distribution<int> tileIndex(0, 7);

    std::uint64_t oracleIntersections = 0;
    std::uint64_t candidateIntersections = 0;
    std::uint64_t rasterFalseNegatives = 0;

    for (int sample = 0; sample < 200000; ++sample) {
        const float theta = angle(rng);
        const float cs = std::cos(theta);
        const float sn = std::sin(theta);
        const float e0 = std::exp(logEigen(rng));
        const float e1 = std::exp(logEigen(rng));
        const float a = cs * cs * e0 + sn * sn * e1;
        const float b = cs * sn * (e0 - e1);
        const float c = sn * sn * e0 + cs * cs * e1;
        const Conic<float> conic {a, b, c};
        const Conic<double> conic64 {a, b, c};
        const float meanX = center(rng);
        const float meanY = center(rng);
        const int tx = tileIndex(rng);
        const int ty = tileIndex(rng);
        const Rect<float> rect {
            static_cast<float>(tx * 16), static_cast<float>(ty * 16),
            static_cast<float>(tx * 16 + 15), static_cast<float>(ty * 16 + 15)};
        const Rect<int> intRect {tx * 16, ty * 16, tx * 16 + 15, ty * 16 + 15};
        const auto limit = culling::opacityPowerLimit(rawOpacity(rng));
        if (!limit.has_value()) {
            continue;
        }

        const double oraclePower = oracleMinimumPower(
            conic64, meanX, meanY,
            Rect<double> {rect.minX, rect.minY, rect.maxX, rect.maxY});
        const bool oracle = oraclePower <= static_cast<double>(*limit);
        const bool candidate = culling::ellipseIntersectsPixelTile(
            conic, meanX, meanY, rect, *limit);
        oracleIntersections += oracle;
        candidateIntersections += candidate;
        require(!oracle || candidate,
                "float predicate produced a continuous-ellipse false negative at sample " +
                    std::to_string(sample));

        const bool raster = rasterHasContributingPixel(
            conic64, meanX, meanY, intRect, *limit);
        rasterFalseNegatives += raster && !candidate;
    }

    require(rasterFalseNegatives == 0, "predicate dropped an integer raster contribution");
    require(candidateIntersections <= oracleIntersections + 32,
            "numeric guard admitted too many false positives");
}

void testRowSpanProperties() {
    std::mt19937 rng(0xACC0711Eu);
    std::uniform_real_distribution<float> center(-48.0f, 176.0f);
    std::uniform_real_distribution<float> angle(-3.14159265f, 3.14159265f);
    std::uniform_real_distribution<float> logEigen(-4.0f, 2.0f);
    std::uniform_real_distribution<float> powerLimit(0.0f, 5.55f);
    std::uniform_int_distribution<int> rowIndex(0, 7);

    std::uint64_t exactTiles = 0;
    std::uint64_t spanTiles = 0;
    for (int sample = 0; sample < 200000; ++sample) {
        const float theta = angle(rng);
        const float cs = std::cos(theta);
        const float sn = std::sin(theta);
        const float e0 = std::exp(logEigen(rng));
        const float e1 = std::exp(logEigen(rng));
        const Conic<float> conic {
            cs * cs * e0 + sn * sn * e1,
            cs * sn * (e0 - e1),
            sn * sn * e0 + cs * cs * e1
        };
        const float meanX = center(rng);
        const float meanY = center(rng);
        const int row = rowIndex(rng);
        const float limit = powerLimit(rng);
        const auto span = culling::ellipseTileRowSpan(
            conic, meanX, meanY, row, 128, 128, limit, 0, 8
        );

        for (int column = 0; column < 8; ++column) {
            const bool exact = culling::ellipseIntersectsPixelTile(
                conic, meanX, meanY,
                Rect<float> {
                    static_cast<float>(column * 16),
                    static_cast<float>(row * 16),
                    static_cast<float>(column * 16 + 15),
                    static_cast<float>(row * 16 + 15)
                },
                limit
            );
            const bool included = span.has_value() &&
                column >= span->begin && column < span->end;
            exactTiles += exact;
            spanTiles += included;
            require(!exact || included,
                    "row span dropped an exact tile at sample " +
                        std::to_string(sample));
        }
    }
    require(spanTiles <= exactTiles * 1.08 + 64,
            "row span admitted excessive false positives");
}

} // namespace

int main() {
    try {
        testPowerLimit();
        testThreeSigmaCapIsNotRasterExact();
        testBoundariesAndTangency();
        testSubpixelOffscreenAndInvalidInputs();
        testRandomProperties();
        testRowSpanProperties();
        std::cout << "tile_culling_tests: PASS\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "tile_culling_tests: FAIL: " << error.what() << '\n';
        return 1;
    }
}
