#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "bindings.h"
#include "loaders.hpp"
#include "model.hpp"

namespace {

constexpr std::uint64_t memoryBudgetBytes = 512ULL * 1024ULL * 1024ULL;
constexpr float relativeTolerance = 2.0e-3f;
constexpr float absoluteTolerance = 2.0e-4f;

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

void verifySharedAllocationBudget() {
    cleanup_msplat_metal();
    msplat_set_raster_memory_budget_bytes(1);
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
            "shared Metal allocation bypassed the resolved training budget"
        );
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
            if (second <= first) {
                throw std::runtime_error("increasing-overflow fixture is not increasing");
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
            throw std::runtime_error("window replay did not perform two increasing exact grows");
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

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 7) {
            throw std::runtime_error(
                "usage: msplat-raster-tests <parity dataset> <mixed-resolution dataset> "
                "<overflow dataset> <broad-overflow dataset> "
                "<increasing-overflow dataset> <exact-budget dataset>"
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
        verifySharedAllocationBudget();
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
