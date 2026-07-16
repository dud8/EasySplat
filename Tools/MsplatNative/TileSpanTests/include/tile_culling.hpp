#pragma once

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>

namespace culling {

template <typename T>
struct Conic {
    T a;
    T b;
    T c;
};

template <typename T>
struct Rect {
    T minX;
    T minY;
    T maxX;
    T maxY;
};

struct TileSpan {
    int begin;
    int end;
};

inline std::optional<float> opacityPowerLimit(float rawOpacity) {
    if (!std::isfinite(rawOpacity)) {
        return std::nullopt;
    }
    const float opacity = rawOpacity >= 0.0f
        ? 1.0f / (1.0f + std::exp(-rawOpacity))
        : std::exp(rawOpacity) / (1.0f + std::exp(rawOpacity));
    const float scaled = opacity * 255.0f;
    if (!(scaled >= 1.0f)) {
        return std::nullopt;
    }
    return std::log(scaled);
}

inline float powerAt(const Conic<float>& conic, float dx, float dy) {
    return std::fma(
        0.5f,
        std::fma(conic.a, dx * dx, conic.c * dy * dy),
        conic.b * dx * dy
    );
}

inline bool ellipseIntersectsPixelTile(
    const Conic<float>& conic,
    float meanX,
    float meanY,
    const Rect<float>& rect,
    float powerLimit
) {
    if (rect.minX > rect.maxX || rect.minY > rect.maxY || powerLimit < 0.0f) {
        return false;
    }
    const float determinant = std::fma(conic.a, conic.c, -conic.b * conic.b);
    if (!std::isfinite(conic.a) || !std::isfinite(conic.b) ||
        !std::isfinite(conic.c) || !std::isfinite(meanX) ||
        !std::isfinite(meanY) || !std::isfinite(powerLimit) ||
        !(conic.a > 0.0f) || !(conic.c > 0.0f) || !(determinant > 0.0f)) {
        return true;
    }

    if (meanX >= rect.minX && meanX <= rect.maxX &&
        meanY >= rect.minY && meanY <= rect.maxY) {
        return true;
    }

    if (rect.minX == rect.maxX || rect.minY == rect.maxY) {
        return true;
    }
    const float xMinDifference = rect.minX - meanX;
    const float xLeft = xMinDifference >= 0.0f ? 1.0f : 0.0f;
    const float outsideX = xLeft + (meanX > rect.maxX ? 1.0f : 0.0f);
    const float yMinDifference = rect.minY - meanY;
    const float yAbove = yMinDifference >= 0.0f ? 1.0f : 0.0f;
    const float outsideY = yAbove + (meanY > rect.maxY ? 1.0f : 0.0f);

    const float cornerX = std::lerp(rect.maxX, rect.minX, xLeft);
    const float cornerY = std::lerp(rect.maxY, rect.minY, yAbove);
    const float differenceX = meanX - cornerX;
    const float differenceY = meanY - cornerY;
    const float directionX = std::copysign(rect.maxX - rect.minX, xMinDifference);
    const float directionY = std::copysign(rect.maxY - rect.minY, yMinDifference);
    const float tX = outsideY * std::clamp(
        (directionX * conic.a * differenceX +
         directionX * conic.b * differenceY) /
            (directionX * conic.a * directionX),
        0.0f, 1.0f
    );
    const float tY = outsideX * std::clamp(
        (directionY * conic.b * differenceX +
         directionY * conic.c * differenceY) /
            (directionY * conic.c * directionY),
        0.0f, 1.0f
    );
    const float deltaX = meanX - (cornerX + tX * directionX);
    const float deltaY = meanY - (cornerY + tY * directionY);
    const float minimumPower = powerAt(conic, deltaX, deltaY);

    const float roundingGuard = 32.0f * std::numeric_limits<float>::epsilon() *
        (1.0f + std::abs(powerLimit) + std::abs(minimumPower));
    return minimumPower <= powerLimit + roundingGuard;
}

inline std::optional<TileSpan> ellipseTileRowSpan(
    const Conic<float>& conic,
    float meanX,
    float meanY,
    int tileRow,
    int imageWidth,
    int imageHeight,
    float powerLimit,
    int broadBegin,
    int broadEnd
) {
    if (tileRow < 0 || imageWidth <= 0 || imageHeight <= 0 ||
        broadBegin >= broadEnd || powerLimit < 0.0f) {
        return std::nullopt;
    }

    const float determinant = std::fma(conic.a, conic.c, -conic.b * conic.b);
    if (!std::isfinite(conic.a) || !std::isfinite(conic.b) ||
        !std::isfinite(conic.c) || !std::isfinite(meanX) ||
        !std::isfinite(meanY) || !std::isfinite(powerLimit) ||
        !(conic.a > 0.0f) || !(conic.c > 0.0f) || !(determinant > 0.0f)) {
        return TileSpan {broadBegin, broadEnd};
    }

    const int pixelMinY = tileRow * 16;
    if (pixelMinY >= imageHeight) {
        return std::nullopt;
    }
    const int pixelMaxY = std::min(pixelMinY + 15, imageHeight - 1);
    const float supportGuard = 128.0f * std::numeric_limits<float>::epsilon() *
        (1.0f + 2.0f * std::abs(powerLimit));
    const float q = 2.0f * (powerLimit + supportGuard);
    const float yRadius = std::sqrt(std::max(0.0f, q * conic.a / determinant));
    const float feasibleMinY = std::max(static_cast<float>(pixelMinY) - meanY,
                                        -yRadius);
    const float feasibleMaxY = std::min(static_cast<float>(pixelMaxY) - meanY,
                                        yRadius);
    if (feasibleMinY > feasibleMaxY) {
        return std::nullopt;
    }

    const auto xRoots = [&](float dy) {
        const float radicand = std::max(
            0.0f, std::fma(-determinant, dy * dy, conic.a * q));
        const float center = -conic.b * dy / conic.a;
        const float halfWidth = std::sqrt(radicand) / conic.a;
        return std::pair<float, float> {center - halfWidth, center + halfWidth};
    };
    const auto lowerRoots = xRoots(feasibleMinY);
    const auto upperRoots = xRoots(feasibleMaxY);
    float minimumX = std::min(lowerRoots.first, upperRoots.first);
    float maximumX = std::max(lowerRoots.second, upperRoots.second);

    const float xRadius = std::sqrt(std::max(0.0f, q * conic.c / determinant));
    const float minimumCriticalY = conic.b * xRadius / conic.c;
    if (minimumCriticalY >= feasibleMinY && minimumCriticalY <= feasibleMaxY) {
        minimumX = -xRadius;
    }
    const float maximumCriticalY = -conic.b * xRadius / conic.c;
    if (maximumCriticalY >= feasibleMinY && maximumCriticalY <= feasibleMaxY) {
        maximumX = xRadius;
    }

    minimumX += meanX;
    maximumX += meanX;
    const float pixelGuard = 64.0f * std::numeric_limits<float>::epsilon() *
        (1.0f + std::abs(meanX) + std::abs(minimumX) + std::abs(maximumX));
    int spanBegin = static_cast<int>(std::floor((minimumX - pixelGuard) / 16.0f));
    int spanEnd = static_cast<int>(std::floor((maximumX + pixelGuard) / 16.0f)) + 1;
    spanBegin = std::clamp(spanBegin, broadBegin, broadEnd);
    spanEnd = std::clamp(spanEnd, broadBegin, broadEnd);
    if (spanBegin >= spanEnd) {
        return std::nullopt;
    }
    return TileSpan {spanBegin, spanEnd};
}

} // namespace culling
