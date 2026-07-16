#include <metal_stdlib>

using namespace metal;

struct GPUCase {
    float a;
    float b;
    float c;
    float meanX;
    float meanY;
    float minX;
    float minY;
    float maxX;
    float maxY;
    float powerLimit;
};

struct GPURowCase {
    float a;
    float b;
    float c;
    float meanX;
    float meanY;
    float powerLimit;
    uint tileRow;
    uint imageWidth;
    uint imageHeight;
    uint broadBegin;
    uint broadEnd;
};

struct GPURowResult {
    uint included;
    uint begin;
    uint end;
};

inline float gaussianPower(float3 conic, float dx, float dy) {
    return fma(0.5f, fma(conic.x, dx * dx, conic.z * dy * dy),
               conic.y * dx * dy);
}

inline bool ellipseIntersectsPixelTile(
    float3 conic,
    float2 mean,
    float4 rect,
    float powerLimit
) {
    if (rect.x > rect.z || rect.y > rect.w || powerLimit < 0.0f) {
        return false;
    }
    const float determinant = fma(conic.x, conic.z, -conic.y * conic.y);
    if (!isfinite(conic.x) || !isfinite(conic.y) || !isfinite(conic.z) ||
        !isfinite(mean.x) || !isfinite(mean.y) || !isfinite(powerLimit) ||
        !(conic.x > 0.0f) || !(conic.z > 0.0f) || !(determinant > 0.0f)) {
        return true;
    }
    if (mean.x >= rect.x && mean.x <= rect.z &&
        mean.y >= rect.y && mean.y <= rect.w) {
        return true;
    }

    if (rect.x == rect.z || rect.y == rect.w) {
        return true;
    }
    const float xMinDifference = rect.x - mean.x;
    const float xLeft = float(xMinDifference >= 0.0f);
    const float outsideX = xLeft + float(mean.x > rect.z);
    const float yMinDifference = rect.y - mean.y;
    const float yAbove = float(yMinDifference >= 0.0f);
    const float outsideY = yAbove + float(mean.y > rect.w);
    const float2 corner = {
        mix(rect.z, rect.x, xLeft),
        mix(rect.w, rect.y, yAbove)
    };
    const float2 difference = mean - corner;
    const float2 direction = {
        copysign(rect.z - rect.x, xMinDifference),
        copysign(rect.w - rect.y, yMinDifference)
    };
    const float2 t = {
        outsideY * clamp(
            (direction.x * conic.x * difference.x +
             direction.x * conic.y * difference.y) /
                (direction.x * conic.x * direction.x),
            0.0f, 1.0f),
        outsideX * clamp(
            (direction.y * conic.y * difference.x +
             direction.y * conic.z * difference.y) /
                (direction.y * conic.z * direction.y),
            0.0f, 1.0f)
    };
    const float2 delta = mean - (corner + t * direction);
    const float minimumPower = gaussianPower(conic, delta.x, delta.y);

    const float roundingGuard = 32.0f * FLT_EPSILON *
        (1.0f + abs(powerLimit) + abs(minimumPower));
    return minimumPower <= powerLimit + roundingGuard;
}

inline bool ellipseTileRowSpan(
    float3 conic,
    float2 mean,
    uint tileRow,
    uint2 imageSize,
    float powerLimit,
    uint broadBegin,
    uint broadEnd,
    thread uint& spanBegin,
    thread uint& spanEnd
) {
    if (imageSize.x == 0 || imageSize.y == 0 || broadBegin >= broadEnd ||
        powerLimit < 0.0f) {
        return false;
    }
    const float determinant = fma(conic.x, conic.z, -conic.y * conic.y);
    const float determinantScale = max(
        max(abs(conic.x * conic.z), conic.y * conic.y),
        FLT_MIN
    );
    const float determinantError =
        8.0f * FLT_EPSILON * determinantScale;
    const float determinantLower = nextafter(
        determinant - determinantError,
        -INFINITY
    );
    if (!isfinite(conic.x) || !isfinite(conic.y) || !isfinite(conic.z) ||
        !isfinite(mean.x) || !isfinite(mean.y) || !isfinite(powerLimit) ||
        !isfinite(determinantScale) || !(conic.x > 0.0f) ||
        !(conic.z > 0.0f) || !(determinantLower > 0.0f)) {
        spanBegin = broadBegin;
        spanEnd = broadEnd;
        return true;
    }

    const uint pixelMinY = tileRow * 16;
    if (pixelMinY >= imageSize.y) {
        return false;
    }
    const uint pixelMaxY = min(pixelMinY + 15, imageSize.y - 1);
    const float supportGuard = 128.0f * FLT_EPSILON *
        (1.0f + 2.0f * abs(powerLimit));
    const float q = 2.0f * (powerLimit + supportGuard);
    const float yRadius = sqrt(max(0.0f, q * conic.x / determinantLower));
    if (!isfinite(yRadius)) {
        spanBegin = broadBegin;
        spanEnd = broadEnd;
        return true;
    }
    const float feasibleMinY = max(float(pixelMinY) - mean.y, -yRadius);
    const float feasibleMaxY = min(float(pixelMaxY) - mean.y, yRadius);
    if (feasibleMinY > feasibleMaxY) {
        return false;
    }

    const float lowerRadicand = max(
        0.0f, fma(-determinantLower, feasibleMinY * feasibleMinY, conic.x * q));
    const float upperRadicand = max(
        0.0f, fma(-determinantLower, feasibleMaxY * feasibleMaxY, conic.x * q));
    const float lowerCenter = -conic.y * feasibleMinY / conic.x;
    const float upperCenter = -conic.y * feasibleMaxY / conic.x;
    const float lowerHalfWidth = sqrt(lowerRadicand) / conic.x;
    const float upperHalfWidth = sqrt(upperRadicand) / conic.x;
    float minimumX = min(lowerCenter - lowerHalfWidth,
                         upperCenter - upperHalfWidth);
    float maximumX = max(lowerCenter + lowerHalfWidth,
                         upperCenter + upperHalfWidth);

    const float xRadius = sqrt(max(0.0f, q * conic.z / determinantLower));
    if (!isfinite(lowerCenter) || !isfinite(upperCenter) ||
        !isfinite(lowerHalfWidth) || !isfinite(upperHalfWidth) ||
        !isfinite(xRadius)) {
        spanBegin = broadBegin;
        spanEnd = broadEnd;
        return true;
    }
    const float minimumCriticalY = conic.y * xRadius / conic.z;
    if (minimumCriticalY >= feasibleMinY && minimumCriticalY <= feasibleMaxY) {
        minimumX = -xRadius;
    }
    const float maximumCriticalY = -conic.y * xRadius / conic.z;
    if (maximumCriticalY >= feasibleMinY && maximumCriticalY <= feasibleMaxY) {
        maximumX = xRadius;
    }

    minimumX += mean.x;
    maximumX += mean.x;
    const float pixelGuard = 64.0f * FLT_EPSILON *
        (1.0f + abs(mean.x) + abs(minimumX) + abs(maximumX));
    if (!isfinite(minimumX) || !isfinite(maximumX) ||
        !isfinite(pixelGuard)) {
        spanBegin = broadBegin;
        spanEnd = broadEnd;
        return true;
    }
    const float lowerTile = floor((minimumX - pixelGuard) / 16.0f);
    const float upperTile = floor((maximumX + pixelGuard) / 16.0f) + 1.0f;
    if (!isfinite(lowerTile) || !isfinite(upperTile)) {
        spanBegin = broadBegin;
        spanEnd = broadEnd;
        return true;
    }
    spanBegin = uint(clamp(lowerTile, float(broadBegin), float(broadEnd)));
    spanEnd = uint(clamp(upperTile, float(broadBegin), float(broadEnd)));
    return spanBegin < spanEnd;
}

kernel void evaluate_tile_culling(
    constant GPUCase* cases [[buffer(0)]],
    device uint* result [[buffer(1)]],
    constant uint& count [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= count) {
        return;
    }
    const GPUCase item = cases[index];
    result[index] = ellipseIntersectsPixelTile(
        float3(item.a, item.b, item.c),
        float2(item.meanX, item.meanY),
        float4(item.minX, item.minY, item.maxX, item.maxY),
        item.powerLimit
    );
}

kernel void evaluate_tile_row_spans(
    constant GPURowCase* cases [[buffer(0)]],
    device GPURowResult* result [[buffer(1)]],
    constant uint& count [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= count) {
        return;
    }
    const GPURowCase item = cases[index];
    uint begin = 0;
    uint end = 0;
    const bool included = ellipseTileRowSpan(
        float3(item.a, item.b, item.c),
        float2(item.meanX, item.meanY),
        item.tileRow,
        uint2(item.imageWidth, item.imageHeight),
        item.powerLimit,
        item.broadBegin,
        item.broadEnd,
        begin,
        end
    );
    result[index] = {uint(included), begin, end};
}
