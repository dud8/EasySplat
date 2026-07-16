#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "bindings.h"
#include "loaders.hpp"
#include "model.hpp"

namespace {

constexpr std::uint64_t memoryBudgetBytes = 512ULL * 1024ULL * 1024ULL;
constexpr float relativeTolerance = 2.0e-3f;
constexpr float absoluteTolerance = 2.0e-4f;
constexpr int stageTimingIterations = 512;

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
    if (!msplat_stage_timing_coherent_for_testing(0.95, 1.0) ||
        !msplat_stage_timing_coherent_for_testing(1.05, 1.0) ||
        msplat_stage_timing_coherent_for_testing(0.249, 1.0) ||
        msplat_stage_timing_coherent_for_testing(1.051, 1.0) ||
        msplat_stage_timing_coherent_for_testing(0.0, 1.0) ||
        msplat_stage_timing_coherent_for_testing(1.0, 0.0)) {
        throw std::runtime_error("GPU stage timing coherence bounds are invalid");
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
    MsplatRasterStats stats {};
};

struct ModelSnapshot {
    std::vector<float> positions;
    std::vector<float> colors;
    std::vector<float> opacities;
    std::vector<float> positionFirstMoment;
    std::vector<float> positionSecondMoment;
    std::vector<float> colorFirstMoment;
    std::vector<float> colorSecondMoment;
    std::vector<float> opacityFirstMoment;
    std::vector<float> opacitySecondMoment;
};

std::vector<float> copyTensor(const MTensor &tensor) {
    const float *values = tensor.data<float>();
    return std::vector<float>(values, values + tensor.numel());
}

Model makeModel(const InputData &inputData) {
    constexpr float background[3] = {0.0f, 0.0f, 0.0f};
    return Model(
        inputData,
        static_cast<int>(inputData.cameras.size()),
        0,
        3000,
        3,
        1000,
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

ModelSnapshot snapshotModel(const Model &model) {
    return ModelSnapshot {
        copyTensor(model.means),
        copyTensor(model.featuresDc),
        copyTensor(model.opacities),
        copyTensor(model.adam_exp_avg[0]),
        copyTensor(model.adam_exp_avg_sq[0]),
        copyTensor(model.adam_exp_avg[3]),
        copyTensor(model.adam_exp_avg_sq[3]),
        copyTensor(model.adam_exp_avg[5]),
        copyTensor(model.adam_exp_avg_sq[5]),
    };
}

void makeBroadSplats(Model &model) {
    float *scales = model.scales.data<float>();
    std::fill(scales, scales + model.scales.numel(), 0.0f);
}

RasterResult runSingleStep(const std::string &dataset, bool forceExact) {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(forceExact);

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
    requireNear(label + "_colors", reference.colors, candidate.colors);
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
        label + "_color_first_moment",
        reference.colorFirstMoment,
        candidate.colorFirstMoment
    );
    requireNear(
        label + "_color_second_moment",
        reference.colorSecondMoment,
        candidate.colorSecondMoment
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

void verifyDeterministicWindowReplay(const std::string &dataset) {
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
    // A stopped replay must match the same number of committed exact iterations.
    // Run the short reference directly so cancellation cannot accidentally retain
    // any guarded optimizer work from the original 100-step attempt.
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(memoryBudgetBytes);
    msplat_set_raster_fallback_count(0);
    msplat_set_force_exact_for_testing(true);
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
    std::cout << "deterministic_window_replay passed\n";
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
    msplat_enable_gpu_timing(true);
    msplat_enable_stage_profiling_for_testing();

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
    // synchronized wall time. Five percent accommodates timestamp sampling and
    // floating-point aggregation without hiding a clock-domain error.
    constexpr double aggregationTolerance = 1.05;
    if (stageMilliseconds > gpuMilliseconds * aggregationTolerance ||
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
        if (argc == 3 && std::string(argv[1]) == "--stage-timing") {
            verifyStageTiming(argv[2]);
            return 0;
        }
        if (argc != 7) {
            throw std::runtime_error(
                "usage: msplat-raster-tests <parity dataset> <mixed-resolution dataset> "
                "<overflow dataset> <broad-overflow dataset> "
                "<increasing-overflow dataset> <exact-budget dataset>\n"
                "       msplat-raster-tests --stage-timing <profile dataset>"
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
        verifyMixedResolutionGrowth(argv[2]);
        verifyExactOnlyBudgetEvidence(argv[6]);
        verifySharedAllocationBudget(argv[3]);
        verifyRepeatedExactFallbackMetrics(argv[3]);
        verifyRestoredExactCapacity(argv[3]);
        verifyQueuedExactFallbackTiming(argv[3]);
        verifySyncFailureDrainsTimingHandlers(argv[3]);
        verifyDeterministicWindowReplay(argv[3]);
        verifyGPUCapacityFailure(argv[4]);
        verifyIncreasingWindowReplay(argv[5]);
        std::cout << "msplat raster parity passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "msplat-raster-tests: " << error.what() << '\n';
        return 1;
    }
}
