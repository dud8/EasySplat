#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace culling {

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

static_assert(sizeof(GPUCase) == 10 * sizeof(float));

struct GPURowCase {
    float a;
    float b;
    float c;
    float meanX;
    float meanY;
    float powerLimit;
    std::uint32_t tileRow;
    std::uint32_t imageWidth;
    std::uint32_t imageHeight;
    std::uint32_t broadBegin;
    std::uint32_t broadEnd;
};

struct GPURowResult {
    std::uint32_t included;
    std::uint32_t begin;
    std::uint32_t end;
};

static_assert(sizeof(GPURowCase) == 44);
static_assert(sizeof(GPURowResult) == 12);

std::vector<std::uint32_t> evaluateOnGPU(
    const std::vector<GPUCase>& cases,
    const std::string& metallibPath
);

std::vector<GPURowResult> evaluateRowSpansOnGPU(
    const std::vector<GPURowCase>& cases,
    const std::string& metallibPath
);

} // namespace culling
