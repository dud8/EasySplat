// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#ifndef EASYSPLAT_ISOLATION_RUNTIME_HPP
#define EASYSPLAT_ISOLATION_RUNTIME_HPP

#include "input_data.hpp"
#include "isolation.hpp"

#include <cstddef>
#include <filesystem>
#include <functional>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>

namespace easysplat::isolation {

struct IsolationRequest {
    std::filesystem::path sourcePly;
    std::filesystem::path maskManifest;
    std::filesystem::path analysisCache;
    std::filesystem::path output;
    std::string expectedSourcePlyDigest;
    std::string expectedInputDigest;
    std::string expectedGeometryDigest;
    std::string expectedSelectedFramesDigest;
    std::string expectedTrainingManifestDigest;
    std::size_t memoryBudgetBytes = 0;
    std::optional<Anchor> anchor;
};

enum class IsolationRunOutcome {
    completed,
    ambiguous,
    noSubject,
    heldOutRejected,
};

struct IsolationRunResult {
    IsolationRunOutcome outcome = IsolationRunOutcome::noSubject;
};

using IsolationEventEmitter = std::function<void(
    const std::string &event,
    nlohmann::json fields
)>;

IsolationRunResult runIsolation(
    const IsolationRequest &request,
    InputData &inputData,
    const IsolationEventEmitter &emit,
    const std::function<bool()> &isCancelled
);

} // namespace easysplat::isolation

#endif
