// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#ifndef EASYSPLAT_ISOLATION_HPP
#define EASYSPLAT_ISOLATION_HPP

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace easysplat::isolation {

inline constexpr std::size_t kNeighborCount = 16;
inline constexpr double kContributionFloor = static_cast<double>(0.04f);
inline constexpr double kViewAssignmentThreshold = 0.55;
inline constexpr double kForegroundThreshold = 0.65;
inline constexpr double kBackgroundThreshold = 0.35;
inline constexpr double kGraphAgreementThreshold = 0.60;
inline constexpr double kAutoSelectionCoverage = 0.60;
inline constexpr double kAutoSelectionLead = 0.15;
inline constexpr double kNoSubjectCoverage = 0.30;
inline constexpr double kMinimumRetainedFraction = 0.001;
inline constexpr double kMaximumRetainedFraction = 0.90;
inline constexpr double kHeldOutMedianIoU = 0.70;
inline constexpr double kHeldOutFirstQuartileIoU = 0.50;

class CancellationError : public std::runtime_error {
public:
    CancellationError() : std::runtime_error("subject isolation cancelled") {}
};

class MemoryLimitError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class PlyValidationError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class CacheValidationError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct Point3 {
    double x = 0;
    double y = 0;
    double z = 0;
};

struct WeightedPixelContribution {
    std::size_t gaussianIndex = 0;
    std::uint16_t label = 0;
    double alpha = 0;
    double transmittance = 0;
    double projectionCentrality = 0;
};

struct LiftedGaussian {
    std::vector<double> labelWeights;
    double centralityWeight = 0;
};

struct LiftedView {
    std::string identity;
    bool heldOut = false;
    std::vector<std::uint16_t> labels;
    std::vector<LiftedGaussian> gaussians;
};

LiftedView liftContributions(
    std::string identity,
    std::size_t gaussianCount,
    const std::vector<WeightedPixelContribution> &contributions
);

enum class GaussianClass {
    foreground,
    background,
    uncertain,
};

struct GaussianViewObservation {
    std::uint16_t assignedInstance = 0;
    double visibleWeight = 0;
    double foregroundWeight = 0;
    double assignedInstanceWeight = 0;
    double projectionCentrality = 0;
    bool sufficientlyObserved = false;
};

struct ReducedView {
    std::string identity;
    bool heldOut = false;
    std::vector<GaussianViewObservation> gaussians;
};

struct GaussianEvidence {
    GaussianClass classification = GaussianClass::uncertain;
    double foregroundProbability = 0;
    double backgroundViewFraction = 0;
    std::vector<GaussianViewObservation> observations;
};

ReducedView reduceLiftedView(const LiftedView &view);
std::vector<ReducedView> reduceLiftedViews(const std::vector<LiftedView> &views);

std::vector<GaussianEvidence> classifyGaussians(
    const std::vector<ReducedView> &views
);

using NeighborList = std::array<std::size_t, kNeighborCount>;

std::vector<NeighborList> deterministicNeighbors(
    const std::vector<Point3> &points
);

bool graphEdgeAllowed(
    double distance,
    double leftLocalDistance,
    double rightLocalDistance,
    const GaussianEvidence &left,
    const GaussianEvidence &right
);

double componentRankScore(
    double viewCoverage,
    double projectionCentrality,
    double visibleSupport
);

bool autoSelectionAllowed(
    double coverage,
    double lead,
    double retainedFraction
);

bool shouldPruneAsBackground(double backgroundViewFraction);

std::size_t minimumComponentSize(std::size_t sourceGaussianCount);

void repairUncertainGaussians(
    const std::vector<NeighborList> &neighbors,
    const std::vector<GaussianEvidence> &evidence,
    std::vector<bool> &selected
);

struct Anchor {
    std::string imageIdentity;
    std::uint16_t instance = 0;
};

struct KeyframeContribution {
    std::string imageIdentity;
    std::uint16_t instance = 0;
    double weight = 0;
    double fraction = 0;
};

struct ComponentEvidence {
    std::string identity;
    std::vector<std::size_t> indices;
    double viewCoverage = 0;
    double projectionCentrality = 0;
    double visibleSupport = 0;
    double score = 0;
    std::vector<KeyframeContribution> keyframeContributions;
};

enum class SelectionOutcome {
    selected,
    ambiguous,
    noSubject,
};

struct SelectionResult {
    SelectionOutcome outcome = SelectionOutcome::noSubject;
    std::vector<std::size_t> selectedIndices;
    std::vector<ComponentEvidence> components;
    std::optional<std::size_t> selectedComponent;
};

SelectionResult selectSubject(
    const std::vector<Point3> &points,
    const std::vector<GaussianEvidence> &evidence,
    const std::vector<ReducedView> &views,
    const std::optional<Anchor> &anchor,
    const std::vector<double> &anchorComponentWeights = {}
);

double median(std::vector<double> values);
double firstQuartile(std::vector<double> values);
bool heldOutValidationPasses(const std::vector<double> &softIoUs);

std::size_t requiredWorkingSetBytes(
    std::size_t gaussianCount,
    std::size_t labelCount,
    std::size_t imageWidth,
    std::size_t imageHeight,
    std::size_t plyRowBytes
);

void enforceMemoryBudget(
    std::size_t requiredBytes,
    std::size_t availableBytes
);

struct SceneBounds {
    bool finite = false;
    Point3 minimum {};
    Point3 maximum {};
};

struct FilteredPlyReceipt {
    SceneBounds bounds;
    std::uint64_t outputDevice = 0;
    std::uint64_t outputInode = 0;
    std::uint64_t outputBytes = 0;
};

struct BinaryPly {
    std::filesystem::path path;
    std::vector<std::uint8_t> header;
    std::string headerPrefixBeforeVertexCount;
    std::string headerSuffixAfterVertexCount;
    std::uint64_t vertexCount = 0;
    std::size_t rowBytes = 0;
    std::uint64_t vertexDataOffset = 0;
    std::size_t xOffset = 0;
    std::size_t yOffset = 0;
    std::size_t zOffset = 0;
    std::vector<std::size_t> finiteFloatOffsets;
    std::vector<std::size_t> allFloatOffsets;
    std::vector<std::size_t> allDoubleOffsets;
    std::uint64_t sourceBytes = 0;
    std::uint64_t sourceDevice = 0;
    std::uint64_t sourceInode = 0;
};

BinaryPly inspectBinaryPlyHeader(
    const std::filesystem::path &path,
    std::size_t memoryBudgetBytes
);

void validateBinaryPlyRows(
    const BinaryPly &ply,
    const std::function<bool()> &isCancelled = {}
);

BinaryPly inspectBinaryPly(
    const std::filesystem::path &path,
    std::size_t memoryBudgetBytes,
    const std::function<bool()> &isCancelled = {}
);

std::vector<std::uint8_t> readVertexRows(
    const BinaryPly &ply,
    const std::vector<std::size_t> &indices
);

FilteredPlyReceipt writeFilteredBinaryPly(
    const BinaryPly &source,
    const std::filesystem::path &output,
    const std::vector<std::size_t> &selectedIndices,
    const std::function<bool()> &isCancelled
);

struct AnalysisCache {
    std::string sourceDigest;
    std::string inputDigest;
    std::string geometryDigest;
    std::string selectedFramesDigest;
    std::string trainingDigest;
    std::vector<std::string> expectedViewIdentities;
    std::vector<std::string> expectedViewMaskDigests;
    std::size_t gaussianCount = 0;
    std::vector<ReducedView> views;
};

void writeAnalysisCacheAtomically(
    const std::filesystem::path &path,
    const AnalysisCache &cache
);

AnalysisCache readAnalysisCache(
    const std::filesystem::path &path,
    const std::string &sourceDigest,
    const std::string &inputDigest,
    const std::string &geometryDigest,
    const std::string &selectedFramesDigest,
    const std::string &trainingDigest,
    const std::vector<std::string> &expectedViewIdentities,
    const std::vector<std::string> &expectedViewMaskDigests,
    std::size_t expectedGaussianCount,
    std::size_t maximumBytes
);

} // namespace easysplat::isolation

#endif
