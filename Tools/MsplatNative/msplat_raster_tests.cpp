// Modified by the EasySplat project in 2026 from msplat 1.1.3.
// Licensed under Apache-2.0; see Tools/MsplatNative/NOTICE.md.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include <unistd.h>

#include "bindings.h"
#include "loaders.hpp"
#include "model.hpp"

void msplat_copy_last_raster_reference_debug(
    float *xys,
    float *depths,
    int *radii,
    float *aabb,
    float *conics,
    float *raw_colors,
    float *render_gradients,
    float *projected_position_gradients,
    float *raster_color_gradients,
    float *opacity_gradients,
    int point_count,
    int pixel_count
);
void msplat_exact_prefix_sum_for_testing(
    const std::int32_t *input,
    std::uint32_t count,
    std::uint64_t *output
);
void msplat_quaternion_vjp_for_testing(
    const float *quaternion,
    const float *rotationGradient,
    float *quaternionGradient
);

namespace {

constexpr std::uint64_t memoryBudgetBytes = 512ULL * 1024ULL * 1024ULL;
constexpr std::uint64_t benchmarkMemoryBudgetBytes = 8ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr float relativeTolerance = 2.0e-3f;
constexpr float absoluteTolerance = 2.0e-4f;
// A near-threshold reciprocal with enough headroom for projected attenuation.
// At the splat center, (1 - opacity)^2050 stays above the 1e-4 early stop.
constexpr float overflowReferenceOpacity = 1.0f / 240.0f;
constexpr int stageTimingIterations = 512;
constexpr int geometryAdamShDegreeInterval = 4;

void quaternionRotation(
    const double *quaternion,
    double *rotation
) {
    const double norm = std::sqrt(
        quaternion[0] * quaternion[0] +
        quaternion[1] * quaternion[1] +
        quaternion[2] * quaternion[2] +
        quaternion[3] * quaternion[3]
    );
    if (!std::isfinite(norm) || norm <= 0) {
        throw std::runtime_error("quaternion VJP oracle received an invalid quaternion");
    }
    const double w = quaternion[0] / norm;
    const double x = quaternion[1] / norm;
    const double y = quaternion[2] / norm;
    const double z = quaternion[3] / norm;
    const double values[] = {
        1.0 - 2.0 * (y * y + z * z),
        2.0 * (x * y + w * z),
        2.0 * (x * z - w * y),
        2.0 * (x * y - w * z),
        1.0 - 2.0 * (x * x + z * z),
        2.0 * (y * z + w * x),
        2.0 * (x * z + w * y),
        2.0 * (y * z - w * x),
        1.0 - 2.0 * (x * x + y * y),
    };
    std::copy(std::begin(values), std::end(values), rotation);
}

double quaternionRotationObjective(
    const double *quaternion,
    const float *rotationGradient
) {
    double rotation[9];
    quaternionRotation(quaternion, rotation);
    double result = 0;
    for (int index = 0; index < 9; ++index) {
        result += rotation[index] * static_cast<double>(rotationGradient[index]);
    }
    return result;
}

void verifyQuaternionVJP() {
    const float quaternion[] = {2.0f, -0.7f, 1.3f, 0.4f};
    const float rotationGradient[] = {
        0.4f, -0.2f, 0.7f,
        -0.6f, 0.3f, 0.1f,
        0.8f, -0.5f, 0.9f,
    };
    float gradient[4];
    msplat_quaternion_vjp_for_testing(quaternion, rotationGradient, gradient);

    double radialDerivative = 0;
    for (int index = 0; index < 4; ++index) {
        if (!std::isfinite(gradient[index])) {
            throw std::runtime_error("quaternion VJP contains a non-finite value");
        }
        radialDerivative += static_cast<double>(quaternion[index]) * gradient[index];
    }
    if (std::abs(radialDerivative) > 2.0e-4) {
        throw std::runtime_error(
            "quaternion VJP is not tangent to the scale-invariant rotation: " +
            std::to_string(radialDerivative)
        );
    }

    float scaledQuaternion[4];
    float scaledGradient[4];
    for (int index = 0; index < 4; ++index) {
        scaledQuaternion[index] = quaternion[index] * 2.0f;
    }
    msplat_quaternion_vjp_for_testing(
        scaledQuaternion,
        rotationGradient,
        scaledGradient
    );
    for (int index = 0; index < 4; ++index) {
        const double expected = static_cast<double>(gradient[index]) * 0.5;
        if (!std::isfinite(scaledGradient[index]) ||
            std::abs(static_cast<double>(scaledGradient[index]) - expected) > 2.0e-4) {
            throw std::runtime_error(
                "quaternion VJP does not scale inversely with quaternion norm"
            );
        }
    }

    constexpr double epsilon = 1.0e-4;
    for (int component = 0; component < 4; ++component) {
        double positive[4];
        double negative[4];
        for (int index = 0; index < 4; ++index) {
            positive[index] = quaternion[index];
            negative[index] = quaternion[index];
        }
        positive[component] += epsilon;
        negative[component] -= epsilon;
        const double finiteDifference = (
            quaternionRotationObjective(positive, rotationGradient) -
            quaternionRotationObjective(negative, rotationGradient)
        ) / (2.0 * epsilon);
        const double actual = gradient[component];
        const double tolerance = 3.0e-3 * std::max(1.0, std::abs(finiteDifference));
        if (!std::isfinite(finiteDifference) || std::abs(actual - finiteDifference) > tolerance) {
            throw std::runtime_error(
                "quaternion VJP differs from finite differences at component " +
                std::to_string(component) + ": actual=" + std::to_string(actual) +
                " expected=" + std::to_string(finiteDifference)
            );
        }
    }

    cleanup_msplat_metal();
    std::cout << "quaternion_vjp passed\n";
}

void verifyExactRadixPassPlanning() {
    struct PassCase {
        std::uint32_t tileCount;
        std::uint32_t expectedPasses;
    };
    const PassCase cases[] = {
        {1, 4},
        {2, 6},
        {256, 6},
        {257, 6},
        {65'536, 6},
        {65'537, 8},
        {16'777'216, 8},
        {16'777'217, 8},
        {std::numeric_limits<std::uint32_t>::max(), 8},
    };
    for (const auto &testCase : cases) {
        const std::uint32_t actual =
            msplat_exact_radix_pass_count_for_testing(testCase.tileCount);
        if (actual != testCase.expectedPasses) {
            throw std::runtime_error(
                "exact radix pass count for " + std::to_string(testCase.tileCount) +
                " tiles expected " + std::to_string(testCase.expectedPasses) +
                ", got " + std::to_string(actual)
            );
        }
    }

    bool rejectedEmptyGrid = false;
    try {
        (void)msplat_exact_radix_pass_count_for_testing(0);
    } catch (const std::runtime_error &) {
        rejectedEmptyGrid = true;
    }
    if (!rejectedEmptyGrid) {
        throw std::runtime_error("exact radix planner accepted an empty tile grid");
    }
}

void verifyExactPrefixCase(std::uint32_t count) {
    constexpr std::size_t canaryCount = 16;
    constexpr std::uint64_t canary = 0xd15ea5e5c0decafeULL;
    std::vector<std::int32_t> input(count);
    for (std::uint32_t index = 0; index < count; ++index) {
        input[index] = static_cast<std::int32_t>((index * 17u + index / 13u) % 11u) - 3;
    }
    const std::vector<std::int32_t> original = input;
    std::vector<std::uint64_t> expected(count);
    std::uint64_t running = 0;
    for (std::uint32_t index = 0; index < count; ++index) {
        running += static_cast<std::uint64_t>(std::max(input[index], 0));
        expected[index] = running;
    }
    std::vector<std::uint64_t> actual(
        static_cast<std::size_t>(count) + canaryCount,
        canary
    );
    msplat_exact_prefix_sum_for_testing(input.data(), count, actual.data());
    for (std::uint32_t index = 0; index < count; ++index) {
        if (actual[index] != expected[index]) {
            throw std::runtime_error(
                "exact prefix count " + std::to_string(count) +
                " differs at index " + std::to_string(index) +
                ": expected=" + std::to_string(expected[index]) +
                " actual=" + std::to_string(actual[index])
            );
        }
    }
    for (std::size_t index = count; index < actual.size(); ++index) {
        if (actual[index] != canary) {
            throw std::runtime_error(
                "exact prefix count " + std::to_string(count) +
                " wrote beyond its logical output"
            );
        }
    }
    if (input != original) {
        throw std::runtime_error(
            "exact prefix count " + std::to_string(count) + " modified its input"
        );
    }
    std::cout << "exact_prefix_oracle count=" << count << " final=" << running << '\n';
}

void verifyExactPrefixOracle() {
    for (const std::uint32_t count : {1023u, 1024u, 1025u, 2048u, 2049u}) {
        verifyExactPrefixCase(count);
    }
}

struct RadixEntry {
    std::uint64_t key;
    std::uint32_t value;
};

constexpr std::size_t radixCanaryCount = 16;
constexpr std::uint64_t radixKeyCanary = 0xd15ea5e5c0decafeULL;
constexpr std::uint32_t radixValueCanary = 0xf00dcafeU;

std::uint32_t radixValue(std::size_t index) {
    return 0x9e3779b9U ^ static_cast<std::uint32_t>(index * 2'654'435'761ULL);
}

std::string radixMismatch(
    const std::string &label,
    int repetition,
    std::size_t index,
    const RadixEntry &expected,
    std::uint64_t actualKey,
    std::uint32_t actualValue
) {
    std::ostringstream message;
    message << label << " repetition " << repetition
            << " differs from stable CPU order at index " << index
            << std::hex
            << ": expected key=0x" << expected.key
            << " value=0x" << expected.value
            << ", got key=0x" << actualKey
            << " value=0x" << actualValue;
    return message.str();
}

void verifyExactRadixCase(
    const std::string &label,
    const std::vector<std::uint64_t> &keys,
    std::uint32_t capacity,
    std::uint32_t tileCount,
    int repetitions,
    bool verifyTileDepthOrder = false
) {
    if (keys.size() > capacity) {
        throw std::runtime_error(label + " test data exceeds its declared capacity");
    }

    const std::uint32_t count = static_cast<std::uint32_t>(keys.size());
    const std::size_t allocationCount =
        static_cast<std::size_t>(capacity) + radixCanaryCount;
    std::vector<std::uint64_t> inputKeys(allocationCount, radixKeyCanary);
    std::vector<std::uint32_t> inputValues(allocationCount, radixValueCanary);
    std::vector<RadixEntry> expected;
    expected.reserve(keys.size());
    for (std::size_t index = 0; index < keys.size(); ++index) {
        const std::uint32_t value = radixValue(index);
        inputKeys[index] = keys[index];
        inputValues[index] = value;
        expected.push_back({keys[index], value});
    }
    std::stable_sort(
        expected.begin(),
        expected.end(),
        [](const RadixEntry &left, const RadixEntry &right) {
            return left.key < right.key;
        }
    );
    const std::vector<std::uint64_t> originalKeys = inputKeys;
    const std::vector<std::uint32_t> originalValues = inputValues;

    for (int repetition = 0; repetition < repetitions; ++repetition) {
        std::vector<std::uint64_t> actualKeys(allocationCount, radixKeyCanary);
        std::vector<std::uint32_t> actualValues(allocationCount, radixValueCanary);
        msplat_exact_radix_sort_for_testing(
            inputKeys.data(),
            inputValues.data(),
            count,
            capacity,
            tileCount,
            actualKeys.data(),
            actualValues.data()
        );

        for (std::size_t index = 0; index < expected.size(); ++index) {
            if (actualKeys[index] != expected[index].key ||
                actualValues[index] != expected[index].value) {
                throw std::runtime_error(
                    radixMismatch(
                        label,
                        repetition + 1,
                        index,
                        expected[index],
                        actualKeys[index],
                        actualValues[index]
                    )
                );
            }
        }
        if (verifyTileDepthOrder) {
            for (std::size_t index = 1; index < count; ++index) {
                const std::uint32_t previousTile =
                    static_cast<std::uint32_t>(actualKeys[index - 1] >> 32);
                const std::uint32_t tile =
                    static_cast<std::uint32_t>(actualKeys[index] >> 32);
                const std::uint32_t previousDepthBits =
                    static_cast<std::uint32_t>(actualKeys[index - 1]);
                const std::uint32_t depthBits =
                    static_cast<std::uint32_t>(actualKeys[index]);
                float previousDepth = 0;
                float depth = 0;
                std::memcpy(&previousDepth, &previousDepthBits, sizeof(previousDepth));
                std::memcpy(&depth, &depthBits, sizeof(depth));
                if (tile < previousTile ||
                    (tile == previousTile && depth < previousDepth)) {
                    throw std::runtime_error(
                        label + " is not numerically ordered by tile and positive depth"
                    );
                }
            }
        }
        for (std::size_t index = count; index < allocationCount; ++index) {
            if (actualKeys[index] != radixKeyCanary ||
                actualValues[index] != radixValueCanary) {
                throw std::runtime_error(
                    label + " wrote beyond its logical output at index " +
                    std::to_string(index)
                );
            }
        }
        if (inputKeys != originalKeys || inputValues != originalValues) {
            throw std::runtime_error(label + " modified its input buffers");
        }
    }
    std::cout << "radix_oracle_case=" << label
              << " count=" << count
              << " capacity=" << capacity
              << " repetitions=" << repetitions << '\n';
}

std::uint64_t nextRadixRandom(std::uint64_t &state) {
    state ^= state >> 12;
    state ^= state << 25;
    state ^= state >> 27;
    return state * 2'685'821'657'736'338'717ULL;
}

void deterministicShuffle(std::vector<std::uint64_t> &values, std::uint64_t seed) {
    for (std::size_t index = values.size(); index > 1; --index) {
        const std::size_t destination = static_cast<std::size_t>(
            nextRadixRandom(seed) % index
        );
        std::swap(values[index - 1], values[destination]);
    }
}

std::uint32_t positiveFloatBits(float value) {
    std::uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

void verifyExactRadixOracle() {
    msplat_exact_radix_sort_for_testing(nullptr, nullptr, 0, 0, 1, nullptr, nullptr);
    verifyExactRadixCase("empty", {}, 0, 1, 2);
    verifyExactRadixCase("single", {0x12345678ULL}, 1, 1, 2);

    verifyExactRadixCase(
        "equal_513",
        std::vector<std::uint64_t>(513, 0x01020304ULL),
        1024,
        1,
        2
    );

    std::vector<std::uint64_t> sameLowDigit;
    sameLowDigit.reserve(256);
    for (std::uint64_t index = 0; index < 256; ++index) {
        sameLowDigit.push_back(((index * 193) % 256) << 8 | 0x5aULL);
    }
    verifyExactRadixCase("same_low_digit_256", sameLowDigit, 256, 1, 2);

    std::vector<std::uint64_t> everyDigit;
    everyDigit.reserve(256);
    for (std::uint64_t digit = 0; digit < 256; ++digit) {
        everyDigit.push_back(digit);
    }
    deterministicShuffle(everyDigit, 0x256d1617ULL);
    verifyExactRadixCase("all_low_digits_shuffled", everyDigit, 256, 1, 2);

    std::vector<std::uint64_t> crossSimdDuplicates;
    crossSimdDuplicates.reserve(512);
    for (std::uint64_t index = 0; index < 512; ++index) {
        const std::uint64_t key = ((index * 37 + index / 32) % 23) << 8 |
            ((index * 11) % 7);
        crossSimdDuplicates.push_back(key);
    }
    verifyExactRadixCase(
        "cross_simd_duplicates_512", crossSimdDuplicates, 512, 1, 2
    );

    std::vector<std::uint64_t> partialGroup;
    partialGroup.reserve(239);
    for (std::uint64_t index = 0; index < 239; ++index) {
        partialGroup.push_back((((index * 73) % 67) + (index % 5) * 256) << 8);
    }
    verifyExactRadixCase(
        "partial_group_digit_zero_239", partialGroup, 2048, 1, 2
    );

    for (std::uint32_t count : {31U, 32U, 33U, 255U, 256U, 257U, 511U, 512U, 513U}) {
        std::vector<std::uint64_t> boundary;
        boundary.reserve(count);
        std::uint64_t state = 0x424f554e44415259ULL ^ count;
        for (std::uint32_t index = 0; index < count; ++index) {
            const std::uint64_t random = nextRadixRandom(state);
            const std::uint64_t tile = random % 513;
            const std::uint64_t depth = (random >> 16) & 0xffffU;
            boundary.push_back(tile << 32 | depth);
        }
        verifyExactRadixCase(
            "boundary_" + std::to_string(count),
            boundary,
            count,
            513,
            2
        );
    }

    std::vector<std::uint64_t> realistic;
    realistic.reserve(4096);
    constexpr float depths[] = {
        0.01f, 0.5f, 0.5f, 1.0f, 3.25f, 10.0f, 10.0f, 250.0f,
    };
    for (std::uint32_t index = 0; index < 4096; ++index) {
        const std::uint32_t tile = (index * 193 + index / 17) % 258;
        const float depth = depths[(index * 5 + index / 11) % std::size(depths)];
        realistic.push_back(
            static_cast<std::uint64_t>(tile) << 32 | positiveFloatBits(depth)
        );
    }
    deterministicShuffle(realistic, 0x7265616c69737469ULL);
    verifyExactRadixCase(
        "realistic_tile_depth_ties", realistic, 8192, 258, 2, true
    );

    std::vector<std::uint64_t> eightPass {
        0ULL,
        1ULL << 63,
        std::numeric_limits<std::uint64_t>::max(),
        1ULL << 56,
        1ULL << 48,
        (1ULL << 48) | 0xffffffffULL,
        0x7fffffffffffffffULL,
        0xff00000000000000ULL,
        0x0102030405060708ULL,
        0x0102030405060708ULL,
    };
    deterministicShuffle(eightPass, 0x3862697470617373ULL);
    verifyExactRadixCase("eight_pass_high_bits", eightPass, 64, 65'537, 2);

    constexpr std::uint32_t stressCount = 1'048'579;
    constexpr std::uint32_t stressCapacity = 2'097'152;
    std::vector<std::uint64_t> stress;
    stress.reserve(stressCount);
    std::uint64_t state = 0x6d73706c61742d31ULL;
    for (std::uint32_t index = 0; index < stressCount; ++index) {
        std::uint64_t key = nextRadixRandom(state);
        if (index % 17 == 0) {
            key &= 0x0000fffffffff000ULL;
        }
        stress.push_back(key);
    }
    verifyExactRadixCase(
        "deterministic_stress_1048579",
        stress,
        stressCapacity,
        65'537,
        1
    );

    cleanup_msplat_metal();
    std::cout << "msplat exact radix oracle passed\n";
}

void requireRelativeNear(
    const std::string &label,
    double actual,
    double expected,
    double relativeTolerance
) {
    const double scale = std::max(std::abs(expected), 1.0);
    if (!std::isfinite(actual) || std::abs(actual - expected) > scale * relativeTolerance) {
        throw std::runtime_error(
            label + " expected " + std::to_string(expected) +
            ", got " + std::to_string(actual)
        );
    }
}

void verifyTimestampMath() {
    struct ConversionCase {
        std::uint64_t ticks;
        double frequencyHz;
        double expectedSeconds;
    };
    const ConversionCase cases[] = {
        {24'000'000ULL, 24'000'000.0, 1.0},
        {37'500'000ULL, 25'000'000.0, 1.5},
        {2'000'000'000ULL, 1'000'000'000.0, 2.0},
        {5'000'000'000ULL, 2'500'000'000.0, 2.0},
    };
    for (const auto &testCase : cases) {
        requireRelativeNear(
            "GPU tick conversion",
            msplat_gpu_ticks_to_seconds_for_testing(testCase.ticks, testCase.frequencyHz),
            testCase.expectedSeconds,
            1.0e-12
        );
    }
    for (double invalidFrequency : {
             0.0,
             -1.0,
             100.0,
             1.0e12,
             std::numeric_limits<double>::infinity(),
             std::numeric_limits<double>::quiet_NaN(),
         }) {
        if (std::isfinite(msplat_gpu_ticks_to_seconds_for_testing(1, invalidFrequency))) {
            throw std::runtime_error("invalid GPU frequency produced a finite duration");
        }
    }
    if (!msplat_stage_timing_sample_valid_for_testing(0.001, 1.0) ||
        !msplat_stage_timing_sample_valid_for_testing(1.05, 1.0) ||
        msplat_stage_timing_sample_valid_for_testing(1.051, 1.0) ||
        msplat_stage_timing_sample_valid_for_testing(0.0, 1.0) ||
        msplat_stage_timing_sample_valid_for_testing(1.0, 0.0)) {
        throw std::runtime_error("GPU stage timing sample bounds are invalid");
    }
    if (!msplat_stage_timing_aggregate_coherent_for_testing(0.25, 1.0) ||
        !msplat_stage_timing_aggregate_coherent_for_testing(1.05, 1.0) ||
        msplat_stage_timing_aggregate_coherent_for_testing(0.249, 1.0) ||
        msplat_stage_timing_aggregate_coherent_for_testing(1.051, 1.0) ||
        msplat_stage_timing_aggregate_coherent_for_testing(0.0, 1.0) ||
        msplat_stage_timing_aggregate_coherent_for_testing(1.0, 0.0)) {
        throw std::runtime_error("GPU aggregate stage timing bounds are invalid");
    }

    constexpr std::uint32_t numer = 125;
    constexpr std::uint32_t denom = 3;
    constexpr double expectedFrequency = 24'000'000.0;
    constexpr std::uint64_t cpuStep = 48'000;
    constexpr std::uint64_t gpuStep = 48'000;
    std::uint64_t cpuSamples[] = {
        10'000'000,
        10'048'000,
        10'096'000,
        10'144'000,
        10'192'000,
        10'240'000,
        10'288'000,
    };
    std::uint64_t gpuSamples[] = {
        20'000'000,
        20'000'000 + gpuStep,
        20'000'000 + gpuStep * 2,
        20'000'000 + gpuStep * 3,
        20'000'000 + gpuStep * 4,
        20'000'000 + gpuStep * 5,
        20'000'000 + gpuStep * 6 + 12'000,
    };
    std::uint32_t validIntervals = 0;
    const double calibrated = msplat_gpu_frequency_from_timestamp_pairs_for_testing(
        cpuSamples,
        gpuSamples,
        std::size(cpuSamples),
        numer,
        denom,
        &validIntervals
    );
    requireRelativeNear(
        "GPU timestamp calibration",
        calibrated,
        expectedFrequency,
        1.0e-12
    );
    if (validIntervals != std::size(cpuSamples) - 1) {
        throw std::runtime_error("legacy calibration did not inspect every valid interval");
    }

    const std::uint64_t invalidCPU[] = {7, 7, 6, 5, 4};
    const std::uint64_t invalidGPU[] = {9, 9, 8, 7, 6};
    validIntervals = 99;
    const double rejected = msplat_gpu_frequency_from_timestamp_pairs_for_testing(
        invalidCPU,
        invalidGPU,
        std::size(invalidCPU),
        numer,
        denom,
        &validIntervals
    );
    if (std::isfinite(rejected) || validIntervals != 0) {
        throw std::runtime_error("invalid timestamp pairs produced a calibration");
    }

    std::cout << "gpu_timestamp_math passed\n";
}

std::uint64_t geometricCapacity(std::uint64_t required) {
    const std::uint64_t maximum = std::numeric_limits<std::uint32_t>::max();
    std::uint64_t capacity = 1;
    while (capacity < required && capacity <= maximum / 2) capacity *= 2;
    return capacity < required ? maximum : capacity;
}

struct RasterResult {
    std::vector<float> rgb;
    std::vector<float> alpha;
    std::vector<float> positionGradients;
    std::vector<float> colorGradients;
    std::vector<float> opacityGradients;
    std::vector<float> positions;
    std::vector<float> colors;
    std::vector<float> opacities;
    std::vector<float> positionFirstMoment;
    std::vector<float> positionSecondMoment;
    std::vector<float> colorFirstMoment;
    std::vector<float> colorSecondMoment;
    std::vector<float> opacityFirstMoment;
    std::vector<float> opacitySecondMoment;
    std::vector<std::uint32_t> contributingPixelCounts;
    std::size_t maxContributorsPerPixel = 0;
    float maximumCandidateAlpha = 0.0f;
    MsplatRasterStats stats {};
};

struct RasterReferenceInputs {
    int width = 0;
    int height = 0;
    std::vector<float> xys;
    std::vector<float> depths;
    std::vector<int> radii;
    std::vector<float> aabb;
    std::vector<float> conics;
    std::vector<float> rawColors;
    std::vector<float> opacityLogits;
    std::vector<float> renderGradients;
    std::vector<float> projectedPositionGradients;
    std::vector<float> rasterColorGradients;
    std::vector<float> opacityGradients;
};

void requireNear(
    const std::string &label,
    const std::vector<float> &reference,
    const std::vector<float> &candidate
);

struct ModelSnapshot {
    std::vector<float> positions;
    std::vector<float> scales;
    std::vector<float> quaternions;
    std::vector<float> colorsDc;
    std::vector<float> colorsRest;
    std::vector<float> opacities;
    std::vector<float> positionFirstMoment;
    std::vector<float> positionSecondMoment;
    std::vector<float> scaleFirstMoment;
    std::vector<float> scaleSecondMoment;
    std::vector<float> quaternionFirstMoment;
    std::vector<float> quaternionSecondMoment;
    std::vector<float> colorDcFirstMoment;
    std::vector<float> colorDcSecondMoment;
    std::vector<float> colorRestFirstMoment;
    std::vector<float> colorRestSecondMoment;
    std::vector<float> opacityFirstMoment;
    std::vector<float> opacitySecondMoment;
    std::vector<float> rendered;
};

std::vector<float> copyTensor(const MTensor &tensor) {
    const float *values = tensor.data<float>();
    return std::vector<float>(values, values + tensor.numel());
}

Model makeModel(const InputData &inputData, int shDegreeInterval = 1000) {
    constexpr float background[3] = {0.0f, 0.0f, 0.0f};
    return Model(
        inputData,
        static_cast<int>(inputData.cameras.size()),
        0,
        3000,
        3,
        shDegreeInterval,
        100,
        500,
        30,
        0.0002f,
        0.01f,
        4000,
        0.05f,
        3000,
        false,
        background
    );
}

void verifyPartialThreadgroupLossAccounting(const std::string &dataset) {
    constexpr int width = 33;
    constexpr int height = 35;
    constexpr int step = 1;
    constexpr float edgeDelta = 0.25f;

    auto measureLoss = [&](bool perturbBottomRightPixel, float ssimWeight) {
        cleanup_msplat_metal();
        msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
        msplat_set_raster_fallback_count(0);
        msplat_set_force_exact_for_testing(false);
        msplat_set_geometry_adam_fusion_enabled_for_testing(true);

        float loss = std::numeric_limits<float>::quiet_NaN();
        {
            InputData inputData = inputDataFromX(dataset);
            if (inputData.cameras.empty() || inputData.points.count <= 0) {
                throw std::runtime_error(
                    "partial-threadgroup loss fixture has no camera or sparse points"
                );
            }
            Camera &camera = inputData.cameras.front();
            const float scaleX = static_cast<float>(width) /
                static_cast<float>(camera.width);
            const float scaleY = static_cast<float>(height) /
                static_cast<float>(camera.height);
            camera.fx *= scaleX;
            camera.cx *= scaleX;
            camera.fy *= scaleY;
            camera.cy *= scaleY;
            camera.width = width;
            camera.height = height;
            camera.image = {};
            camera.imagePyramids.clear();
            camera.mtensorImageCache.clear();
            camera.cachedViewMat = MTensor();
            camera.cachedProjViewMat = MTensor();
            camera.cachedFovX = 0;
            camera.cachedFovY = 0;

            Model model = makeModel(inputData);
            MTensor rendered = model.render(camera, step);
            msplat_commit();
            msplat_gpu_sync();

            std::vector<float> targetPixels = copyTensor(rendered);
            const std::size_t expectedPixelCount =
                static_cast<std::size_t>(width) * height * 3;
            if (targetPixels.size() != expectedPixelCount) {
                throw std::runtime_error(
                    "partial-threadgroup render has an unexpected pixel count"
                );
            }
            if (perturbBottomRightPixel) {
                const std::size_t edge =
                    (static_cast<std::size_t>(height - 1) * width + width - 1) * 3;
                for (int channel = 0; channel < 3; ++channel) {
                    targetPixels[edge + channel] += edgeDelta;
                }
            }

            MTensor target = gpu_empty({height, width, 3}, DType::Float32);
            std::memcpy(
                target.data_ptr(),
                targetPixels.data(),
                targetPixels.size() * sizeof(float)
            );
            msplat_set_raster_iteration_context(step, 0);
            model.fullIteration(camera, step, target, ssimWeight);
            msplat_record_last_loss(
                0,
                1,
                1.0f / static_cast<float>(width * height)
            );
            msplat_commit();
            msplat_sync_loss_window(1, &loss);
        }
        cleanup_msplat_metal();
        return loss;
    };

    const float identityLoss = measureLoss(false, 0.2f);
    if (!std::isfinite(identityLoss) || std::abs(identityLoss) > 1.0e-6f) {
        throw std::runtime_error(
            "partial SSIM threadgroup identity loss was not zero: " +
            std::to_string(identityLoss)
        );
    }

    const float edgeLoss = measureLoss(true, 0.0f);
    const float expectedEdgeLoss = edgeDelta / static_cast<float>(width * height);
    const float edgeTolerance = std::max(1.0e-7f, expectedEdgeLoss * 1.0e-3f);
    if (!std::isfinite(edgeLoss) ||
        std::abs(edgeLoss - expectedEdgeLoss) > edgeTolerance) {
        throw std::runtime_error(
            "partial threadgroup omitted an edge loss contribution: actual=" +
            std::to_string(edgeLoss) +
            " expected=" + std::to_string(expectedEdgeLoss)
        );
    }

    std::cout << "partial threadgroup loss accounting passed\n";
}

void setUniformOpacity(Model &model, float opacity) {
    if (!(opacity > 1.0f / 255.0f && opacity < 1.0f)) {
        throw std::runtime_error("test opacity must survive the raster alpha threshold");
    }
    const float logit = std::log(opacity / (1.0f - opacity));
    std::fill(
        model.opacities.data<float>(),
        model.opacities.data<float>() + model.opacities.numel(),
        logit
    );
}

class TemporaryCheckpoint {
public:
    TemporaryCheckpoint() {
        const std::string pattern = (
            std::filesystem::temp_directory_path() /
            "easysplat-geometry-adam-parity.XXXXXX"
        ).string();
        std::vector<char> writablePattern(pattern.begin(), pattern.end());
        writablePattern.push_back('\0');
        const int descriptor = ::mkstemp(writablePattern.data());
        if (descriptor == -1) {
            throw std::runtime_error("could not create a unique geometry-Adam checkpoint");
        }
        path_ = writablePattern.data();
        if (::close(descriptor) != 0) {
            std::error_code ignored;
            std::filesystem::remove(path_, ignored);
            path_.clear();
            throw std::runtime_error("could not close the temporary geometry-Adam checkpoint");
        }
    }

    ~TemporaryCheckpoint() {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
    }

    TemporaryCheckpoint(const TemporaryCheckpoint &) = delete;
    TemporaryCheckpoint &operator=(const TemporaryCheckpoint &) = delete;

    const std::filesystem::path &path() const { return path_; }

private:
    std::filesystem::path path_;
};

void verifyDensificationScratchLifecycle(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    {
        InputData inputData = inputDataFromX(dataset);
        Model model = makeModel(inputData);
        if (model.densify_compact_scratch.defined()) {
            throw std::runtime_error("densification scratch memory was allocated eagerly");
        }

        const int pointCount = model.num_active;
        const int64_t featureStride = model.featuresRest_buf.stride0();
        model.ensureCapacity(3 * pointCount);
        model.ensureDensificationCompactScratch(pointCount);
        const int64_t expectedElements = 3LL * pointCount * featureStride;
        if (!model.densify_compact_scratch.defined() ||
            model.densify_compact_scratch.numel() != expectedElements) {
            throw std::runtime_error("densification scratch memory has an invalid shape");
        }
        const void *storage = model.densify_compact_scratch.data_ptr();
        model.ensureDensificationCompactScratch(pointCount);
        if (model.densify_compact_scratch.data_ptr() != storage) {
            throw std::runtime_error("sufficient densification scratch memory was reallocated");
        }

        model.radii = gpu_zeros({pointCount}, DType::Float32);
        model.afterTrain(model.stopSplitAt);
        if (model.densify_compact_scratch.defined()) {
            throw std::runtime_error("densification scratch memory survived the final boundary");
        }
        try {
            model.ensureDensificationCompactScratch(0);
            throw std::runtime_error("invalid densification point count was accepted");
        } catch (const std::runtime_error &error) {
            if (std::string(error.what()).find("inconsistent densification scratch") ==
                std::string::npos) {
                throw;
            }
        }
        if (model.densify_compact_scratch.defined()) {
            throw std::runtime_error("invalid densification request retained scratch memory");
        }
    }
    cleanup_msplat_metal();
    std::cout << "densification scratch lifecycle passed\n";
}

void enqueueStep(Model &model, Camera &camera, int step, std::size_t cameraIndex) {
    if (camera.image.empty()) {
        camera.loadImage(1.0f);
        if (camera.image.empty()) {
            throw std::runtime_error("replay fixture image did not decode");
        }
    }
    MTensor target = camera.getGPUImage(model.getDownscaleFactor(step));
    msplat_set_raster_iteration_context(step, cameraIndex);
    model.fullIteration(camera, step, target, 0.2f);
    model.schedulersStep(step);
    msplat_commit();
}

ModelSnapshot snapshotModel(const Model &model, const MTensor *rendered = nullptr) {
    return ModelSnapshot {
        copyTensor(model.means),
        copyTensor(model.scales),
        copyTensor(model.quats),
        copyTensor(model.featuresDc),
        copyTensor(model.featuresRest),
        copyTensor(model.opacities),
        copyTensor(model.adam_exp_avg[0]),
        copyTensor(model.adam_exp_avg_sq[0]),
        copyTensor(model.adam_exp_avg[1]),
        copyTensor(model.adam_exp_avg_sq[1]),
        copyTensor(model.adam_exp_avg[2]),
        copyTensor(model.adam_exp_avg_sq[2]),
        copyTensor(model.adam_exp_avg[3]),
        copyTensor(model.adam_exp_avg_sq[3]),
        copyTensor(model.adam_exp_avg[4]),
        copyTensor(model.adam_exp_avg_sq[4]),
        copyTensor(model.adam_exp_avg[5]),
        copyTensor(model.adam_exp_avg_sq[5]),
        rendered == nullptr ? std::vector<float> {} : copyTensor(*rendered),
    };
}

void makeBroadSplats(Model &model) {
    float *scales = model.scales.data<float>();
    std::fill(scales, scales + model.scales.numel(), 0.0f);
}

void configureOverflowReferenceModel(Model &model) {
    makeBroadSplats(model);
    setUniformOpacity(model, overflowReferenceOpacity);
}

RasterResult runSingleStep(
    const std::string &dataset,
    bool forceExact,
    bool tileSpanCulling = false,
    bool overflowReferenceConfiguration = false
) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(forceExact);
    msplat_set_tile_culling_min_area_for_testing(tileSpanCulling ? 4 : 0);

    RasterResult result;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty() || inputData.points.count <= 0) {
            throw std::runtime_error("parity fixture has no camera or sparse points");
        }
        Camera &camera = inputData.cameras.front();
        camera.loadImage(1.0f);
        if (camera.image.empty()) {
            throw std::runtime_error("parity fixture image did not decode");
        }

        Model model = makeModel(inputData);
        if (overflowReferenceConfiguration) configureOverflowReferenceModel(model);
        if (forceExact) {
            // The production path discovers exact capacity from the GPU count,
            // then replays the failed iteration without committing optimizer
            // state. Exercise that same path for parity instead of reserving a
            // guessed worst-case workspace.
            enqueueStep(model, camera, 1, 0);
            msplat_gpu_sync_for_raster_replay();
            const MsplatRasterStats overflow = msplat_get_raster_stats();
            if (!overflow.capacity_exceeded || overflow.memory_budget_exceeded ||
                overflow.resource_limit_exceeded ||
                overflow.latest_intersection_count == 0) {
                throw std::runtime_error("exact parity probe did not report recoverable capacity");
            }
            model.adam_step_count = 0;
            model.schedulersStep(0);
            msplat_grow_exact_raster_capacity(overflow.latest_intersection_count);
            msplat_clear_raster_capacity_failure();
            enqueueStep(model, camera, 1, 0);
        } else {
            enqueueStep(model, camera, 1, 0);
        }
        msplat_gpu_sync();

        const int pointCount = model.num_active;
        const int pixelCount = model.lastWidth * model.lastHeight;
        result.rgb.resize(static_cast<std::size_t>(pixelCount) * 3);
        result.alpha.resize(pixelCount);
        result.positionGradients.resize(static_cast<std::size_t>(pointCount) * 3);
        result.colorGradients.resize(static_cast<std::size_t>(pointCount) * 3);
        result.opacityGradients.resize(pointCount);
        msplat_copy_last_raster_debug(
            result.rgb.data(),
            result.alpha.data(),
            pixelCount,
            result.positionGradients.data(),
            result.colorGradients.data(),
            result.opacityGradients.data(),
            pointCount
        );

        result.positions = copyTensor(model.means);
        result.colors = copyTensor(model.featuresDc);
        result.opacities = copyTensor(model.opacities);
        result.positionFirstMoment = copyTensor(model.adam_exp_avg[0]);
        result.positionSecondMoment = copyTensor(model.adam_exp_avg_sq[0]);
        result.colorFirstMoment = copyTensor(model.adam_exp_avg[3]);
        result.colorSecondMoment = copyTensor(model.adam_exp_avg_sq[3]);
        result.opacityFirstMoment = copyTensor(model.adam_exp_avg[5]);
        result.opacitySecondMoment = copyTensor(model.adam_exp_avg_sq[5]);
        const float gradientScale = 1.0f / (1.0f - model.adam_beta1);
        std::transform(
            result.colorFirstMoment.begin(), result.colorFirstMoment.end(),
            result.colorGradients.begin(),
            [gradientScale](float value) { return value * gradientScale; }
        );
        result.stats = msplat_get_raster_stats();
    }
    cleanup_msplat_metal();
    return result;
}

RasterReferenceInputs runOverflowReferenceFixture(const std::string &dataset) {
    if (std::pow(1.0f - overflowReferenceOpacity, 2050.0f) <= 1.0e-4f) {
        throw std::runtime_error("overflow reference opacity cannot expose points after 2048");
    }
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);

    RasterReferenceInputs result;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty() || inputData.points.count <= 2048) {
            throw std::runtime_error("overflow reference fixture must exceed 2048 points");
        }
        Camera &camera = inputData.cameras.front();
        camera.loadImage(1.0f);
        Model model = makeModel(inputData);
        configureOverflowReferenceModel(model);
        result.opacityLogits = copyTensor(model.opacities);

        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats overflow = msplat_get_raster_stats();
        if (!overflow.capacity_exceeded || overflow.latest_intersection_count <= 2048 ||
            overflow.dropped_intersection_count != 0) {
            throw std::runtime_error("overflow reference probe did not exceed 2048 intersections");
        }
        model.adam_step_count = 0;
        model.schedulersStep(0);
        msplat_grow_exact_raster_capacity(overflow.latest_intersection_count);
        msplat_clear_raster_capacity_failure();
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync();

        const int pointCount = model.num_active;
        const int pixelCount = model.lastWidth * model.lastHeight;
        result.width = model.lastWidth;
        result.height = model.lastHeight;
        result.xys.resize(static_cast<std::size_t>(pointCount) * 2);
        result.depths.resize(pointCount);
        result.radii.resize(pointCount);
        result.aabb.resize(static_cast<std::size_t>(pointCount) * 2);
        result.conics.resize(static_cast<std::size_t>(pointCount) * 3);
        result.rawColors.resize(static_cast<std::size_t>(pointCount) * 3);
        result.renderGradients.resize(static_cast<std::size_t>(pixelCount) * 3);
        result.projectedPositionGradients.resize(static_cast<std::size_t>(pointCount) * 2);
        result.rasterColorGradients.resize(static_cast<std::size_t>(pointCount) * 3);
        result.opacityGradients.resize(pointCount);
        msplat_copy_last_raster_reference_debug(
            result.xys.data(), result.depths.data(), result.radii.data(), result.aabb.data(),
            result.conics.data(), result.rawColors.data(), result.renderGradients.data(),
            result.projectedPositionGradients.data(), result.rasterColorGradients.data(),
            result.opacityGradients.data(), pointCount, pixelCount
        );
        const MsplatRasterStats completed = msplat_get_raster_stats();
        if (completed.fallback_count != 1 || completed.capacity_exceeded ||
            completed.dropped_intersection_count != 0) {
            throw std::runtime_error("overflow reference exact rerun was not lossless");
        }
    }
    cleanup_msplat_metal();
    return result;
}

RasterResult cpuRasterReference(const RasterReferenceInputs &input) {
    const std::size_t pointCount = input.depths.size();
    const std::size_t pixelCount = static_cast<std::size_t>(input.width) * input.height;
    if (pointCount <= 2048 || input.opacityLogits.size() != pointCount) {
        throw std::runtime_error("CPU raster reference received an invalid overflow fixture");
    }
    RasterResult result;
    result.rgb.assign(pixelCount * 3, 0.0f);
    result.alpha.assign(pixelCount, 0.0f);
    result.positionGradients.assign(pointCount * 2, 0.0f);
    result.colorGradients.assign(pointCount * 3, 0.0f);
    result.opacityGradients.assign(pointCount, 0.0f);
    result.contributingPixelCounts.assign(pointCount, 0);

    std::vector<std::size_t> depthOrder(pointCount);
    std::iota(depthOrder.begin(), depthOrder.end(), 0);
    std::stable_sort(depthOrder.begin(), depthOrder.end(), [&](std::size_t lhs, std::size_t rhs) {
        return input.depths[lhs] < input.depths[rhs];
    });

    struct Contribution { std::size_t point; float alpha; };
    std::vector<Contribution> contributions;
    contributions.reserve(pointCount);
    const int tilesX = (input.width + 15) / 16;
    const int tilesY = (input.height + 15) / 16;
    for (int py = 0; py < input.height; ++py) {
        for (int px = 0; px < input.width; ++px) {
            const std::size_t pixel = static_cast<std::size_t>(py) * input.width + px;
            const int pixelTileX = px / 16;
            const int pixelTileY = py / 16;
            contributions.clear();
            float transmittance = 1.0f;
            float color[3] = {0.0f, 0.0f, 0.0f};
            for (const std::size_t point : depthOrder) {
                if (input.radii[point] <= 0) continue;
                const float centerX = input.xys[point * 2];
                const float centerY = input.xys[point * 2 + 1];
                const float radiusX = input.aabb[point * 2];
                const float radiusY = input.aabb[point * 2 + 1];
                const int tileMinX = std::clamp(static_cast<int>(centerX / 16.0f - radiusX / 16.0f), 0, tilesX);
                const int tileMaxX = std::clamp(static_cast<int>(centerX / 16.0f + radiusX / 16.0f + 1.0f), 0, tilesX);
                const int tileMinY = std::clamp(static_cast<int>(centerY / 16.0f - radiusY / 16.0f), 0, tilesY);
                const int tileMaxY = std::clamp(static_cast<int>(centerY / 16.0f + radiusY / 16.0f + 1.0f), 0, tilesY);
                if (pixelTileX < tileMinX || pixelTileX >= tileMaxX ||
                    pixelTileY < tileMinY || pixelTileY >= tileMaxY) continue;
                const float dx = centerX - static_cast<float>(px);
                const float dy = centerY - static_cast<float>(py);
                const float *conic = &input.conics[point * 3];
                const float sigma = 0.5f * (conic[0] * dx * dx + conic[2] * dy * dy) +
                    conic[1] * dx * dy;
                if (sigma < 0.0f || sigma >= 5.55f) continue;
                const float opacity = 1.0f / (1.0f + std::exp(-input.opacityLogits[point]));
                const float alpha = std::min(0.999f, opacity * std::exp(-sigma));
                result.maximumCandidateAlpha = std::max(result.maximumCandidateAlpha, alpha);
                if (alpha < 1.0f / 255.0f) continue;
                const float nextTransmittance = transmittance * (1.0f - alpha);
                if (nextTransmittance <= 1.0e-4f) break;
                contributions.push_back({point, alpha});
                for (int channel = 0; channel < 3; ++channel) {
                    const float rgb = std::max(input.rawColors[point * 3 + channel] + 0.5f, 0.0f);
                    color[channel] = std::fma(rgb, alpha * transmittance, color[channel]);
                }
                transmittance = nextTransmittance;
            }
            result.alpha[pixel] = 1.0f - transmittance;
            result.maxContributorsPerPixel = std::max(
                result.maxContributorsPerPixel,
                contributions.size()
            );
            for (const Contribution &contribution : contributions) {
                ++result.contributingPixelCounts[contribution.point];
            }
            for (int channel = 0; channel < 3; ++channel) {
                result.rgb[pixel * 3 + channel] = std::clamp(color[channel], 0.0f, 1.0f);
            }

            float reverseTransmittance = transmittance;
            float buffer[3] = {0.0f, 0.0f, 0.0f};
            for (auto iterator = contributions.rbegin(); iterator != contributions.rend(); ++iterator) {
                const std::size_t point = iterator->point;
                const float alpha = iterator->alpha;
                if (alpha >= 0.999f) continue;
                const float reciprocalAlpha = 1.0f / (1.0f - alpha);
                reverseTransmittance *= reciprocalAlpha;
                const float factor = alpha * reverseTransmittance;
                float vAlpha = 0.0f;
                for (int channel = 0; channel < 3; ++channel) {
                    const float outputGradient = input.renderGradients[pixel * 3 + channel];
                    const float unclampedRgb = input.rawColors[point * 3 + channel] + 0.5f;
                    if (unclampedRgb >= 0.0f) {
                        result.colorGradients[point * 3 + channel] += factor * outputGradient;
                    }
                    const float rgb = std::max(unclampedRgb, 0.0f);
                    vAlpha += (rgb * reverseTransmittance - buffer[channel] * reciprocalAlpha) * outputGradient;
                    buffer[channel] = std::fma(rgb, factor, buffer[channel]);
                }
                const float vSigma = -alpha * vAlpha;
                const float dx = input.xys[point * 2] - static_cast<float>(px);
                const float dy = input.xys[point * 2 + 1] - static_cast<float>(py);
                const float *conic = &input.conics[point * 3];
                result.positionGradients[point * 2] +=
                    vSigma * (conic[0] * dx + conic[1] * dy);
                result.positionGradients[point * 2 + 1] +=
                    vSigma * (conic[1] * dx + conic[2] * dy);
                const float opacity = 1.0f / (1.0f + std::exp(-input.opacityLogits[point]));
                result.opacityGradients[point] += -vSigma * (1.0f - opacity);
            }
        }
    }
    return result;
}

float maximumAbsoluteGradientAfter(
    const std::vector<float> &gradients,
    std::size_t pointBoundary,
    std::size_t valuesPerPoint
) {
    const std::size_t first = pointBoundary * valuesPerPoint;
    if (valuesPerPoint == 0 || first >= gradients.size() ||
        gradients.size() % valuesPerPoint != 0) {
        throw std::runtime_error("invalid tail-gradient boundary");
    }
    float maximum = 0.0f;
    for (std::size_t index = first; index < gradients.size(); ++index) {
        maximum = std::max(maximum, std::abs(gradients[index]));
    }
    return maximum;
}

void requireMeaningfulTailGradient(
    const std::string &label,
    const std::vector<float> &gradients,
    std::size_t pointBoundary,
    std::size_t valuesPerPoint
) {
    const float overall = maximumAbsoluteGradientAfter(gradients, 0, valuesPerPoint);
    const float tail = maximumAbsoluteGradientAfter(
        gradients,
        pointBoundary,
        valuesPerPoint
    );
    const float minimum = std::max(1.0e-12f, overall * 1.0e-6f);
    if (!std::isfinite(tail) || tail < minimum) {
        throw std::runtime_error(
            label + " has no meaningful gradient at or after point " +
            std::to_string(pointBoundary) + ": tail=" + std::to_string(tail) +
            " required=" + std::to_string(minimum)
        );
    }
}

void requireOverflowTailEvidence(
    const RasterResult &reference,
    const RasterResult &actual,
    std::size_t pointBoundary
) {
    const std::size_t firstTailPoint = pointBoundary + 1;
    if (firstTailPoint >= reference.contributingPixelCounts.size()) {
        throw std::runtime_error("invalid overflow contribution boundary");
    }
    const std::uint64_t tailContributions = std::accumulate(
        reference.contributingPixelCounts.begin() + firstTailPoint,
        reference.contributingPixelCounts.end(),
        std::uint64_t {0}
    );
    if (tailContributions == 0) {
        throw std::runtime_error(
            "CPU raster reference has no supporting contribution after point " +
            std::to_string(pointBoundary) + "; maximum contributors per pixel=" +
            std::to_string(reference.maxContributorsPerPixel) +
            " maximum candidate alpha=" + std::to_string(reference.maximumCandidateAlpha)
        );
    }

    requireMeaningfulTailGradient(
        "CPU projected-position oracle", reference.positionGradients, firstTailPoint, 2
    );
    requireMeaningfulTailGradient(
        "GPU projected-position result", actual.positionGradients, firstTailPoint, 2
    );
    requireMeaningfulTailGradient(
        "CPU raster-color oracle", reference.colorGradients, firstTailPoint, 3
    );
    requireMeaningfulTailGradient(
        "GPU raster-color result", actual.colorGradients, firstTailPoint, 3
    );
    requireMeaningfulTailGradient(
        "CPU opacity oracle", reference.opacityGradients, firstTailPoint, 1
    );
    requireMeaningfulTailGradient(
        "GPU opacity result", actual.opacityGradients, firstTailPoint, 1
    );
    std::cout << "overflow_tail_evidence after_index=" << pointBoundary
              << " supporting_contributions=" << tailContributions << '\n';
}

void verifyOverflowCPUReference(const std::string &dataset) {
    const RasterReferenceInputs exact = runOverflowReferenceFixture(dataset);
    const RasterResult reference = cpuRasterReference(exact);
    RasterResult actual;
    actual.rgb.resize(reference.rgb.size());
    actual.alpha.resize(reference.alpha.size());
    actual.positionGradients = exact.projectedPositionGradients;
    actual.colorGradients = exact.rasterColorGradients;
    actual.opacityGradients = exact.opacityGradients;
    requireOverflowTailEvidence(reference, actual, 1024);
    requireOverflowTailEvidence(reference, actual, 2048);

    cleanup_msplat_metal();
    // The raw image/alpha debug values are copied by the existing test hook in
    // a separate exact run, keeping the CPU oracle independent of exact bins.
    const RasterResult raw = runSingleStep(
        dataset,
        true,
        false,
        true
    );
    actual.rgb = raw.rgb;
    actual.alpha = raw.alpha;
    requireNear("overflow_cpu_forward_rgb", reference.rgb, actual.rgb);
    requireNear("overflow_cpu_forward_alpha", reference.alpha, actual.alpha);
    requireNear("overflow_cpu_position_gradients", reference.positionGradients, actual.positionGradients);
    requireNear("overflow_cpu_color_gradients", reference.colorGradients, actual.colorGradients);
    requireNear("overflow_cpu_opacity_gradients", reference.opacityGradients, actual.opacityGradients);
    std::cout << "overflow_cpu_raster_reference passed\n";
}

void requireNear(
    const std::string &label,
    const std::vector<float> &fast,
    const std::vector<float> &exact
) {
    if (fast.size() != exact.size() || fast.empty()) {
        throw std::runtime_error(label + " shape mismatch");
    }
    float worstError = 0;
    std::size_t worstIndex = 0;
    for (std::size_t index = 0; index < fast.size(); ++index) {
        if (!std::isfinite(fast[index]) || !std::isfinite(exact[index])) {
            throw std::runtime_error(label + " contains a non-finite value");
        }
        const float error = std::abs(fast[index] - exact[index]);
        const float tolerance = absoluteTolerance +
            relativeTolerance * std::abs(fast[index]);
        if (error > worstError) {
            worstError = error;
            worstIndex = index;
        }
        if (error > tolerance) {
            throw std::runtime_error(
                label + " differs at index " + std::to_string(index) +
                ": fast=" + std::to_string(fast[index]) +
                " exact=" + std::to_string(exact[index]) +
                " error=" + std::to_string(error) +
                " tolerance=" + std::to_string(tolerance)
            );
        }
    }
    std::cout << label << " max_abs_error=" << worstError
              << " index=" << worstIndex << '\n';
}

void requireModelNear(
    const std::string &label,
    const ModelSnapshot &reference,
    const ModelSnapshot &candidate
) {
    requireNear(label + "_positions", reference.positions, candidate.positions);
    requireNear(label + "_scales", reference.scales, candidate.scales);
    requireNear(label + "_quaternions", reference.quaternions, candidate.quaternions);
    requireNear(label + "_colors_dc", reference.colorsDc, candidate.colorsDc);
    requireNear(label + "_colors_rest", reference.colorsRest, candidate.colorsRest);
    requireNear(label + "_opacities", reference.opacities, candidate.opacities);
    requireNear(
        label + "_position_first_moment",
        reference.positionFirstMoment,
        candidate.positionFirstMoment
    );
    requireNear(
        label + "_position_second_moment",
        reference.positionSecondMoment,
        candidate.positionSecondMoment
    );
    requireNear(
        label + "_scale_first_moment",
        reference.scaleFirstMoment,
        candidate.scaleFirstMoment
    );
    requireNear(
        label + "_scale_second_moment",
        reference.scaleSecondMoment,
        candidate.scaleSecondMoment
    );
    requireNear(
        label + "_quaternion_first_moment",
        reference.quaternionFirstMoment,
        candidate.quaternionFirstMoment
    );
    requireNear(
        label + "_quaternion_second_moment",
        reference.quaternionSecondMoment,
        candidate.quaternionSecondMoment
    );
    requireNear(
        label + "_color_dc_first_moment",
        reference.colorDcFirstMoment,
        candidate.colorDcFirstMoment
    );
    requireNear(
        label + "_color_dc_second_moment",
        reference.colorDcSecondMoment,
        candidate.colorDcSecondMoment
    );
    requireNear(
        label + "_color_rest_first_moment",
        reference.colorRestFirstMoment,
        candidate.colorRestFirstMoment
    );
    requireNear(
        label + "_color_rest_second_moment",
        reference.colorRestSecondMoment,
        candidate.colorRestSecondMoment
    );
    requireNear(
        label + "_opacity_first_moment",
        reference.opacityFirstMoment,
        candidate.opacityFirstMoment
    );
    requireNear(
        label + "_opacity_second_moment",
        reference.opacitySecondMoment,
        candidate.opacitySecondMoment
    );
    if (!reference.rendered.empty() || !candidate.rendered.empty()) {
        requireNear(label + "_rendered", reference.rendered, candidate.rendered);
    }
}

void requireSphericalHarmonicStateExercised(
    const std::string &label,
    const ModelSnapshot &snapshot
) {
    constexpr std::size_t colorChannels = 3;
    constexpr std::size_t basesWithoutDc = 15;
    constexpr std::size_t pointStride = basesWithoutDc * colorChannels;

    const auto requireNonzeroDegree = [&](
        const std::string &stateLabel,
        const std::vector<float> &values,
        int degree
    ) {
        if (values.empty() || values.size() % pointStride != 0) {
            throw std::runtime_error(label + "_" + stateLabel + " has an invalid SH shape");
        }
        const std::size_t firstBasis = static_cast<std::size_t>(degree * degree - 1);
        const std::size_t basisCount = static_cast<std::size_t>(2 * degree + 1);
        const std::size_t firstValue = firstBasis * colorChannels;
        const std::size_t valueCount = basisCount * colorChannels;
        bool foundNonzero = false;
        for (std::size_t point = 0; point < values.size(); point += pointStride) {
            for (std::size_t offset = 0; offset < valueCount; ++offset) {
                const float value = values[point + firstValue + offset];
                if (!std::isfinite(value)) {
                    throw std::runtime_error(
                        label + "_" + stateLabel + " contains a non-finite value"
                    );
                }
                foundNonzero = foundNonzero || value != 0.0f;
            }
        }
        if (!foundNonzero) {
            throw std::runtime_error(
                label + "_" + stateLabel + " did not exercise SH degree " +
                std::to_string(degree)
            );
        }
    };

    for (int degree = 1; degree <= 3; ++degree) {
        requireNonzeroDegree("coefficients", snapshot.colorsRest, degree);
        requireNonzeroDegree("first_moment", snapshot.colorRestFirstMoment, degree);
        requireNonzeroDegree("second_moment", snapshot.colorRestSecondMoment, degree);
    }
}

std::uint64_t primeExactWorkspace(
    Model &model,
    Camera &camera,
    int probeIteration,
    std::size_t cameraIndex
);

ModelSnapshot runGeometryAdamWindow(
    const std::string &dataset,
    bool fused,
    bool forceExact,
    int firstStep,
    int lastStep,
    const std::string &resumeCheckpoint = {}
) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(forceExact);
    msplat_set_geometry_adam_fusion_enabled_for_testing(fused);

    ModelSnapshot snapshot;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty()) {
            throw std::runtime_error("geometry-Adam parity fixture has no camera");
        }
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData, geometryAdamShDegreeInterval);
        if (!resumeCheckpoint.empty()) {
            const int loadedStep = model.loadCheckpoint(resumeCheckpoint);
            if (loadedStep != firstStep - 1) {
                throw std::runtime_error("geometry-Adam checkpoint resumed at the wrong step");
            }
        }
        if (forceExact && resumeCheckpoint.empty()) {
            (void)primeExactWorkspace(model, camera, 1, 0);
        }
        for (int step = firstStep; step <= lastStep; ++step) {
            enqueueStep(model, camera, step, 0);
        }
        msplat_gpu_sync_for_raster_replay();
        Camera &renderCamera = forceExact ? camera : inputData.cameras.back();
        MTensor rendered = model.render(renderCamera, lastStep);
        msplat_commit();
        msplat_gpu_sync();
        snapshot = snapshotModel(model, &rendered);
    }
    cleanup_msplat_metal();
    return snapshot;
}

ModelSnapshot runGeometryAdamCheckpointPrefix(
    const std::string &dataset,
    bool fused,
    int lastStep,
    const std::string &checkpoint
) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(false);
    msplat_set_geometry_adam_fusion_enabled_for_testing(fused);

    ModelSnapshot snapshot;
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData, geometryAdamShDegreeInterval);
        for (int step = 1; step <= lastStep; ++step) {
            enqueueStep(model, camera, step, 0);
        }
        model.saveCheckpoint(checkpoint, lastStep);
        snapshot = snapshotModel(model);
    }
    cleanup_msplat_metal();
    return snapshot;
}

void verifyGeometryAdamFusionParity(const std::string &dataset) {
    constexpr int lastStep = 24;
    const ModelSnapshot legacy = runGeometryAdamWindow(
        dataset, false, false, 1, lastStep
    );
    const ModelSnapshot fused = runGeometryAdamWindow(
        dataset, true, false, 1, lastStep
    );
    requireSphericalHarmonicStateExercised("geometry_adam_common", fused);
    requireModelNear("geometry_adam_common", legacy, fused);

    const ModelSnapshot exactLegacy = runGeometryAdamWindow(
        dataset, false, true, 1, lastStep
    );
    const ModelSnapshot exactFused = runGeometryAdamWindow(
        dataset, true, true, 1, lastStep
    );
    requireSphericalHarmonicStateExercised("geometry_adam_exact", exactFused);
    requireModelNear("geometry_adam_exact", exactLegacy, exactFused);

    const TemporaryCheckpoint checkpoint;
    constexpr int checkpointStep = 12;
    const ModelSnapshot checkpointPrefix = runGeometryAdamCheckpointPrefix(
        dataset, true, checkpointStep, checkpoint.path().string()
    );
    requireSphericalHarmonicStateExercised(
        "geometry_adam_checkpoint_prefix", checkpointPrefix
    );
    const ModelSnapshot resumed = runGeometryAdamWindow(
        dataset, true, false, checkpointStep + 1, lastStep, checkpoint.path().string()
    );
    requireSphericalHarmonicStateExercised("geometry_adam_checkpoint_resume", resumed);
    requireModelNear("geometry_adam_checkpoint_resume", fused, resumed);
    std::cout << "geometry_adam_fusion_parity passed\n";
}

double benchmarkCommonPath(const std::string &dataset, bool exactDispatchEnabled) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_exact_fallback_enabled_for_testing(exactDispatchEnabled);

    double elapsed = 0;
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        camera.loadImage(1.0f);
        Model model = makeModel(inputData);
        MTensor target = camera.getGPUImage(1);

        constexpr int warmupSteps = 20;
        constexpr int measuredSteps = 200;
        for (int step = 1; step <= warmupSteps; ++step) {
            model.fullIteration(camera, step, target, 0.2f);
            msplat_commit();
        }
        msplat_gpu_sync();
        const auto started = std::chrono::steady_clock::now();
        for (int step = warmupSteps + 1; step <= warmupSteps + measuredSteps; ++step) {
            model.fullIteration(camera, step, target, 0.2f);
            msplat_commit();
        }
        msplat_gpu_sync();
        elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started
        ).count();
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (stats.fallback_count != 0 || stats.dropped_intersection_count != 0) {
            throw std::runtime_error("common-path benchmark unexpectedly used exact fallback");
        }
    }
    cleanup_msplat_metal();
    return elapsed;
}

double median(std::vector<double> values);

double benchmarkGeometryAdamPath(const std::string &dataset, bool fused) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(benchmarkMemoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_geometry_adam_fusion_enabled_for_testing(fused);

    double elapsed = 0;
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        camera.loadImage(1.0f);
        Model model = makeModel(inputData);
        MTensor target = camera.getGPUImage(1);

        constexpr int warmupSteps = 100;
        constexpr int measuredSteps = 1000;
        for (int step = 1; step <= warmupSteps; ++step) {
            model.fullIteration(camera, step, target, 0.2f);
            msplat_commit();
        }
        msplat_gpu_sync();
        const auto started = std::chrono::steady_clock::now();
        for (int step = warmupSteps + 1; step <= warmupSteps + measuredSteps; ++step) {
            model.fullIteration(camera, step, target, 0.2f);
            msplat_commit();
        }
        msplat_gpu_sync();
        elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started
        ).count();
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (stats.fallback_count != 0 || stats.dropped_intersection_count != 0) {
            throw std::runtime_error("geometry-Adam benchmark left the common raster path");
        }
    }
    cleanup_msplat_metal();
    return elapsed;
}

void benchmarkGeometryAdamFusion(const std::string &dataset) {
    std::vector<double> legacySamples;
    std::vector<double> fusedSamples;
    for (int sample = 0; sample < 5; ++sample) {
        if (sample % 2 == 0) {
            legacySamples.push_back(benchmarkGeometryAdamPath(dataset, false));
            fusedSamples.push_back(benchmarkGeometryAdamPath(dataset, true));
        } else {
            fusedSamples.push_back(benchmarkGeometryAdamPath(dataset, true));
            legacySamples.push_back(benchmarkGeometryAdamPath(dataset, false));
        }
    }
    const double legacyMedian = median(legacySamples);
    const double fusedMedian = median(fusedSamples);
    std::cout << "geometry_adam_legacy_seconds=" << legacyMedian
              << " fused_seconds=" << fusedMedian
              << " speedup=" << legacyMedian / fusedMedian << '\n';
}

double median(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

void verifyMixedResolutionGrowth(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.size() != 2 ||
            inputData.cameras[0].width >= inputData.cameras[1].width ||
            inputData.cameras[0].height >= inputData.cameras[1].height) {
            throw std::runtime_error("mixed-resolution fixture order is invalid");
        }
        Model model = makeModel(inputData);
        std::uint64_t firstAllocation = 0;
        for (std::size_t index = 0; index < inputData.cameras.size(); ++index) {
            Camera &camera = inputData.cameras[index];
            camera.loadImage(1.0f);
            MTensor target = camera.getGPUImage(1);
            model.fullIteration(camera, static_cast<int>(index) + 1, target, 0.2f);
            msplat_commit();
            msplat_gpu_sync();
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (stats.memory_budget_exceeded || stats.dropped_intersection_count != 0 ||
                stats.fallback_count != 0) {
                throw std::runtime_error("mixed-resolution common path became unsafe");
            }
            if (index == 0) {
                firstAllocation = stats.allocation_bytes;
            } else if (stats.allocation_bytes <= firstAllocation) {
                throw std::runtime_error("mixed-resolution raster workspace did not grow");
            }
        }
    }
    cleanup_msplat_metal();
    std::cout << "mixed_resolution_growth passed\n";
}

void verifyExactOnlyBudgetEvidence(const std::string &dataset) {
    struct Probe {
        std::uint64_t preciseRequired;
        std::uint64_t conservativeEstimate;
    };

    auto runProbe = [&](std::uint64_t growthBudget) {
        cleanup_msplat_metal();
        msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
        msplat_set_raster_fallback_count(0);
        msplat_set_force_exact_for_testing(true);

        Probe evidence {};
        {
            InputData inputData = inputDataFromX(dataset);
            if (inputData.cameras.empty()) {
                throw std::runtime_error("exact-only budget fixture has no camera");
            }
            Camera &camera = inputData.cameras.back();
            Model model = makeModel(inputData);
            makeBroadSplats(model);
            enqueueStep(model, camera, 1, 0);
            msplat_gpu_sync_for_raster_replay();
            const MsplatRasterStats overflow = msplat_get_raster_stats();
            const std::uint64_t tilesX =
                (static_cast<std::uint64_t>(model.lastWidth) + 15) / 16;
            const std::uint64_t tilesY =
                (static_cast<std::uint64_t>(model.lastHeight) + 15) / 16;
            const std::uint64_t packedCapacity = tilesX * tilesY * 2048;
            if (!overflow.capacity_exceeded || overflow.memory_budget_exceeded ||
                overflow.latest_intersection_count <= 2048 ||
                overflow.latest_intersection_count > packedCapacity) {
                throw std::runtime_error(
                    "exact-only budget fixture also requires packed-buffer growth"
                );
            }

            evidence.conservativeEstimate = overflow.allocation_bytes +
                overflow.latest_intersection_count * 64;
            model.adam_step_count = 0;
            model.schedulersStep(0);
            if (growthBudget != 0) {
                msplat_set_raster_memory_budget_for_testing(growthBudget);
            }
            msplat_grow_exact_raster_capacity(overflow.latest_intersection_count);
            const MsplatRasterStats grown = msplat_get_raster_stats();
            evidence.preciseRequired = grown.required_bytes;
            if (grown.required_bytes == 0 ||
                (growthBudget != 0 && grown.required_bytes > growthBudget)) {
                throw std::runtime_error("exact-only grow reported invalid budget evidence");
            }
        }
        cleanup_msplat_metal();
        return evidence;
    };

    const Probe measured = runProbe(0);
    if (measured.conservativeEstimate <= measured.preciseRequired + 1) {
        throw std::runtime_error(
            "exact-only fixture does not distinguish precise and conservative budgets: precise=" +
            std::to_string(measured.preciseRequired) + " conservative=" +
            std::to_string(measured.conservativeEstimate)
        );
    }
    const std::uint64_t boundary = measured.preciseRequired +
        (measured.conservativeEstimate - measured.preciseRequired) / 2;
    const Probe bounded = runProbe(boundary);
    if (bounded.preciseRequired > boundary ||
        bounded.conservativeEstimate <= boundary) {
        throw std::runtime_error(
            "exact-only grow did not prove the precise near-budget path"
        );
    }
    std::cout << "exact_only_budget_evidence passed\n";
}

void verifySharedAllocationBudget(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    msplat_set_geometry_adam_fusion_enabled_for_testing(true);
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        msplat_set_exact_execution_capacity_for_testing(2048);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats overflow = msplat_get_raster_stats();
        if (!overflow.capacity_exceeded || overflow.latest_intersection_count == 0) {
            throw std::runtime_error(
                "shared allocation fixture did not establish prior raster evidence"
            );
        }

        msplat_set_raster_memory_budget_for_testing(1);
        bool rejected = false;
        try {
            (void)gpu_empty({4096}, DType::Float32);
        } catch (const std::exception &) {
            rejected = true;
        }
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (!rejected || !stats.memory_budget_exceeded ||
            !msplat_raster_memory_budget_was_exceeded() ||
            stats.resource_limit_exceeded || stats.required_bytes <= stats.budget_bytes ||
            stats.latest_intersection_count != 0) {
            throw std::runtime_error(
                "shared Metal allocation inherited stale raster evidence"
            );
        }
    }
    cleanup_msplat_metal();
    std::cout << "shared_allocation_budget passed\n";
}

std::uint64_t primeExactWorkspace(
    Model &model,
    Camera &camera,
    int probeIteration,
    std::size_t cameraIndex
) {
    msplat_set_exact_execution_capacity_for_testing(2048);
    enqueueStep(model, camera, probeIteration, cameraIndex);
    msplat_gpu_sync_for_raster_replay();
    const MsplatRasterStats stats = msplat_get_raster_stats();
    if (!stats.capacity_exceeded || stats.memory_budget_exceeded ||
        stats.first_overflow_iteration != static_cast<std::uint64_t>(probeIteration) ||
        stats.first_overflow_camera != cameraIndex ||
        stats.latest_intersection_count == 0) {
        throw std::runtime_error(
            "exact workspace probe did not produce recoverable evidence: failed=" +
            std::to_string(stats.capacity_exceeded) + " memory=" +
            std::to_string(stats.memory_budget_exceeded) + " iteration=" +
            std::to_string(stats.first_overflow_iteration) + " camera=" +
            std::to_string(stats.first_overflow_camera) + " actual=" +
            std::to_string(stats.latest_intersection_count)
        );
    }
    model.adam_step_count = 0;
    model.schedulersStep(0);
    msplat_grow_exact_raster_capacity(stats.latest_intersection_count);
    msplat_clear_raster_capacity_failure();
    return stats.latest_intersection_count;
}

ModelSnapshot runSingleCameraWindow(
    const std::string &dataset,
    int overflowIteration,
    int cancelReplayAfter
) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    msplat_set_geometry_adam_fusion_enabled_for_testing(true);

    ModelSnapshot snapshot;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty()) {
            throw std::runtime_error("replay fixture has no camera");
        }
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        const std::uint64_t exactIntersections = primeExactWorkspace(model, camera, 1, 0);
        if (exactIntersections <= 2048) {
            throw std::runtime_error("replay fixture does not exceed the forced exact capacity");
        }

        constexpr int windowEnd = 100;
        for (int step = 1; step <= windowEnd; ++step) {
            if (step == overflowIteration) {
                msplat_set_exact_execution_capacity_for_testing(2048);
            }
            enqueueStep(model, camera, step, 0);
        }
        msplat_gpu_sync_for_raster_replay();

        if (overflowIteration > 0) {
            const MsplatRasterStats overflow = msplat_get_raster_stats();
            if (!overflow.capacity_exceeded || overflow.memory_budget_exceeded ||
                overflow.first_overflow_iteration !=
                    static_cast<std::uint64_t>(overflowIteration) ||
                overflow.first_overflow_camera != 0 ||
                overflow.latest_intersection_count != exactIntersections) {
                throw std::runtime_error("window overflow was not attributed to its first iteration");
            }
            const int successfulPrefix = overflowIteration - 1;
            model.adam_step_count = successfulPrefix;
            model.schedulersStep(successfulPrefix);
            msplat_grow_exact_raster_capacity(overflow.latest_intersection_count);
            msplat_clear_raster_capacity_failure();

            const int replayEnd = cancelReplayAfter > 0
                ? std::min(windowEnd, overflowIteration + cancelReplayAfter - 1)
                : windowEnd;
            for (int step = overflowIteration; step <= replayEnd; ++step) {
                enqueueStep(model, camera, step, 0);
            }
            msplat_gpu_sync_for_raster_replay();
            const MsplatRasterStats replayed = msplat_get_raster_stats();
            if (replayed.capacity_exceeded || replayed.memory_budget_exceeded ||
                replayed.dropped_intersection_count != 0 ||
                replayed.fallback_count != static_cast<std::uint64_t>(replayEnd)) {
                throw std::runtime_error("window replay did not commit an exact prefix");
            }
        }
        snapshot = snapshotModel(model);
    }
    cleanup_msplat_metal();
    return snapshot;
}

void verifyWindowReplayNumericalParity(const std::string &dataset) {
    const ModelSnapshot reference = runSingleCameraWindow(dataset, 0, 0);
    for (int overflowIteration : {1, 50, 100}) {
        const ModelSnapshot replayed = runSingleCameraWindow(dataset, overflowIteration, 0);
        requireModelNear(
            "replay_iteration_" + std::to_string(overflowIteration),
            reference,
            replayed
        );
    }

    constexpr int cancelledReplayLength = 37;
    // A stopped replay must remain numerically equivalent after the same number
    // of committed exact iterations.
    // Run the short reference directly so cancellation cannot accidentally retain
    // any guarded optimizer work from the original 100-step attempt.
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    msplat_set_geometry_adam_fusion_enabled_for_testing(true);
    ModelSnapshot shortReference;
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        (void)primeExactWorkspace(model, camera, 1, 0);
        for (int step = 1; step <= cancelledReplayLength; ++step) {
            enqueueStep(model, camera, step, 0);
        }
        msplat_gpu_sync_for_raster_replay();
        shortReference = snapshotModel(model);
    }
    cleanup_msplat_metal();
    const ModelSnapshot cancelled = runSingleCameraWindow(
        dataset,
        1,
        cancelledReplayLength
    );
    requireModelNear("cancelled_replay_prefix", shortReference, cancelled);
    std::cout << "window_replay_numerical_parity passed\n";
}

void verifyRepeatedExactFallbackMetrics(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    const std::vector<std::tuple<std::uint64_t, double, std::uint64_t,
                                 std::uint64_t, std::uint64_t>> invalidHistory {
        {0, 0.1, 0, 0, 0},
        {1, 0.0, 0, 0, 0},
        {1, 0.1, 0, 0, 0},
        {1, 0.1, 1, 0, 2304},
        {1, 0.1, 1, 4096, 2048},
        {1, 0.1, 2, 4096, 2304},
        {1, 0.1, 1, memoryBudgetBytes + 1, 2304},
        {1, 0.1, 1, 4096, std::uint64_t {1} << 32},
    };
    for (const auto &[fallbacks, elapsed, growths, bytes, peak] : invalidHistory) {
        bool rejected = false;
        try {
            msplat_restore_raster_metrics(fallbacks, elapsed, growths, bytes, peak);
        } catch (const std::invalid_argument &) {
            rejected = true;
        }
        if (!rejected) {
            throw std::runtime_error("native raster restore accepted inconsistent history");
        }
    }
    msplat_restore_raster_metrics(3, 0.1, 2, memoryBudgetBytes + 1, 2304);
    const MsplatRasterStats restored = msplat_get_raster_stats();
    if (restored.fallback_count != 3 || restored.exact_fallback_elapsed_seconds != 0.1 ||
        restored.exact_buffer_growth_count != 2 ||
        restored.exact_buffer_bytes_added != memoryBudgetBytes + 1 ||
        restored.peak_exact_intersection_capacity != 2304) {
        throw std::runtime_error("native raster restore rejected consistent history");
    }
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);

    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty()) {
            throw std::runtime_error("repeated exact-fallback fixture has no camera");
        }
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        const std::uint64_t intersections = primeExactWorkspace(model, camera, 1, 0);
        const MsplatRasterStats grown = msplat_get_raster_stats();
        const std::uint64_t expectedHeadroom = geometricCapacity(intersections);
        if (grown.exact_buffer_growth_count != 1 ||
            grown.exact_buffer_bytes_added == 0 ||
            grown.peak_exact_intersection_capacity != expectedHeadroom) {
            throw std::runtime_error("exact buffer growth did not reserve geometric headroom");
        }

        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats first = msplat_get_raster_stats();
        enqueueStep(model, camera, 2, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats second = msplat_get_raster_stats();

        if (second.fallback_count != 2 ||
            second.exact_buffer_growth_count != 1 ||
            second.exact_buffer_bytes_added != grown.exact_buffer_bytes_added ||
            second.peak_exact_intersection_capacity != grown.peak_exact_intersection_capacity ||
            second.exact_fallback_elapsed_seconds <= 0 ||
            second.exact_fallback_elapsed_seconds < first.exact_fallback_elapsed_seconds) {
            throw std::runtime_error(
                "repeated exact dispatches were confused with buffer allocations"
            );
        }

        msplat_grow_exact_raster_capacity(intersections);
        const MsplatRasterStats cached = msplat_get_raster_stats();
        if (cached.exact_buffer_growth_count != 1 ||
            cached.exact_buffer_bytes_added != grown.exact_buffer_bytes_added) {
            throw std::runtime_error("cached exact capacity was counted as new growth");
        }
    }

    cleanup_msplat_metal();
    std::cout << "repeated_exact_fallback_metrics passed\n";
}

void verifyRestoredExactCapacity(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);

    MsplatRasterStats durable {};
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        (void)primeExactWorkspace(model, camera, 1, 0);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        durable = msplat_get_raster_stats();
        if (durable.fallback_count != 1 || durable.exact_buffer_growth_count != 1 ||
            durable.peak_exact_intersection_capacity <= 2048) {
            throw std::runtime_error("restored-capacity fixture has no durable exact history");
        }
    }

    const std::uint64_t persistedCapacity = durable.latest_intersection_count;
    if (persistedCapacity <= 2048 || geometricCapacity(persistedCapacity) == persistedCapacity) {
        throw std::runtime_error(
            "restored-capacity fixture did not produce a non-geometric durable capacity"
        );
    }

    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_restore_raster_metrics(
        durable.fallback_count,
        durable.exact_fallback_elapsed_seconds,
        durable.exact_buffer_growth_count,
        durable.exact_buffer_bytes_added,
        persistedCapacity
    );
    msplat_set_force_exact_for_testing(true);
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        msplat_preflight_raster_memory(
            model.num_active,
            camera.height,
            camera.width,
            static_cast<int>(model.featuresRest.size(-2))
        );
        msplat_restore_exact_raster_capacity(persistedCapacity);

        const MsplatRasterStats restored = msplat_get_raster_stats();
        if (restored.memory_budget_exceeded || restored.resource_limit_exceeded ||
            restored.required_bytes > restored.budget_bytes ||
            restored.exact_buffer_growth_count != durable.exact_buffer_growth_count ||
            restored.exact_buffer_bytes_added != durable.exact_buffer_bytes_added ||
            restored.peak_exact_intersection_capacity != persistedCapacity) {
            throw std::runtime_error("restored exact capacity changed durable history");
        }

        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats resumed = msplat_get_raster_stats();
        if (resumed.capacity_exceeded || resumed.dropped_intersection_count != 0 ||
            resumed.fallback_count != durable.fallback_count + 1 ||
            resumed.exact_buffer_growth_count != durable.exact_buffer_growth_count ||
            resumed.exact_buffer_bytes_added != durable.exact_buffer_bytes_added ||
            resumed.peak_exact_intersection_capacity != persistedCapacity) {
            throw std::runtime_error("restored exact capacity replayed or changed history");
        }
    }
    cleanup_msplat_metal();
    std::cout << "restored_exact_capacity passed\n";
}

void verifyQueuedExactFallbackTiming(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);

    double wallSeconds = 0;
    double exactSeconds = 0;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty()) {
            throw std::runtime_error("queued-timing fixture has no camera");
        }
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        (void)primeExactWorkspace(model, camera, 1, 0);

        constexpr int batchSize = 100;
        const auto started = std::chrono::steady_clock::now();
        for (int step = 1; step <= batchSize; ++step) {
            enqueueStep(model, camera, step, 0);
        }
        msplat_gpu_sync_for_raster_replay();
        wallSeconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - started
        ).count();
        const MsplatRasterStats stats = msplat_get_raster_stats();
        exactSeconds = stats.exact_fallback_elapsed_seconds;
        if (stats.fallback_count != batchSize || !std::isfinite(exactSeconds) ||
            exactSeconds <= 0 || exactSeconds > wallSeconds + 1.0e-6) {
            throw std::runtime_error(
                "queued exact GPU timing exceeded its enclosing wall time: exact=" +
                std::to_string(exactSeconds) + " wall=" + std::to_string(wallSeconds)
            );
        }
    }

    cleanup_msplat_metal();
    std::cout << "queued_exact_gpu_seconds=" << exactSeconds
              << " wall_seconds=" << wallSeconds
              << " queued_exact_timing passed\n";
}

void verifySyncFailureDrainsTimingHandlers(const std::string &dataset) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);

    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty()) {
            throw std::runtime_error("sync-failure fixture has no camera");
        }
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        (void)primeExactWorkspace(model, camera, 1, 0);

        msplat_fail_next_sync_for_testing();
        enqueueStep(model, camera, 1, 0);
        if (msplat_pending_exact_raster_timing_handlers_for_testing() == 0) {
            throw std::runtime_error(
                "sync-failure fixture did not queue an exact-raster timing handler"
            );
        }
        bool syncRejected = false;
        try {
            msplat_gpu_sync_for_raster_replay();
        } catch (const std::runtime_error &error) {
            syncRejected = std::string(error.what()).find("injected sync failure") !=
                std::string::npos;
        }
        if (!syncRejected ||
            msplat_pending_exact_raster_timing_handlers_for_testing() != 0) {
            throw std::runtime_error(
                "sync failure escaped before exact-raster timing handlers drained"
            );
        }

        msplat_fail_next_sync_for_testing();
        enqueueStep(model, camera, 2, 0);
        if (msplat_pending_exact_raster_timing_handlers_for_testing() == 0) {
            throw std::runtime_error(
                "cleanup fixture did not queue an exact-raster timing handler"
            );
        }
        bool cleanupRejected = false;
        try {
            cleanup_msplat_metal();
        } catch (const std::runtime_error &error) {
            cleanupRejected = std::string(error.what()).find("injected sync failure") !=
                std::string::npos;
        }
        const MsplatRasterStats reset = msplat_get_raster_stats();
        if (!cleanupRejected ||
            msplat_pending_exact_raster_timing_handlers_for_testing() != 0 ||
            reset.fallback_count != 0 ||
            reset.exact_fallback_elapsed_seconds != 0 ||
            reset.exact_buffer_growth_count != 0 ||
            reset.exact_buffer_bytes_added != 0 ||
            reset.peak_exact_intersection_capacity != 0) {
            throw std::runtime_error(
                "cleanup failure did not drain handlers and reset exact-raster state"
            );
        }
    }

    // A failed cleanup must leave the next lifecycle usable.
    cleanup_msplat_metal();
    std::cout << "sync_failure_timing_lifecycle passed\n";
}

ModelSnapshot runIncreasingWindow(const std::string &dataset, bool replay) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    msplat_set_geometry_adam_fusion_enabled_for_testing(true);

    ModelSnapshot snapshot;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.size() != 2) {
            throw std::runtime_error("increasing-overflow fixture must have two cameras");
        }
        Model model = makeModel(inputData);
        constexpr int windowEnd = 100;
        constexpr int secondCameraStep = 50;

        if (!replay) {
            const std::uint64_t first = primeExactWorkspace(model, inputData.cameras[0], 1, 0);
            const std::uint64_t second = primeExactWorkspace(
                model,
                inputData.cameras[1],
                secondCameraStep,
                1
            );
            if (second <= first || geometricCapacity(second) <= geometricCapacity(first)) {
                throw std::runtime_error(
                    "increasing-overflow fixture does not cross a geometric bucket"
                );
            }
        }

        int replayStart = 1;
        std::vector<std::uint64_t> growths;
        while (true) {
            for (int step = replayStart; step <= windowEnd; ++step) {
                const std::size_t cameraIndex = step < secondCameraStep ? 0 : 1;
                enqueueStep(model, inputData.cameras[cameraIndex], step, cameraIndex);
            }
            msplat_gpu_sync_for_raster_replay();
            const MsplatRasterStats stats = msplat_get_raster_stats();
            if (!stats.capacity_exceeded) break;
            if (stats.memory_budget_exceeded || stats.first_overflow_iteration == 0 ||
                stats.first_overflow_iteration > windowEnd ||
                stats.latest_intersection_count == 0) {
                throw std::runtime_error("increasing replay produced invalid overflow evidence");
            }
            const int firstOverflow = static_cast<int>(stats.first_overflow_iteration);
            model.adam_step_count = firstOverflow - 1;
            model.schedulersStep(firstOverflow - 1);
            growths.push_back(stats.latest_intersection_count);
            msplat_grow_exact_raster_capacity(stats.latest_intersection_count);
            msplat_clear_raster_capacity_failure();
            replayStart = firstOverflow;
        }
        if (replay && (growths.size() != 2 || growths[1] <= growths[0])) {
            throw std::runtime_error(
                "window replay did not perform two geometric bucket grows"
            );
        }
        const MsplatRasterStats completed = msplat_get_raster_stats();
        if (completed.capacity_exceeded || completed.memory_budget_exceeded ||
            completed.dropped_intersection_count != 0 || completed.fallback_count != windowEnd) {
            throw std::runtime_error("increasing window did not finish losslessly");
        }
        snapshot = snapshotModel(model);
    }
    cleanup_msplat_metal();
    return snapshot;
}

void verifyIncreasingWindowReplay(const std::string &dataset) {
    const ModelSnapshot reference = runIncreasingWindow(dataset, false);
    const ModelSnapshot replayed = runIncreasingWindow(dataset, true);
    requireModelNear("increasing_window_replay", reference, replayed);
    std::cout << "increasing_window_replay passed\n";
}

void verifyGPUCapacityFailure(const std::string &dataset) {
    auto probe = [&](std::uint64_t budget) {
        cleanup_msplat_metal();
        msplat_set_raster_memory_budget_bytes(budget);
        msplat_set_raster_fallback_count(0);
        msplat_set_force_exact_for_testing(true);
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        makeBroadSplats(model);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (!stats.capacity_exceeded || stats.memory_budget_exceeded ||
            stats.resource_limit_exceeded || stats.latest_intersection_count <= 2048 ||
            stats.dropped_intersection_count != 0 ||
            stats.first_overflow_iteration != 1 || stats.first_overflow_camera != 0) {
            throw std::runtime_error(
                std::string("GPU raster-capacity probe lost authoritative evidence:") +
                " intersections=" + std::to_string(stats.latest_intersection_count) +
                " allocation=" + std::to_string(stats.allocation_bytes) +
                " required=" + std::to_string(stats.required_bytes) +
                " budget=" + std::to_string(stats.budget_bytes)
            );
        }
        return stats;
    };

    const MsplatRasterStats initialFailure = probe(memoryBudgetBytes);
    const std::uint64_t intersections = initialFailure.latest_intersection_count;

    auto growProbe = [&](bool clampToObserved, std::uint64_t budgetOverride) {
        cleanup_msplat_metal();
        msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
        msplat_set_raster_fallback_count(0);
        msplat_set_force_exact_for_testing(true);
        if (clampToObserved) {
            msplat_set_exact_capacity_limit_for_testing(intersections);
        }
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        makeBroadSplats(model);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats overflow = msplat_get_raster_stats();
        if (!overflow.capacity_exceeded || overflow.latest_intersection_count != intersections) {
            throw std::runtime_error("geometric budget probe changed the intersection count");
        }
        if (budgetOverride != 0) {
            msplat_set_raster_memory_budget_for_testing(budgetOverride);
        }
        msplat_grow_exact_raster_capacity(intersections);
        return msplat_get_raster_stats();
    };

    const MsplatRasterStats minimumGrowth = growProbe(true, 0);
    const MsplatRasterStats geometricGrowth = growProbe(false, 0);
    if (minimumGrowth.peak_exact_intersection_capacity != intersections ||
        geometricGrowth.peak_exact_intersection_capacity != geometricCapacity(intersections) ||
        geometricGrowth.required_bytes <= minimumGrowth.required_bytes) {
        throw std::runtime_error("geometric budget probe did not create distinct capacities");
    }
    const std::uint64_t tightBudget = minimumGrowth.required_bytes +
        (geometricGrowth.required_bytes - minimumGrowth.required_bytes) / 4;
    const MsplatRasterStats tightGrowth = growProbe(false, tightBudget);
    if (tightGrowth.memory_budget_exceeded || tightGrowth.resource_limit_exceeded ||
        msplat_raster_memory_budget_was_exceeded() ||
        msplat_raster_resource_limit_was_exceeded() ||
        tightGrowth.required_bytes > tightGrowth.budget_bytes ||
        tightGrowth.peak_exact_intersection_capacity != intersections) {
        throw std::runtime_error(
            "geometric headroom did not fall back to the minimum fitting capacity"
        );
    }

    // A device buffer limit is distinct from memory pressure. Make the exact
    // growth fail after the GPU count so the typed evidence is authoritative.
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    msplat_set_exact_capacity_limit_for_testing(intersections - 1);
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        makeBroadSplats(model);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        bool rejected = false;
        try {
            msplat_grow_exact_raster_capacity(intersections);
        } catch (const std::exception &) {
            rejected = true;
        }
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (!rejected || !stats.resource_limit_exceeded ||
            !msplat_raster_resource_limit_was_exceeded() ||
            stats.memory_budget_exceeded || stats.max_buffer_bytes == 0 ||
            stats.required_bytes <= stats.max_buffer_bytes ||
            stats.latest_intersection_count != intersections ||
            stats.dropped_intersection_count != 0) {
            throw std::runtime_error("exact growth did not report a typed resource limit");
        }
    }

    // The same observed count must report a typed budget failure when the
    // resolved training budget cannot hold the dynamically sized buffers.
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        makeBroadSplats(model);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats overflow = msplat_get_raster_stats();
        if (!overflow.capacity_exceeded || overflow.latest_intersection_count != intersections) {
            throw std::runtime_error("memory-limit probe changed the observed intersection count");
        }
        msplat_set_raster_memory_budget_for_testing(1);
        bool rejected = false;
        try {
            msplat_grow_exact_raster_capacity(intersections);
        } catch (const std::exception &) {
            rejected = true;
        }
        const MsplatRasterStats stats = msplat_get_raster_stats();
        if (!rejected || !stats.memory_budget_exceeded ||
            !msplat_raster_memory_budget_was_exceeded() ||
            stats.resource_limit_exceeded || stats.required_bytes <= stats.budget_bytes ||
            stats.latest_intersection_count != intersections ||
            stats.dropped_intersection_count != 0) {
            throw std::runtime_error("exact growth did not report a typed memory limit");
        }
    }

    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
    {
        InputData inputData = inputDataFromX(dataset);
        Camera &camera = inputData.cameras.front();
        Model model = makeModel(inputData);
        makeBroadSplats(model);
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync_for_raster_replay();
        const MsplatRasterStats overflow = msplat_get_raster_stats();
        if (!overflow.capacity_exceeded || overflow.memory_budget_exceeded ||
            overflow.latest_intersection_count /
                    static_cast<std::uint64_t>(model.num_active) <= 32) {
            throw std::runtime_error(
                "broad-splat fixture did not exceed 32 tiles per Gaussian: actual=" +
                std::to_string(overflow.latest_intersection_count) + " points=" +
                std::to_string(model.num_active) + " failed=" +
                std::to_string(overflow.capacity_exceeded)
            );
        }
        model.adam_step_count = 0;
        model.schedulersStep(0);
        msplat_grow_exact_raster_capacity(overflow.latest_intersection_count);
        msplat_clear_raster_capacity_failure();
        enqueueStep(model, camera, 1, 0);
        msplat_gpu_sync();
        const MsplatRasterStats completed = msplat_get_raster_stats();
        if (completed.capacity_exceeded || completed.memory_budget_exceeded ||
            completed.dropped_intersection_count != 0 || completed.fallback_count != 1) {
            throw std::runtime_error("broad-splat exact growth did not finish losslessly");
        }
    }
    cleanup_msplat_metal();
    std::cout << "gpu_capacity_failure passed\n";
}

void verifyStageTiming(const std::string &dataset) {
    verifyTimestampMath();
    cleanup_msplat_metal();
    msplat_set_geometry_adam_fusion_enabled_for_testing(true);
    msplat_enable_gpu_timing(true);
    msplat_enable_stage_profiling_for_testing();

    const MsplatStageProfilingStatus profilingStatus =
        msplat_stage_profiling_status_for_testing();
    if (profilingStatus == MSPLAT_STAGE_PROFILING_UNAVAILABLE) {
        cleanup_msplat_metal();
        std::cout << "msplat stage timing skipped: Metal timestamp counters unavailable\n";
        return;
    }
    if (profilingStatus != MSPLAT_STAGE_PROFILING_AVAILABLE) {
        throw std::runtime_error("runtime GPU stage profiler initialization failed");
    }

    const MsplatGpuTimestampCalibration calibration =
        msplat_gpu_timestamp_calibration_for_testing();
    if (!std::isfinite(calibration.frequency_hz) || calibration.frequency_hz <= 0 ||
        !std::isfinite(calibration.reference_frequency_hz) ||
        calibration.reference_frequency_hz <= 0 ||
        calibration.sample_count == 0 || calibration.method == 0) {
        throw std::runtime_error("runtime GPU timestamp calibration is invalid");
    }

    std::vector<double> discardedGpuTimes;
    msplat_drain_gpu_times(discardedGpuTimes);
    std::vector<double> discardedStageTimes[8];
    const char *discardedStageNames[8] {};
    int discardedStageCount = 0;
    msplat_drain_stage_times(
        discardedStageTimes,
        8,
        discardedStageCount,
        discardedStageNames
    );

    double wallMilliseconds = 0;
    {
        InputData inputData = inputDataFromX(dataset);
        if (inputData.cameras.empty() || inputData.points.count <= 0) {
            throw std::runtime_error("stage timing fixture has no camera or sparse points");
        }
        Camera &camera = inputData.cameras.front();
        camera.loadImage(1.0f);
        if (camera.image.empty()) {
            throw std::runtime_error("stage timing fixture image did not decode");
        }
        Model model = makeModel(inputData);
        MTensor target = camera.getGPUImage(1);
        msplat_commit();
        msplat_gpu_sync();
        msplat_drain_gpu_times(discardedGpuTimes);

        const auto started = std::chrono::steady_clock::now();
        for (int step = 1; step <= stageTimingIterations; ++step) {
            model.fullIteration(camera, step, target, 0.2f);
            model.schedulersStep(step);
            msplat_commit();
            // The profiler reuses one counter-sample buffer. Synchronizing each
            // iteration keeps every resolve paired with the command buffer that
            // wrote it, which makes this an absolute-timing validation rather
            // than a throughput benchmark.
            msplat_gpu_sync();
        }
        wallMilliseconds = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started
        ).count();
    }

    std::vector<double> gpuTimes;
    msplat_drain_gpu_times(gpuTimes);
    if (gpuTimes.size() != stageTimingIterations) {
        throw std::runtime_error(
            "stage timing fixture expected " + std::to_string(stageTimingIterations) +
            " command-buffer samples, got " + std::to_string(gpuTimes.size())
        );
    }

    std::vector<double> stageTimes[8];
    const char *stageNames[8] {};
    int stageCount = 0;
    msplat_drain_stage_times(stageTimes, 8, stageCount, stageNames);
    if (stageCount != 8 || !stageTimes[0].empty()) {
        throw std::runtime_error("stage timing fixture reported an invalid stage layout");
    }

    double stageMilliseconds = 0;
    for (int stage = 1; stage < stageCount; ++stage) {
        if (stageNames[stage] == nullptr || stageTimes[stage].size() != stageTimingIterations) {
            throw std::runtime_error(
                "stage timing fixture did not report every iteration for stage " +
                std::to_string(stage)
            );
        }
        for (double duration : stageTimes[stage]) {
            if (!std::isfinite(duration) || duration < 0) {
                throw std::runtime_error("stage timing fixture reported an invalid duration");
            }
            stageMilliseconds += duration;
        }
    }
    double gpuMilliseconds = 0;
    for (double duration : gpuTimes) {
        if (!std::isfinite(duration) || duration < 0) {
            throw std::runtime_error("command-buffer timing reported an invalid duration");
        }
        gpuMilliseconds += duration;
    }
    if (stageMilliseconds <= 0 || gpuMilliseconds <= 0 || wallMilliseconds <= 0) {
        throw std::runtime_error("stage timing fixture reported an empty duration");
    }

    // All seven measured compute encoders execute serially on each command
    // buffer. Their sum excludes the blit encoder and inter-encoder overhead,
    // so it cannot materially exceed either total command-buffer GPU time or
    // synchronized wall time. The aggregate gate also rejects an implausibly
    // small stage total after first-use overhead has been amortized.
    constexpr double aggregationTolerance = 1.05;
    if (!msplat_stage_timing_aggregate_coherent_for_testing(
            stageMilliseconds,
            gpuMilliseconds
        ) ||
        stageMilliseconds > wallMilliseconds * aggregationTolerance ||
        gpuMilliseconds > wallMilliseconds * aggregationTolerance) {
        throw std::runtime_error(
            "stage timing is incoherent: stages=" + std::to_string(stageMilliseconds) +
            "ms gpu=" + std::to_string(gpuMilliseconds) +
            "ms wall=" + std::to_string(wallMilliseconds) + "ms"
        );
    }

    std::cout << "gpu_timestamp_frequency_hz=" << calibration.frequency_hz
              << " reference_frequency_hz=" << calibration.reference_frequency_hz
              << " calibration_method=" << calibration.method
              << " calibration_samples=" << calibration.sample_count << '\n';
    std::cout << "stage_profile_iterations=" << stageTimingIterations
              << " stage_ms=" << stageMilliseconds
              << " gpu_ms=" << gpuMilliseconds
              << " wall_ms=" << wallMilliseconds << '\n';
    cleanup_msplat_metal();
    std::cout << "msplat stage timing passed\n";
}

} // namespace

int main(int argc, char **argv) {
    try {
        verifyExactRadixPassPlanning();
        if (argc == 2 && std::string(argv[1]) == "--prefix-oracle") {
            verifyExactPrefixOracle();
            return 0;
        }
        if (argc == 2 && std::string(argv[1]) == "--radix-oracle") {
            verifyExactRadixOracle();
            return 0;
        }
        if (argc == 2 && std::string(argv[1]) == "--quaternion-vjp") {
            verifyQuaternionVJP();
            return 0;
        }
        if (argc == 3 && std::string(argv[1]) == "--geometry-adam-benchmark") {
            benchmarkGeometryAdamFusion(argv[2]);
            return 0;
        }
        if (argc == 3 && std::string(argv[1]) == "--stage-timing") {
            verifyStageTiming(argv[2]);
            return 0;
        }
        if (argc == 3 && std::string(argv[1]) == "--overflow-cpu-reference") {
            verifyOverflowCPUReference(argv[2]);
            return 0;
        }
        if (argc != 7) {
            throw std::runtime_error(
                "usage: msplat-raster-tests <parity dataset> <mixed-resolution dataset> "
                "<overflow dataset> <broad-overflow dataset> "
                "<increasing-overflow dataset> <exact-budget dataset>\n"
                "       msplat-raster-tests --prefix-oracle\n"
                "       msplat-raster-tests --radix-oracle\n"
                "       msplat-raster-tests --quaternion-vjp\n"
                "       msplat-raster-tests --overflow-cpu-reference <overflow dataset>\n"
                "       msplat-raster-tests --stage-timing <profile dataset>\n"
                "       msplat-raster-tests --geometry-adam-benchmark <dataset>"
            );
        }
        const std::string dataset = argv[1];
        const RasterResult fast = runSingleStep(dataset, false);
        const RasterResult exact = runSingleStep(dataset, true);
        if (fast.stats.fallback_count != 0 || exact.stats.fallback_count != 1 ||
            fast.stats.dropped_intersection_count != 0 ||
            exact.stats.dropped_intersection_count != 0) {
            throw std::runtime_error("forced-exact test did not exercise the intended routes");
        }

        requireNear("forward_rgb", fast.rgb, exact.rgb);
        requireNear("forward_alpha", fast.alpha, exact.alpha);
        requireNear("position_gradients", fast.positionGradients, exact.positionGradients);
        requireNear("color_gradients", fast.colorGradients, exact.colorGradients);
        requireNear("opacity_gradients", fast.opacityGradients, exact.opacityGradients);
        requireNear("position_parameters", fast.positions, exact.positions);
        requireNear("color_parameters", fast.colors, exact.colors);
        requireNear("opacity_parameters", fast.opacities, exact.opacities);
        requireNear("position_first_moment", fast.positionFirstMoment, exact.positionFirstMoment);
        requireNear("position_second_moment", fast.positionSecondMoment, exact.positionSecondMoment);
        requireNear("color_first_moment", fast.colorFirstMoment, exact.colorFirstMoment);
        requireNear("color_second_moment", fast.colorSecondMoment, exact.colorSecondMoment);
        requireNear("opacity_first_moment", fast.opacityFirstMoment, exact.opacityFirstMoment);
        requireNear("opacity_second_moment", fast.opacitySecondMoment, exact.opacitySecondMoment);

        verifyPartialThreadgroupLossAccounting(dataset);

        const RasterResult culledFast = runSingleStep(dataset, false, true);
        const RasterResult culledExact = runSingleStep(dataset, true, true);
        if (culledFast.stats.fallback_count != 0 ||
            culledExact.stats.fallback_count != 1 ||
            culledFast.stats.dropped_intersection_count != 0 ||
            culledExact.stats.dropped_intersection_count != 0) {
            throw std::runtime_error(
                "tile-span test did not exercise both raster routes"
            );
        }
        requireNear("culled_fast_exact_rgb", culledFast.rgb, culledExact.rgb);
        requireNear("culled_fast_exact_alpha", culledFast.alpha, culledExact.alpha);
        requireNear(
            "culled_fast_exact_position_gradients",
            culledFast.positionGradients,
            culledExact.positionGradients
        );
        requireNear(
            "culled_fast_exact_color_gradients",
            culledFast.colorGradients,
            culledExact.colorGradients
        );
        requireNear(
            "culled_fast_exact_opacity_gradients",
            culledFast.opacityGradients,
            culledExact.opacityGradients
        );
        requireNear("culled_baseline_rgb", fast.rgb, culledFast.rgb);
        requireNear("culled_baseline_alpha", fast.alpha, culledFast.alpha);
        requireNear("culled_baseline_positions", fast.positions, culledFast.positions);
        requireNear("culled_baseline_colors", fast.colors, culledFast.colors);
        requireNear("culled_baseline_opacities", fast.opacities, culledFast.opacities);
        if (exact.stats.latest_intersection_count == 0 ||
            culledExact.stats.latest_intersection_count == 0 ||
            culledExact.stats.latest_intersection_count * 100 >=
                exact.stats.latest_intersection_count * 95) {
            throw std::runtime_error(
                "tile-span culling did not reduce exact intersections by five percent: baseline=" +
                std::to_string(exact.stats.latest_intersection_count) +
                " candidate=" +
                std::to_string(culledExact.stats.latest_intersection_count)
            );
        }
        std::cout << "tile_span_intersections baseline="
                  << exact.stats.latest_intersection_count
                  << " candidate=" << culledExact.stats.latest_intersection_count
                  << '\n';

        verifyOverflowCPUReference(argv[3]);

        std::vector<double> disabledSamples;
        std::vector<double> enabledSamples;
        for (int sample = 0; sample < 3; ++sample) {
            disabledSamples.push_back(benchmarkCommonPath(dataset, false));
            enabledSamples.push_back(benchmarkCommonPath(dataset, true));
        }
        const double disabledMedian = median(disabledSamples);
        const double enabledMedian = median(enabledSamples);
        const double allowed = disabledMedian * 1.10 + 0.010;
        std::cout << "common_path_disabled_seconds=" << disabledMedian
                  << " enabled_seconds=" << enabledMedian
                  << " allowed_seconds=" << allowed << '\n';
        if (enabledMedian > allowed) {
            throw std::runtime_error("zero-group exact dispatch materially slowed the common path");
        }
        verifyGeometryAdamFusionParity(argv[2]);
        verifyDensificationScratchLifecycle(dataset);
        verifyMixedResolutionGrowth(argv[2]);
        verifyExactOnlyBudgetEvidence(argv[6]);
        verifySharedAllocationBudget(argv[3]);
        verifyRepeatedExactFallbackMetrics(argv[3]);
        verifyRestoredExactCapacity(argv[3]);
        verifyQueuedExactFallbackTiming(argv[3]);
        verifySyncFailureDrainsTimingHandlers(argv[3]);
        verifyWindowReplayNumericalParity(argv[3]);
        verifyGPUCapacityFailure(argv[4]);
        verifyIncreasingWindowReplay(argv[5]);
        std::cout << "msplat raster parity passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "msplat-raster-tests: " << error.what() << '\n';
        return 1;
    }
}
