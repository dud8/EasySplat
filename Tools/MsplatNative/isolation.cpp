// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include "isolation.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <numeric>
#include <queue>
#include <set>
#include <sstream>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <utility>

namespace fs = std::filesystem;

namespace easysplat::isolation {
namespace {

constexpr std::size_t kMaximumHeaderBytes = 1U << 20;
constexpr std::size_t kMaximumCacheViews = 24;
constexpr std::size_t kMaximumMaskLabels = 256;
constexpr std::size_t kMaximumIdentityBytes = 4096;
constexpr std::array<char, 8> kCacheMagic = {'E', 'S', 'I', 'S', 'O', 'A', 'C', '2'};
constexpr std::uint32_t kCacheVersion = 2;

std::size_t checkedAdd(std::size_t left, std::size_t right, const char *description) {
    if (right > std::numeric_limits<std::size_t>::max() - left) {
        throw MemoryLimitError(std::string(description) + " exceeds the native range");
    }
    return left + right;
}

std::size_t checkedMultiply(
    std::size_t left,
    std::size_t right,
    const char *description
) {
    if (left != 0 && right > std::numeric_limits<std::size_t>::max() / left) {
        throw MemoryLimitError(std::string(description) + " exceeds the native range");
    }
    return left * right;
}

bool finiteUnit(double value) {
    return std::isfinite(value) && value >= 0 && value <= 1;
}

double coordinate(const Point3 &point, int axis) {
    if (axis == 0) return point.x;
    if (axis == 1) return point.y;
    return point.z;
}

double squaredDistance(const Point3 &left, const Point3 &right) {
    const double dx = left.x - right.x;
    const double dy = left.y - right.y;
    const double dz = left.z - right.z;
    return dx * dx + dy * dy + dz * dz;
}

class DisjointSet {
public:
    explicit DisjointSet(std::size_t count) : parents_(count), ranks_(count, 0) {
        std::iota(parents_.begin(), parents_.end(), 0);
    }

    std::size_t find(std::size_t value) {
        while (parents_[value] != value) {
            parents_[value] = parents_[parents_[value]];
            value = parents_[value];
        }
        return value;
    }

    void unite(std::size_t left, std::size_t right) {
        left = find(left);
        right = find(right);
        if (left == right) return;
        if (ranks_[left] < ranks_[right] ||
            (ranks_[left] == ranks_[right] && left > right)) {
            std::swap(left, right);
        }
        parents_[right] = left;
        if (ranks_[left] == ranks_[right]) ++ranks_[left];
    }

private:
    std::vector<std::size_t> parents_;
    std::vector<unsigned> ranks_;
};

class DeterministicKDTree {
public:
    explicit DeterministicKDTree(const std::vector<Point3> &points) : points_(points) {
        std::vector<std::size_t> indices(points.size());
        std::iota(indices.begin(), indices.end(), 0);
        nodes_.reserve(points.size());
        root_ = build(indices, 0, indices.size(), 0);
    }

    std::vector<std::pair<double, std::size_t>> nearest(
        std::size_t queryIndex,
        std::size_t count
    ) const {
        using Candidate = std::pair<double, std::size_t>;
        std::priority_queue<Candidate> candidates;
        query(root_, queryIndex, count, candidates);
        std::vector<Candidate> result;
        result.reserve(candidates.size());
        while (!candidates.empty()) {
            result.push_back(candidates.top());
            candidates.pop();
        }
        std::sort(result.begin(), result.end(), [](const Candidate &left, const Candidate &right) {
            if (left.first != right.first) return left.first < right.first;
            return left.second < right.second;
        });
        return result;
    }

private:
    struct Node {
        std::size_t point = 0;
        int axis = 0;
        int left = -1;
        int right = -1;
    };

    int build(
        std::vector<std::size_t> &indices,
        std::size_t begin,
        std::size_t end,
        int depth
    ) {
        if (begin >= end) return -1;
        const int axis = depth % 3;
        const std::size_t middle = begin + (end - begin) / 2;
        std::nth_element(
            indices.begin() + static_cast<std::ptrdiff_t>(begin),
            indices.begin() + static_cast<std::ptrdiff_t>(middle),
            indices.begin() + static_cast<std::ptrdiff_t>(end),
            [&](std::size_t left, std::size_t right) {
                const double leftCoordinate = coordinate(points_[left], axis);
                const double rightCoordinate = coordinate(points_[right], axis);
                if (leftCoordinate != rightCoordinate) {
                    return leftCoordinate < rightCoordinate;
                }
                return left < right;
            }
        );
        const int nodeIndex = static_cast<int>(nodes_.size());
        nodes_.push_back({indices[middle], axis, -1, -1});
        const std::size_t storedNodeIndex =
            static_cast<std::size_t>(nodeIndex);
        nodes_[storedNodeIndex].left =
            build(indices, begin, middle, depth + 1);
        nodes_[storedNodeIndex].right =
            build(indices, middle + 1, end, depth + 1);
        return nodeIndex;
    }

    void query(
        int nodeIndex,
        std::size_t queryIndex,
        std::size_t count,
        std::priority_queue<std::pair<double, std::size_t>> &candidates
    ) const {
        if (nodeIndex < 0) return;
        const Node &node = nodes_[static_cast<std::size_t>(nodeIndex)];
        const Point3 &queryPoint = points_[queryIndex];
        const Point3 &nodePoint = points_[node.point];
        const double delta =
            coordinate(queryPoint, node.axis) - coordinate(nodePoint, node.axis);
        const int nearNode = delta <= 0 ? node.left : node.right;
        const int farNode = delta <= 0 ? node.right : node.left;
        query(nearNode, queryIndex, count, candidates);
        if (node.point != queryIndex) {
            const auto candidate = std::make_pair(
                squaredDistance(queryPoint, nodePoint),
                node.point
            );
            if (candidates.size() < count) {
                candidates.push(candidate);
            } else if (candidate < candidates.top()) {
                candidates.pop();
                candidates.push(candidate);
            }
        }
        const double worst = candidates.size() < count
            ? std::numeric_limits<double>::infinity()
            : candidates.top().first;
        if (delta * delta <= worst) query(farNode, queryIndex, count, candidates);
    }

    const std::vector<Point3> &points_;
    std::vector<Node> nodes_;
    int root_ = -1;
};

void readExact(int descriptor, void *bytes, std::size_t count, std::uint64_t offset) {
    auto *destination = static_cast<std::uint8_t *>(bytes);
    std::size_t completed = 0;
    while (completed < count) {
        const ssize_t amount = ::pread(
            descriptor,
            destination + completed,
            count - completed,
            static_cast<off_t>(offset + completed)
        );
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) throw PlyValidationError("binary PLY ended unexpectedly");
        completed += static_cast<std::size_t>(amount);
    }
}

void writeExact(int descriptor, const void *bytes, std::size_t count) {
    const auto *source = static_cast<const std::uint8_t *>(bytes);
    std::size_t completed = 0;
    while (completed < count) {
        const ssize_t amount = ::write(descriptor, source + completed, count - completed);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) throw std::runtime_error("could not write isolated PLY");
        completed += static_cast<std::size_t>(amount);
    }
}

void closeDescriptor(int &descriptor) noexcept {
    if (descriptor < 0) return;
    const int openDescriptor = descriptor;
    descriptor = -1;
    (void)::close(openDescriptor);
}

std::size_t propertySize(std::string_view type) {
    if (type == "char" || type == "int8" || type == "uchar" || type == "uint8") return 1;
    if (type == "short" || type == "int16" || type == "ushort" || type == "uint16") return 2;
    if (type == "int" || type == "int32" || type == "uint" || type == "uint32" ||
        type == "float" || type == "float32") {
        return 4;
    }
    if (type == "double" || type == "float64" || type == "int64" || type == "uint64") {
        return 8;
    }
    throw PlyValidationError("binary PLY contains an unsupported property type");
}

std::uint64_t parseUnsigned(std::string_view value, const char *description) {
    if (value.empty()) throw PlyValidationError(std::string(description) + " is empty");
    std::uint64_t result = 0;
    for (char character : value) {
        if (character < '0' || character > '9') {
            throw PlyValidationError(std::string(description) + " is malformed");
        }
        const std::uint64_t digit = static_cast<std::uint64_t>(character - '0');
        if (result > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) {
            throw PlyValidationError(std::string(description) + " is too large");
        }
        result = result * 10 + digit;
    }
    return result;
}

float rowFloat(const std::vector<std::uint8_t> &row, std::size_t offset) {
    float value = 0;
    std::memcpy(&value, row.data() + offset, sizeof(value));
    return value;
}

double rowDouble(const std::vector<std::uint8_t> &row, std::size_t offset) {
    double value = 0;
    std::memcpy(&value, row.data() + offset, sizeof(value));
    return value;
}

void verifyStableSource(const BinaryPly &source, int descriptor) {
    struct stat status {};
    if (::fstat(descriptor, &status) != 0 ||
        static_cast<std::uint64_t>(status.st_dev) != source.sourceDevice ||
        static_cast<std::uint64_t>(status.st_ino) != source.sourceInode ||
        static_cast<std::uint64_t>(status.st_size) != source.sourceBytes) {
        throw PlyValidationError("source PLY changed during isolation");
    }
}

template <typename T>
void appendScalar(std::vector<std::uint8_t> &bytes, T value) {
    const auto *begin = reinterpret_cast<const std::uint8_t *>(&value);
    bytes.insert(bytes.end(), begin, begin + sizeof(T));
}

void appendString(std::vector<std::uint8_t> &bytes, const std::string &value) {
    if (value.size() > kMaximumIdentityBytes) {
        throw CacheValidationError("analysis cache identity is too long");
    }
    appendScalar<std::uint32_t>(bytes, static_cast<std::uint32_t>(value.size()));
    bytes.insert(bytes.end(), value.begin(), value.end());
}

class CacheReader {
public:
    explicit CacheReader(std::vector<std::uint8_t> bytes) : bytes_(std::move(bytes)) {}

    template <typename T>
    T scalar() {
        require(sizeof(T));
        T value {};
        std::memcpy(&value, bytes_.data() + offset_, sizeof(T));
        offset_ += sizeof(T);
        return value;
    }

    std::string string() {
        const std::uint32_t length = scalar<std::uint32_t>();
        if (length > kMaximumIdentityBytes) {
            throw CacheValidationError("analysis cache identity exceeds its bound");
        }
        require(length);
        std::string value(
            reinterpret_cast<const char *>(bytes_.data() + offset_),
            length
        );
        offset_ += length;
        return value;
    }

    void exactEnd() const {
        if (offset_ != bytes_.size()) {
            throw CacheValidationError("analysis cache has trailing bytes");
        }
    }

private:
    void require(std::size_t count) const {
        if (count > bytes_.size() - offset_) {
            throw CacheValidationError("analysis cache is truncated");
        }
    }

    std::vector<std::uint8_t> bytes_;
    std::size_t offset_ = 0;
};

void validateDigest(const std::string &digest, const char *description) {
    if (digest.size() != 64 ||
        !std::all_of(digest.begin(), digest.end(), [](char character) {
            return (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f');
        })) {
        throw CacheValidationError(std::string(description) + " is not lowercase SHA-256");
    }
}

void validateCachedObservation(
    const GaussianViewObservation &gaussian,
    const char *description
) {
    const bool weightsAreValid =
        gaussian.assignedInstance < kMaximumMaskLabels &&
        std::isfinite(gaussian.visibleWeight) &&
        gaussian.visibleWeight >= 0 &&
        std::isfinite(gaussian.foregroundWeight) &&
        gaussian.foregroundWeight >= 0 &&
        gaussian.foregroundWeight <= gaussian.visibleWeight &&
        std::isfinite(gaussian.assignedInstanceWeight) &&
        gaussian.assignedInstanceWeight >= 0 &&
        gaussian.assignedInstanceWeight <= gaussian.foregroundWeight &&
        finiteUnit(gaussian.projectionCentrality);
    const bool observationStateIsValid =
        gaussian.sufficientlyObserved ==
            (gaussian.visibleWeight >= kContributionFloor) &&
        (gaussian.visibleWeight > 0 || gaussian.projectionCentrality == 0);
    const bool assignmentIsValid = gaussian.assignedInstance == 0
        ? gaussian.assignedInstanceWeight == 0
        : gaussian.sufficientlyObserved &&
            gaussian.assignedInstanceWeight >=
                kViewAssignmentThreshold * gaussian.visibleWeight;
    if (!weightsAreValid || !observationStateIsValid || !assignmentIsValid) {
        throw CacheValidationError(description);
    }
}

} // namespace

LiftedView liftContributions(
    std::string identity,
    std::size_t gaussianCount,
    const std::vector<WeightedPixelContribution> &contributions
) {
    if (identity.empty() || identity.size() > kMaximumIdentityBytes) {
        throw std::invalid_argument("view identity is invalid");
    }
    std::set<std::uint16_t> labelSet {0};
    for (const WeightedPixelContribution &contribution : contributions) {
        if (contribution.gaussianIndex >= gaussianCount ||
            contribution.label >= kMaximumMaskLabels ||
            !finiteUnit(contribution.alpha) ||
            !finiteUnit(contribution.transmittance) ||
            !finiteUnit(contribution.projectionCentrality)) {
            throw std::invalid_argument("pixel contribution is invalid");
        }
        const double weight = contribution.alpha * contribution.transmittance;
        if (weight >= kContributionFloor) labelSet.insert(contribution.label);
    }
    LiftedView result;
    result.identity = std::move(identity);
    result.labels.assign(labelSet.begin(), labelSet.end());
    result.gaussians.resize(gaussianCount);
    for (LiftedGaussian &gaussian : result.gaussians) {
        gaussian.labelWeights.assign(result.labels.size(), 0);
    }
    for (const WeightedPixelContribution &contribution : contributions) {
        const double weight = contribution.alpha * contribution.transmittance;
        if (weight < kContributionFloor) continue;
        const auto found = std::lower_bound(
            result.labels.begin(),
            result.labels.end(),
            contribution.label
        );
        const std::size_t labelIndex =
            static_cast<std::size_t>(found - result.labels.begin());
        LiftedGaussian &gaussian = result.gaussians[contribution.gaussianIndex];
        gaussian.labelWeights[labelIndex] += weight;
        gaussian.centralityWeight += weight * contribution.projectionCentrality;
    }
    return result;
}

ReducedView reduceLiftedView(const LiftedView &view) {
    if (view.identity.empty() || view.labels.empty() || view.labels.front() != 0 ||
        !std::is_sorted(view.labels.begin(), view.labels.end()) ||
        std::adjacent_find(view.labels.begin(), view.labels.end()) != view.labels.end()) {
        throw std::invalid_argument("lifted view shape is invalid");
    }
    ReducedView reduced;
    reduced.identity = view.identity;
    reduced.heldOut = view.heldOut;
    reduced.gaussians.reserve(view.gaussians.size());
    for (const LiftedGaussian &gaussian : view.gaussians) {
        if (gaussian.labelWeights.size() != view.labels.size()) {
            throw std::invalid_argument("lifted Gaussian label shape is invalid");
        }
        if (!std::isfinite(gaussian.centralityWeight) ||
            gaussian.centralityWeight < 0) {
            throw std::invalid_argument("lifted Gaussian centrality is invalid");
        }
        double visibleWeight = 0;
        double foregroundWeight = 0;
        double bestWeight = 0;
        std::uint16_t bestLabel = 0;
        for (std::size_t labelIndex = 0; labelIndex < view.labels.size(); ++labelIndex) {
            const double weight = gaussian.labelWeights[labelIndex];
            if (!std::isfinite(weight) || weight < 0) {
                throw std::invalid_argument("lifted Gaussian weight is invalid");
            }
            visibleWeight += weight;
            if (!std::isfinite(visibleWeight)) {
                throw std::invalid_argument("lifted Gaussian visible weight overflowed");
            }
            if (view.labels[labelIndex] != 0) {
                foregroundWeight += weight;
                if (!std::isfinite(foregroundWeight)) {
                    throw std::invalid_argument(
                        "lifted Gaussian foreground weight overflowed"
                    );
                }
                if (weight > bestWeight ||
                    (weight == bestWeight && view.labels[labelIndex] < bestLabel)) {
                    bestWeight = weight;
                    bestLabel = view.labels[labelIndex];
                }
            }
        }
        GaussianViewObservation observation;
        observation.visibleWeight = visibleWeight;
        observation.foregroundWeight = foregroundWeight;
        observation.sufficientlyObserved = visibleWeight >= kContributionFloor;
        if (observation.sufficientlyObserved &&
            bestWeight >= kViewAssignmentThreshold * visibleWeight) {
            observation.assignedInstance = bestLabel;
            observation.assignedInstanceWeight = bestWeight;
        }
        if (visibleWeight > 0) {
            observation.projectionCentrality =
                std::clamp(gaussian.centralityWeight / visibleWeight, 0.0, 1.0);
        }
        reduced.gaussians.push_back(observation);
    }
    return reduced;
}

std::vector<ReducedView> reduceLiftedViews(const std::vector<LiftedView> &views) {
    std::vector<ReducedView> reduced;
    reduced.reserve(views.size());
    for (const LiftedView &view : views) reduced.push_back(reduceLiftedView(view));
    return reduced;
}

std::vector<GaussianEvidence> classifyGaussians(
    const std::vector<ReducedView> &views
) {
    if (views.empty()) return {};
    const std::size_t gaussianCount = views.front().gaussians.size();
    std::vector<GaussianEvidence> evidence(gaussianCount);
    for (const ReducedView &view : views) {
        if (view.heldOut) continue;
        if (view.gaussians.size() != gaussianCount) {
            throw std::invalid_argument("reduced view shape is invalid");
        }
        for (std::size_t gaussianIndex = 0; gaussianIndex < gaussianCount; ++gaussianIndex) {
            evidence[gaussianIndex].observations.push_back(view.gaussians[gaussianIndex]);
        }
    }

    for (GaussianEvidence &gaussian : evidence) {
        double visibleWeight = 0;
        double foregroundWeight = 0;
        std::size_t observedViews = 0;
        std::size_t backgroundViews = 0;
        for (const GaussianViewObservation &observation : gaussian.observations) {
            if (!observation.sufficientlyObserved) continue;
            visibleWeight += observation.visibleWeight;
            foregroundWeight += observation.foregroundWeight;
            ++observedViews;
            if (observation.foregroundWeight <=
                kBackgroundThreshold * observation.visibleWeight) {
                ++backgroundViews;
            }
        }
        gaussian.foregroundProbability =
            visibleWeight > 0 ? foregroundWeight / visibleWeight : 0;
        gaussian.backgroundViewFraction = observedViews > 0
            ? static_cast<double>(backgroundViews) / static_cast<double>(observedViews)
            : 0;
        if (gaussian.foregroundProbability >= kForegroundThreshold) {
            gaussian.classification = GaussianClass::foreground;
        } else if (gaussian.foregroundProbability <= kBackgroundThreshold) {
            gaussian.classification = GaussianClass::background;
        } else {
            gaussian.classification = GaussianClass::uncertain;
        }
    }
    return evidence;
}

std::vector<NeighborList> deterministicNeighbors(
    const std::vector<Point3> &points
) {
    for (const Point3 &point : points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(point.z)) {
            throw std::invalid_argument("Gaussian position is not finite");
        }
    }
    std::vector<NeighborList> neighbors(points.size());
    if (points.empty()) return neighbors;
    const DeterministicKDTree tree(points);
    for (std::size_t index = 0; index < points.size(); ++index) {
        const auto nearest = tree.nearest(index, std::min(kNeighborCount, points.size() - 1));
        const std::size_t fallback = nearest.empty() ? index : nearest.back().second;
        for (std::size_t slot = 0; slot < kNeighborCount; ++slot) {
            neighbors[index][slot] =
                slot < nearest.size() ? nearest[slot].second : fallback;
        }
    }
    return neighbors;
}

bool graphEdgeAllowed(
    double distance,
    double leftLocalDistance,
    double rightLocalDistance,
    const GaussianEvidence &left,
    const GaussianEvidence &right
) {
    if (!std::isfinite(distance) || distance < 0 ||
        !std::isfinite(leftLocalDistance) || leftLocalDistance < 0 ||
        !std::isfinite(rightLocalDistance) || rightLocalDistance < 0) {
        throw std::invalid_argument("graph distance is invalid");
    }
    std::size_t common = 0;
    std::size_t agreement = 0;
    std::size_t contradictions = 0;
    const std::size_t viewCount =
        std::min(left.observations.size(), right.observations.size());
    for (std::size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
        const auto &leftView = left.observations[viewIndex];
        const auto &rightView = right.observations[viewIndex];
        if (!leftView.sufficientlyObserved || !rightView.sufficientlyObserved) continue;
        ++common;
        if (leftView.assignedInstance != 0 &&
            leftView.assignedInstance == rightView.assignedInstance) {
            ++agreement;
        } else if (leftView.assignedInstance != 0 &&
                   rightView.assignedInstance != 0) {
            ++contradictions;
        }
    }
    const double adaptiveDistance = std::max(leftLocalDistance, rightLocalDistance);
    const bool sharedInstance =
        common >= 2 &&
        static_cast<double>(agreement) >=
            kGraphAgreementThreshold * static_cast<double>(common) &&
        distance <= 2.5 * adaptiveDistance;
    const bool closeFallback =
        left.foregroundProbability >= 0.80 &&
        right.foregroundProbability >= 0.80 &&
        contradictions == 0 &&
        distance <= 1.5 * adaptiveDistance;
    return sharedInstance || closeFallback;
}

double componentRankScore(
    double viewCoverage,
    double projectionCentrality,
    double visibleSupport
) {
    if (!finiteUnit(viewCoverage) || !finiteUnit(projectionCentrality) ||
        !finiteUnit(visibleSupport)) {
        throw std::invalid_argument("component rank metric is invalid");
    }
    return 0.50 * viewCoverage +
        0.30 * projectionCentrality +
        0.20 * visibleSupport;
}

bool autoSelectionAllowed(
    double coverage,
    double lead,
    double retainedFraction
) {
    if (!finiteUnit(coverage) || !std::isfinite(lead) || lead < 0 ||
        !finiteUnit(retainedFraction)) {
        throw std::invalid_argument("auto-selection metric is invalid");
    }
    return coverage >= kAutoSelectionCoverage &&
        lead >= kAutoSelectionLead &&
        retainedFraction >= kMinimumRetainedFraction &&
        retainedFraction <= kMaximumRetainedFraction;
}

bool shouldPruneAsBackground(double backgroundViewFraction) {
    if (!finiteUnit(backgroundViewFraction)) {
        throw std::invalid_argument("background-view fraction is invalid");
    }
    return backgroundViewFraction > 0.80;
}

std::size_t minimumComponentSize(std::size_t sourceGaussianCount) {
    return std::max<std::size_t>(
        64,
        static_cast<std::size_t>(
            std::ceil(0.001 * static_cast<double>(sourceGaussianCount))
        )
    );
}

void repairUncertainGaussians(
    const std::vector<NeighborList> &neighbors,
    const std::vector<GaussianEvidence> &evidence,
    std::vector<bool> &selected
) {
    if (neighbors.size() != evidence.size() || selected.size() != evidence.size()) {
        throw std::invalid_argument("repair inputs have different Gaussian counts");
    }
    constexpr std::size_t requiredNeighbors = 13;
    for (int pass = 0; pass < 2; ++pass) {
        std::vector<std::size_t> additions;
        for (std::size_t index = 0; index < evidence.size(); ++index) {
            if (selected[index] || evidence[index].classification != GaussianClass::uncertain) {
                continue;
            }
            NeighborList uniqueNeighbors = neighbors[index];
            std::sort(uniqueNeighbors.begin(), uniqueNeighbors.end());
            const auto uniqueEnd =
                std::unique(uniqueNeighbors.begin(), uniqueNeighbors.end());
            std::size_t selectedNeighbors = 0;
            for (auto neighborIt = uniqueNeighbors.begin();
                 neighborIt != uniqueEnd;
                 ++neighborIt) {
                const std::size_t neighbor = *neighborIt;
                if (neighbor >= selected.size()) {
                    throw std::invalid_argument("repair neighbor is out of range");
                }
                if (selected[neighbor]) ++selectedNeighbors;
            }
            if (selectedNeighbors >= requiredNeighbors) additions.push_back(index);
        }
        for (std::size_t index : additions) selected[index] = true;
        if (additions.empty()) break;
    }
}

SelectionResult selectSubject(
    const std::vector<Point3> &points,
    const std::vector<GaussianEvidence> &evidence,
    const std::vector<ReducedView> &views,
    const std::optional<Anchor> &anchor,
    const std::vector<double> &anchorComponentWeights
) {
    if (points.size() != evidence.size()) {
        throw std::invalid_argument("selection evidence does not match source Gaussian count");
    }
    if (!anchor.has_value() && !anchorComponentWeights.empty()) {
        throw std::invalid_argument(
            "anchor component weights require an anchor"
        );
    }
    SelectionResult result;
    const std::size_t sourceCount = points.size();
    if (sourceCount == 0) return result;
    for (const ReducedView &view : views) {
        if (!view.heldOut && view.gaussians.size() != sourceCount) {
            throw std::invalid_argument(
                "view Gaussian count changed during selection"
            );
        }
    }
    const std::size_t requiredComponentSize = minimumComponentSize(sourceCount);
    const auto neighbors = deterministicNeighbors(points);
    std::vector<double> localDistance(sourceCount, 0);
    for (std::size_t index = 0; index < sourceCount; ++index) {
        std::array<double, kNeighborCount> distances {};
        for (std::size_t slot = 0; slot < kNeighborCount; ++slot) {
            distances[slot] = std::sqrt(
                squaredDistance(
                    points[index],
                    points[neighbors[index][slot]]
                )
            );
        }
        std::sort(distances.begin(), distances.end());
        localDistance[index] =
            distances[kNeighborCount / 2 - 1] +
            (distances[kNeighborCount / 2] -
             distances[kNeighborCount / 2 - 1]) *
                0.5;
    }

    DisjointSet sets(sourceCount);
    for (std::size_t left = 0; left < sourceCount; ++left) {
        if (evidence[left].classification != GaussianClass::foreground) continue;
        for (std::size_t right : neighbors[left]) {
            if (right == left ||
                evidence[right].classification != GaussianClass::foreground) {
                continue;
            }
            const double distance = std::sqrt(squaredDistance(points[left], points[right]));
            if (graphEdgeAllowed(
                    distance,
                    localDistance[left],
                    localDistance[right],
                    evidence[left],
                    evidence[right]
                )) {
                sets.unite(left, right);
            }
        }
    }

    std::unordered_map<std::size_t, std::vector<std::size_t>> componentMap;
    for (std::size_t index = 0; index < sourceCount; ++index) {
        if (evidence[index].classification == GaussianClass::foreground) {
            componentMap[sets.find(index)].push_back(index);
        }
    }
    std::vector<std::vector<std::size_t>> components;
    for (auto &[_, indices] : componentMap) {
        std::sort(indices.begin(), indices.end());
        if (indices.size() >= requiredComponentSize) {
            components.push_back(std::move(indices));
        }
    }
    std::sort(components.begin(), components.end(), [](const auto &left, const auto &right) {
        return left.front() < right.front();
    });

    double totalForegroundWeight = 0;
    for (const ReducedView &view : views) {
        if (view.heldOut) continue;
        for (const GaussianViewObservation &gaussian : view.gaussians) {
            totalForegroundWeight += gaussian.foregroundWeight;
        }
    }
    std::size_t workViewCount = 0;
    for (const ReducedView &view : views) {
        if (!view.heldOut) ++workViewCount;
    }

    for (const auto &indices : components) {
        ComponentEvidence component;
        component.identity = "component-" + std::to_string(indices.front());
        component.indices = indices;
        std::size_t coveredViews = 0;
        double componentForegroundWeight = 0;
        double centralityNumerator = 0;
        double centralityDenominator = 0;
        for (const ReducedView &view : views) {
            if (view.heldOut) continue;
            std::unordered_map<std::uint16_t, double> labelWeights;
            double visibleWeight = 0;
            double centralityWeight = 0;
            double viewForeground = 0;
            for (std::size_t index : indices) {
                if (index >= view.gaussians.size()) {
                    throw std::invalid_argument("view Gaussian count changed during selection");
                }
                const GaussianViewObservation &gaussian = view.gaussians[index];
                centralityWeight +=
                    gaussian.projectionCentrality * gaussian.visibleWeight;
                visibleWeight += gaussian.visibleWeight;
                viewForeground += gaussian.foregroundWeight;
                if (gaussian.assignedInstance != 0) {
                    labelWeights[gaussian.assignedInstance] +=
                        gaussian.assignedInstanceWeight;
                }
            }
            if (viewForeground >= kContributionFloor) ++coveredViews;
            componentForegroundWeight += viewForeground;
            centralityNumerator += centralityWeight;
            centralityDenominator += visibleWeight;

            std::uint16_t bestLabel = 0;
            double bestWeight = 0;
            for (const auto &[label, weight] : labelWeights) {
                if (weight > bestWeight || (weight == bestWeight && label < bestLabel)) {
                    bestLabel = label;
                    bestWeight = weight;
                }
            }
            if (bestLabel != 0 && bestWeight > 0) {
                component.keyframeContributions.push_back({
                    view.identity,
                    bestLabel,
                    bestWeight,
                    viewForeground > 0 ? bestWeight / viewForeground : 0,
                });
            }
        }
        component.viewCoverage = workViewCount > 0
            ? static_cast<double>(coveredViews) / static_cast<double>(workViewCount)
            : 0;
        component.projectionCentrality = centralityDenominator > 0
            ? std::clamp(centralityNumerator / centralityDenominator, 0.0, 1.0)
            : 0;
        component.visibleSupport = totalForegroundWeight > 0
            ? std::clamp(componentForegroundWeight / totalForegroundWeight, 0.0, 1.0)
            : 0;
        component.score = componentRankScore(
            component.viewCoverage,
            component.projectionCentrality,
            component.visibleSupport
        );
        result.components.push_back(std::move(component));
    }
    std::sort(result.components.begin(), result.components.end(), [](const auto &left, const auto &right) {
        if (left.score != right.score) return left.score > right.score;
        if (left.viewCoverage != right.viewCoverage) {
            return left.viewCoverage > right.viewCoverage;
        }
        return left.indices.front() < right.indices.front();
    });

    const bool anySubjectCoverage = std::any_of(
        result.components.begin(),
        result.components.end(),
        [](const ComponentEvidence &component) {
            return component.viewCoverage >= kNoSubjectCoverage;
        }
    );
    if (!anySubjectCoverage) {
        result.outcome = SelectionOutcome::noSubject;
        return result;
    }

    std::optional<std::size_t> chosen;
    if (anchor.has_value()) {
        if (anchor->instance == 0) {
            throw std::invalid_argument("anchor instance must be nonzero");
        }
        const auto viewFound = std::find_if(views.begin(), views.end(), [&](const ReducedView &view) {
            return !view.heldOut && view.identity == anchor->imageIdentity;
        });
        if (viewFound == views.end()) {
            throw std::invalid_argument("anchor image is not in the analysis cache");
        }
        if (anchorComponentWeights.size() != result.components.size()) {
            throw std::invalid_argument(
                "anchor component weights do not match the deterministic graph"
            );
        }
        double bestWeight = 0;
        for (std::size_t componentIndex = 0;
             componentIndex < result.components.size();
             ++componentIndex) {
            const double weight = anchorComponentWeights[componentIndex];
            if (!std::isfinite(weight) || weight < 0) {
                throw std::invalid_argument(
                    "anchor component weight is invalid"
                );
            }
            if (weight > bestWeight) {
                bestWeight = weight;
                chosen = componentIndex;
            }
        }
        if (!chosen.has_value() || bestWeight <= 0) {
            throw std::invalid_argument("anchor has no weighted 3D component contribution");
        }
    } else {
        const ComponentEvidence &best = result.components.front();
        const double lead = result.components.size() > 1
            ? best.score - result.components[1].score
            : 1.0;
        const double retainedFraction =
            static_cast<double>(best.indices.size()) / static_cast<double>(sourceCount);
        if (autoSelectionAllowed(best.viewCoverage, lead, retainedFraction)) {
            chosen = 0;
        }
    }
    if (!chosen.has_value()) {
        result.outcome = SelectionOutcome::ambiguous;
        return result;
    }

    std::vector<bool> selected(sourceCount, false);
    for (std::size_t index : result.components[*chosen].indices) {
        if (!shouldPruneAsBackground(evidence[index].backgroundViewFraction)) {
            selected[index] = true;
        }
    }
    repairUncertainGaussians(neighbors, evidence, selected);
    for (std::size_t index = 0; index < selected.size(); ++index) {
        if (selected[index]) result.selectedIndices.push_back(index);
    }
    const double retainedFraction =
        static_cast<double>(result.selectedIndices.size()) / static_cast<double>(sourceCount);
    if (retainedFraction < kMinimumRetainedFraction ||
        retainedFraction > kMaximumRetainedFraction) {
        result.outcome = SelectionOutcome::ambiguous;
        result.selectedIndices.clear();
        return result;
    }
    result.outcome = SelectionOutcome::selected;
    result.selectedComponent = chosen;
    return result;
}

double median(std::vector<double> values) {
    if (values.empty()) throw std::invalid_argument("median requires values");
    for (double value : values) {
        if (!finiteUnit(value)) throw std::invalid_argument("median value is invalid");
    }
    std::sort(values.begin(), values.end());
    const std::size_t middle = values.size() / 2;
    return values.size() % 2 == 0
        ? (values[middle - 1] + values[middle]) / 2
        : values[middle];
}

double firstQuartile(std::vector<double> values) {
    if (values.empty()) throw std::invalid_argument("quartile requires values");
    for (double value : values) {
        if (!finiteUnit(value)) throw std::invalid_argument("quartile value is invalid");
    }
    std::sort(values.begin(), values.end());
    const std::size_t index = static_cast<std::size_t>(
        std::floor(0.25 * static_cast<double>(values.size() - 1))
    );
    return values[index];
}

bool heldOutValidationPasses(const std::vector<double> &softIoUs) {
    return !softIoUs.empty() &&
        median(softIoUs) >= kHeldOutMedianIoU &&
        firstQuartile(softIoUs) >= kHeldOutFirstQuartileIoU;
}

std::size_t requiredWorkingSetBytes(
    std::size_t gaussianCount,
    std::size_t labelCount,
    std::size_t imageWidth,
    std::size_t imageHeight,
    std::size_t plyRowBytes
) {
    if (labelCount == 0 || labelCount > kMaximumMaskLabels ||
        imageWidth == 0 || imageHeight == 0 || plyRowBytes == 0) {
        throw MemoryLimitError("isolation working-set dimensions are invalid");
    }
    std::size_t bytes = checkedMultiply(
        gaussianCount,
        checkedAdd(
            checkedMultiply(labelCount, sizeof(float), "sizing label weights"),
            sizeof(float) * 4 + sizeof(Point3) + plyRowBytes,
            "sizing per-Gaussian isolation state"
        ),
        "sizing per-Gaussian isolation state"
    );
    bytes = checkedAdd(
        bytes,
        checkedMultiply(
            checkedMultiply(imageWidth, imageHeight, "sizing isolation mask pixels"),
            sizeof(std::uint16_t) + sizeof(float),
            "sizing isolation mask pixels"
        ),
        "sizing isolation working set"
    );
    bytes = checkedAdd(
        bytes,
        checkedMultiply(
            gaussianCount,
            kNeighborCount * sizeof(std::size_t),
            "sizing isolation neighbor graph"
        ),
        "sizing isolation working set"
    );
    return bytes;
}

void enforceMemoryBudget(
    std::size_t requiredBytes,
    std::size_t availableBytes
) {
    if (requiredBytes > availableBytes) {
        throw MemoryLimitError("isolation working set exceeds the memory budget");
    }
}

BinaryPly inspectBinaryPly(
    const fs::path &path,
    std::size_t memoryBudgetBytes
) {
    if (memoryBudgetBytes < 4096) {
        throw MemoryLimitError("memory budget cannot contain a binary PLY header");
    }
    int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) throw PlyValidationError("cannot open source PLY safely");
    try {
        struct stat status {};
        if (::fstat(descriptor, &status) != 0 ||
            !S_ISREG(status.st_mode) ||
            status.st_nlink != 1 ||
            status.st_size <= 0) {
            throw PlyValidationError("source PLY must be a single-link regular file");
        }
        BinaryPly result;
        result.path = path;
        result.sourceBytes = static_cast<std::uint64_t>(status.st_size);
        result.sourceDevice = static_cast<std::uint64_t>(status.st_dev);
        result.sourceInode = static_cast<std::uint64_t>(status.st_ino);
        const std::size_t headerLimit = std::min({
            kMaximumHeaderBytes,
            memoryBudgetBytes,
            static_cast<std::size_t>(status.st_size),
        });
        result.header.reserve(std::min<std::size_t>(headerLimit, 4096));
        std::array<char, 11> suffix {};
        bool ended = false;
        for (std::size_t offset = 0; offset < headerLimit; ++offset) {
            std::uint8_t byte = 0;
            readExact(descriptor, &byte, 1, offset);
            if (byte == '\r' || byte == '\0') {
                throw PlyValidationError("binary PLY header has unsupported control bytes");
            }
            result.header.push_back(byte);
            std::rotate(suffix.begin(), suffix.begin() + 1, suffix.end());
            suffix.back() = static_cast<char>(byte);
            if (std::string_view(suffix.data(), suffix.size()) == "end_header\n") {
                ended = true;
                break;
            }
        }
        if (!ended) throw PlyValidationError("binary PLY header is missing end_header");
        result.vertexDataOffset = result.header.size();
        const std::string headerText(result.header.begin(), result.header.end());
        std::istringstream lines(headerText);
        std::string line;
        bool firstLine = true;
        bool formatSeen = false;
        bool vertexSeen = false;
        bool inVertex = false;
        std::size_t rowOffset = 0;
        std::unordered_map<std::string, std::pair<std::size_t, std::string>> properties;
        std::size_t vertexCountStart = std::string::npos;
        std::size_t vertexCountEnd = std::string::npos;
        std::size_t cursor = 0;
        while (std::getline(lines, line)) {
            const std::size_t lineStart = cursor;
            cursor += line.size() + 1;
            if (firstLine) {
                firstLine = false;
                if (line != "ply") throw PlyValidationError("source is not a PLY file");
                continue;
            }
            if (line == "format binary_little_endian 1.0") {
                if (formatSeen) throw PlyValidationError("binary PLY repeats its format");
                formatSeen = true;
                continue;
            }
            if (line.rfind("format ", 0) == 0) {
                throw PlyValidationError("source PLY format is unsupported");
            }
            if (!formatSeen) {
                throw PlyValidationError(
                    "source PLY format declaration is out of order"
                );
            }
            if (line.rfind("element ", 0) == 0) {
                std::istringstream fields(line);
                std::string token;
                std::string name;
                std::string countText;
                fields >> token >> name >> countText;
                std::string extra;
                if (token != "element" || name.empty() || countText.empty() || fields >> extra) {
                    throw PlyValidationError("binary PLY element line is malformed");
                }
                if (line != "element " + name + " " + countText) {
                    throw PlyValidationError(
                        "binary PLY element line is not canonical"
                    );
                }
                const std::uint64_t count = parseUnsigned(countText, "PLY element count");
                inVertex = name == "vertex";
                if (inVertex) {
                    if (vertexSeen) throw PlyValidationError("binary PLY repeats vertex element");
                    vertexSeen = true;
                    result.vertexCount = count;
                    vertexCountStart = lineStart + std::string("element vertex ").size();
                    vertexCountEnd = vertexCountStart + countText.size();
                } else if (count != 0) {
                    throw PlyValidationError(
                        "binary PLY with non-vertex payload cannot be filtered safely"
                    );
                }
                continue;
            }
            if (line.rfind("property ", 0) == 0) {
                if (!inVertex) continue;
                std::istringstream fields(line);
                std::string property;
                std::string type;
                std::string name;
                fields >> property >> type >> name;
                std::string extra;
                if (property != "property" || type == "list" || name.empty() ||
                    fields >> extra) {
                    throw PlyValidationError("binary PLY vertex property is unsupported");
                }
                if (line != "property " + type + " " + name) {
                    throw PlyValidationError(
                        "binary PLY vertex property is not canonical"
                    );
                }
                if (properties.find(name) != properties.end()) {
                    throw PlyValidationError("binary PLY repeats a vertex property");
                }
                const std::size_t size = propertySize(type);
                properties.emplace(name, std::make_pair(rowOffset, type));
                if (type == "float" || type == "float32") {
                    result.allFloatOffsets.push_back(rowOffset);
                } else if (type == "double" || type == "float64") {
                    result.allDoubleOffsets.push_back(rowOffset);
                }
                rowOffset = checkedAdd(rowOffset, size, "sizing binary PLY row");
                continue;
            }
            if (line == "end_header" ||
                line == "comment" ||
                line.rfind("comment ", 0) == 0 ||
                line == "obj_info" ||
                line.rfind("obj_info ", 0) == 0 ||
                line.empty()) {
                continue;
            }
            throw PlyValidationError("binary PLY header directive is unsupported");
        }
        if (!formatSeen || !vertexSeen || result.vertexCount == 0 || rowOffset == 0 ||
            vertexCountStart == std::string::npos || vertexCountEnd == std::string::npos) {
            throw PlyValidationError("binary PLY header is incomplete");
        }
        result.rowBytes = rowOffset;
        result.headerPrefixBeforeVertexCount = headerText.substr(0, vertexCountStart);
        result.headerSuffixAfterVertexCount = headerText.substr(vertexCountEnd);
        const std::array<std::string, 14> requiredFloatProperties = {
            "x", "y", "z",
            "f_dc_0", "f_dc_1", "f_dc_2",
            "opacity",
            "scale_0", "scale_1", "scale_2",
            "rot_0", "rot_1", "rot_2", "rot_3",
        };
        for (const std::string &name : requiredFloatProperties) {
            const auto found = properties.find(name);
            if (found == properties.end() ||
                (found->second.second != "float" && found->second.second != "float32")) {
                throw PlyValidationError(
                    "binary PLY required Gaussian properties must be float32"
                );
            }
            result.finiteFloatOffsets.push_back(found->second.first);
        }
        result.xOffset = properties.at("x").first;
        result.yOffset = properties.at("y").first;
        result.zOffset = properties.at("z").first;
        const std::uint64_t payloadBytes =
            result.vertexCount * static_cast<std::uint64_t>(result.rowBytes);
        if (result.vertexCount != 0 &&
            payloadBytes / result.vertexCount != result.rowBytes) {
            throw PlyValidationError("binary PLY payload is too large");
        }
        if (payloadBytes >
                std::numeric_limits<std::uint64_t>::max() -
                    result.vertexDataOffset ||
            result.vertexDataOffset + payloadBytes != result.sourceBytes) {
            throw PlyValidationError("binary PLY byte count does not match its header");
        }
        std::vector<std::uint8_t> row(result.rowBytes);
        for (std::uint64_t index = 0; index < result.vertexCount; ++index) {
            readExact(
                descriptor,
                row.data(),
                row.size(),
                result.vertexDataOffset + index * result.rowBytes
            );
            for (std::size_t offset : result.allFloatOffsets) {
                if (!std::isfinite(rowFloat(row, offset))) {
                    throw PlyValidationError(
                        "binary PLY contains a non-finite float attribute"
                    );
                }
            }
            for (std::size_t offset : result.allDoubleOffsets) {
                if (!std::isfinite(rowDouble(row, offset))) {
                    throw PlyValidationError(
                        "binary PLY contains a non-finite float attribute"
                    );
                }
            }
        }
        verifyStableSource(result, descriptor);
        closeDescriptor(descriptor);
        return result;
    } catch (...) {
        closeDescriptor(descriptor);
        throw;
    }
}

std::vector<std::uint8_t> readVertexRows(
    const BinaryPly &ply,
    const std::vector<std::size_t> &indices
) {
    int descriptor = ::open(ply.path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) throw PlyValidationError("cannot reopen source PLY safely");
    try {
        verifyStableSource(ply, descriptor);
        std::vector<std::uint8_t> rows(
            checkedMultiply(indices.size(), ply.rowBytes, "reading selected PLY rows")
        );
        for (std::size_t outputIndex = 0; outputIndex < indices.size(); ++outputIndex) {
            if (indices[outputIndex] >= ply.vertexCount) {
                throw PlyValidationError("selected PLY row is out of range");
            }
            readExact(
                descriptor,
                rows.data() + outputIndex * ply.rowBytes,
                ply.rowBytes,
                ply.vertexDataOffset + indices[outputIndex] * ply.rowBytes
            );
        }
        verifyStableSource(ply, descriptor);
        closeDescriptor(descriptor);
        return rows;
    } catch (...) {
        closeDescriptor(descriptor);
        throw;
    }
}

FilteredPlyReceipt writeFilteredBinaryPly(
    const BinaryPly &source,
    const fs::path &output,
    const std::vector<std::size_t> &selectedIndices,
    const std::function<bool()> &isCancelled
) {
    if (selectedIndices.empty()) throw PlyValidationError("isolated PLY would be empty");
    if (!std::is_sorted(selectedIndices.begin(), selectedIndices.end()) ||
        std::adjacent_find(selectedIndices.begin(), selectedIndices.end()) !=
            selectedIndices.end() ||
        selectedIndices.back() >= source.vertexCount) {
        throw PlyValidationError("selected PLY rows must be unique, sorted, and in range");
    }
    if (fs::exists(output) || fs::is_symlink(output)) {
        throw PlyValidationError("isolated PLY output already exists");
    }
    const fs::path parent = output.parent_path().empty() ? fs::current_path() : output.parent_path();
    if (!fs::is_directory(parent) || fs::is_symlink(parent)) {
        throw PlyValidationError("isolated PLY output parent is unsafe");
    }
    const fs::path temporary = parent /
        ("." + output.filename().string() + ".isolation." + std::to_string(::getpid()) + ".pending");
    const int sourceDescriptor =
        ::open(source.path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (sourceDescriptor < 0) throw PlyValidationError("cannot reopen source PLY safely");
    int outputDescriptor = -1;
    bool temporaryCreated = false;
    std::uint64_t temporaryDevice = 0;
    std::uint64_t temporaryInode = 0;
    bool outputPublished = false;
    std::uint64_t publishedDevice = 0;
    std::uint64_t publishedInode = 0;
    try {
        verifyStableSource(source, sourceDescriptor);
        if (isCancelled && isCancelled()) throw CancellationError();
        outputDescriptor = ::open(
            temporary.c_str(),
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0600
        );
        if (outputDescriptor < 0) {
            throw PlyValidationError("cannot create isolated PLY staging file safely");
        }
        struct stat temporaryStatus {};
        if (::fstat(outputDescriptor, &temporaryStatus) != 0 ||
            !S_ISREG(temporaryStatus.st_mode) ||
            temporaryStatus.st_nlink != 1) {
            throw PlyValidationError("cannot bind isolated PLY staging file safely");
        }
        temporaryDevice = static_cast<std::uint64_t>(temporaryStatus.st_dev);
        temporaryInode = static_cast<std::uint64_t>(temporaryStatus.st_ino);
        temporaryCreated = true;
        const std::string header =
            source.headerPrefixBeforeVertexCount +
            std::to_string(selectedIndices.size()) +
            source.headerSuffixAfterVertexCount;
        writeExact(outputDescriptor, header.data(), header.size());
        std::vector<std::uint8_t> row(source.rowBytes);
        SceneBounds bounds;
        bounds.minimum = {
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(),
            std::numeric_limits<double>::infinity(),
        };
        bounds.maximum = {
            -std::numeric_limits<double>::infinity(),
            -std::numeric_limits<double>::infinity(),
            -std::numeric_limits<double>::infinity(),
        };
        for (std::size_t selectedIndex : selectedIndices) {
            if (isCancelled && isCancelled()) throw CancellationError();
            readExact(
                sourceDescriptor,
                row.data(),
                row.size(),
                source.vertexDataOffset + selectedIndex * source.rowBytes
            );
            const double x = rowFloat(row, source.xOffset);
            const double y = rowFloat(row, source.yOffset);
            const double z = rowFloat(row, source.zOffset);
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
                throw PlyValidationError("selected PLY row has non-finite bounds");
            }
            bounds.minimum.x = std::min(bounds.minimum.x, x);
            bounds.minimum.y = std::min(bounds.minimum.y, y);
            bounds.minimum.z = std::min(bounds.minimum.z, z);
            bounds.maximum.x = std::max(bounds.maximum.x, x);
            bounds.maximum.y = std::max(bounds.maximum.y, y);
            bounds.maximum.z = std::max(bounds.maximum.z, z);
            writeExact(outputDescriptor, row.data(), row.size());
        }
        bounds.finite =
            std::isfinite(bounds.minimum.x) && std::isfinite(bounds.minimum.y) &&
            std::isfinite(bounds.minimum.z) && std::isfinite(bounds.maximum.x) &&
            std::isfinite(bounds.maximum.y) && std::isfinite(bounds.maximum.z);
        if (!bounds.finite) throw PlyValidationError("isolated PLY bounds are invalid");
        if (::fsync(outputDescriptor) != 0) {
            throw PlyValidationError("could not synchronize isolated PLY staging file");
        }
        ::close(outputDescriptor);
        outputDescriptor = -1;
        verifyStableSource(source, sourceDescriptor);
        if (isCancelled && isCancelled()) throw CancellationError();
        const BinaryPly staged = inspectBinaryPly(
            temporary,
            std::max<std::size_t>(4096, header.size())
        );
        if (staged.vertexCount != selectedIndices.size() ||
            staged.rowBytes != source.rowBytes) {
            throw PlyValidationError("completed isolated PLY failed validation");
        }
        publishedDevice = staged.sourceDevice;
        publishedInode = staged.sourceInode;
#if defined(__APPLE__)
        if (::renameatx_np(
                AT_FDCWD,
                temporary.c_str(),
                AT_FDCWD,
                output.c_str(),
                RENAME_EXCL
            ) != 0) {
            throw PlyValidationError("could not publish isolated PLY exclusively");
        }
        outputPublished = true;
#else
        if (::link(temporary.c_str(), output.c_str()) != 0) {
            throw PlyValidationError("could not publish isolated PLY exclusively");
        }
        outputPublished = true;
        if (::unlink(temporary.c_str()) != 0) {
            throw PlyValidationError("could not retire isolated PLY staging file");
        }
#endif
        const int parentDescriptor = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (parentDescriptor >= 0) {
            (void)::fsync(parentDescriptor);
            ::close(parentDescriptor);
        }
        verifyStableSource(source, sourceDescriptor);
        ::close(sourceDescriptor);
        return {
            bounds,
            publishedDevice,
            publishedInode,
            staged.sourceBytes,
        };
    } catch (...) {
        if (outputDescriptor >= 0) ::close(outputDescriptor);
        ::close(sourceDescriptor);
        if (temporaryCreated) {
            struct stat status {};
            if (::lstat(temporary.c_str(), &status) == 0 &&
                static_cast<std::uint64_t>(status.st_dev) == temporaryDevice &&
                static_cast<std::uint64_t>(status.st_ino) == temporaryInode) {
                (void)::unlink(temporary.c_str());
            }
        }
        if (outputPublished) {
            struct stat status {};
            if (::lstat(output.c_str(), &status) == 0 &&
                static_cast<std::uint64_t>(status.st_dev) == publishedDevice &&
                static_cast<std::uint64_t>(status.st_ino) == publishedInode) {
                (void)::unlink(output.c_str());
            }
        }
        throw;
    }
}

void writeAnalysisCacheAtomically(
    const fs::path &path,
    const AnalysisCache &cache
) {
    validateDigest(cache.sourceDigest, "cache source digest");
    validateDigest(cache.inputDigest, "cache input digest");
    validateDigest(cache.geometryDigest, "cache geometry digest");
    validateDigest(cache.selectedFramesDigest, "cache selected-frames digest");
    validateDigest(cache.trainingDigest, "cache training digest");
    if (cache.gaussianCount == 0 ||
        cache.expectedViewIdentities.empty() ||
        cache.expectedViewIdentities.size() > kMaximumCacheViews ||
        cache.expectedViewMaskDigests.size() !=
            cache.expectedViewIdentities.size() ||
        cache.views.size() > cache.expectedViewIdentities.size()) {
        throw CacheValidationError("analysis cache dimensions are invalid");
    }
    std::set<std::string> expectedIdentities;
    for (std::size_t index = 0;
         index < cache.expectedViewIdentities.size();
         ++index) {
        const std::string &identity = cache.expectedViewIdentities[index];
        if (identity.empty() || !expectedIdentities.insert(identity).second) {
            throw CacheValidationError(
                "analysis cache expected view order is invalid"
            );
        }
        validateDigest(
            cache.expectedViewMaskDigests[index],
            "cache expected view mask digest"
        );
    }
    std::vector<std::uint8_t> bytes(kCacheMagic.begin(), kCacheMagic.end());
    appendScalar<std::uint32_t>(bytes, kCacheVersion);
    appendString(bytes, cache.sourceDigest);
    appendString(bytes, cache.inputDigest);
    appendString(bytes, cache.geometryDigest);
    appendString(bytes, cache.selectedFramesDigest);
    appendString(bytes, cache.trainingDigest);
    appendScalar<std::uint32_t>(
        bytes,
        static_cast<std::uint32_t>(cache.expectedViewIdentities.size())
    );
    for (std::size_t index = 0;
         index < cache.expectedViewIdentities.size();
         ++index) {
        appendString(bytes, cache.expectedViewIdentities[index]);
        appendString(bytes, cache.expectedViewMaskDigests[index]);
    }
    appendScalar<std::uint64_t>(bytes, cache.gaussianCount);
    appendScalar<std::uint32_t>(bytes, static_cast<std::uint32_t>(cache.views.size()));
    for (std::size_t viewIndex = 0; viewIndex < cache.views.size(); ++viewIndex) {
        const ReducedView &view = cache.views[viewIndex];
        if (view.identity != cache.expectedViewIdentities[viewIndex] ||
            view.gaussians.size() != cache.gaussianCount) {
            throw CacheValidationError("analysis cache view shape is invalid");
        }
        appendString(bytes, view.identity);
        appendScalar<std::uint8_t>(bytes, view.heldOut ? 1 : 0);
        for (const GaussianViewObservation &gaussian : view.gaussians) {
            validateCachedObservation(
                gaussian,
                "analysis cache Gaussian shape is invalid"
            );
            appendScalar<std::uint16_t>(bytes, gaussian.assignedInstance);
            appendScalar<std::uint8_t>(bytes, gaussian.sufficientlyObserved ? 1 : 0);
            appendScalar<std::uint8_t>(bytes, 0);
            appendScalar<double>(bytes, gaussian.visibleWeight);
            appendScalar<double>(bytes, gaussian.foregroundWeight);
            appendScalar<double>(bytes, gaussian.assignedInstanceWeight);
            appendScalar<double>(bytes, gaussian.projectionCentrality);
        }
    }
    const fs::path parent = path.parent_path().empty() ? fs::current_path() : path.parent_path();
    if (!fs::is_directory(parent) || fs::is_symlink(parent)) {
        throw CacheValidationError("analysis cache parent is unsafe");
    }
    const fs::path temporary = parent /
        ("." + path.filename().string() + ".pending." + std::to_string(::getpid()));
    int descriptor = ::open(
        temporary.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (descriptor < 0) throw CacheValidationError("cannot create analysis cache staging file");
    try {
        writeExact(descriptor, bytes.data(), bytes.size());
        if (::fsync(descriptor) != 0) {
            throw CacheValidationError("cannot synchronize analysis cache");
        }
        closeDescriptor(descriptor);
#if defined(__APPLE__)
        if (::renameatx_np(
                AT_FDCWD,
                temporary.c_str(),
                AT_FDCWD,
                path.c_str(),
                0
            ) != 0) {
            throw CacheValidationError("cannot publish analysis cache");
        }
#else
        if (::rename(temporary.c_str(), path.c_str()) != 0) {
            throw CacheValidationError("cannot publish analysis cache");
        }
#endif
        const int parentDescriptor =
            ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (parentDescriptor < 0 || ::fsync(parentDescriptor) != 0) {
            if (parentDescriptor >= 0) ::close(parentDescriptor);
            throw CacheValidationError(
                "cannot synchronize analysis cache directory"
            );
        }
        ::close(parentDescriptor);
    } catch (...) {
        closeDescriptor(descriptor);
        (void)::unlink(temporary.c_str());
        throw;
    }
}

AnalysisCache readAnalysisCache(
    const fs::path &path,
    const std::string &sourceDigest,
    const std::string &inputDigest,
    const std::string &geometryDigest,
    const std::string &selectedFramesDigest,
    const std::string &trainingDigest,
    const std::vector<std::string> &expectedViewIdentities,
    const std::vector<std::string> &expectedViewMaskDigests,
    std::size_t expectedGaussianCount,
    std::size_t maximumBytes
) {
    validateDigest(sourceDigest, "expected source digest");
    validateDigest(inputDigest, "expected input digest");
    validateDigest(geometryDigest, "expected geometry digest");
    validateDigest(selectedFramesDigest, "expected selected-frames digest");
    validateDigest(trainingDigest, "expected training digest");
    if (expectedGaussianCount == 0 ||
        expectedViewIdentities.empty() ||
        expectedViewIdentities.size() > kMaximumCacheViews ||
        expectedViewMaskDigests.size() != expectedViewIdentities.size()) {
        throw CacheValidationError("expected analysis view order is invalid");
    }
    std::set<std::string> uniqueExpectedIdentities;
    for (std::size_t index = 0;
         index < expectedViewIdentities.size();
         ++index) {
        const std::string &identity = expectedViewIdentities[index];
        if (identity.empty() || !uniqueExpectedIdentities.insert(identity).second) {
            throw CacheValidationError("expected analysis view order is invalid");
        }
        validateDigest(
            expectedViewMaskDigests[index],
            "expected analysis view mask digest"
        );
    }
    int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) throw CacheValidationError("analysis cache is unavailable");
    try {
        struct stat status {};
        if (::fstat(descriptor, &status) != 0 ||
            !S_ISREG(status.st_mode) ||
            status.st_nlink != 1 ||
            status.st_size <= 0 ||
            static_cast<std::uint64_t>(status.st_size) > maximumBytes) {
            throw CacheValidationError("analysis cache file is unsafe or exceeds its bound");
        }
        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(status.st_size));
        readExact(descriptor, bytes.data(), bytes.size(), 0);
        closeDescriptor(descriptor);
        CacheReader reader(std::move(bytes));
        for (char expected : kCacheMagic) {
            if (reader.scalar<char>() != expected) {
                throw CacheValidationError("analysis cache magic is invalid");
            }
        }
        if (reader.scalar<std::uint32_t>() != kCacheVersion) {
            throw CacheValidationError("analysis cache version is unsupported");
        }
        AnalysisCache cache;
        cache.sourceDigest = reader.string();
        cache.inputDigest = reader.string();
        cache.geometryDigest = reader.string();
        cache.selectedFramesDigest = reader.string();
        cache.trainingDigest = reader.string();
        if (cache.sourceDigest != sourceDigest ||
            cache.inputDigest != inputDigest ||
            cache.geometryDigest != geometryDigest ||
            cache.selectedFramesDigest != selectedFramesDigest ||
            cache.trainingDigest != trainingDigest) {
            throw CacheValidationError("analysis cache digest binding is stale");
        }
        const std::uint32_t expectedViewCount = reader.scalar<std::uint32_t>();
        if (expectedViewCount == 0 || expectedViewCount > kMaximumCacheViews) {
            throw CacheValidationError("analysis cache expected view count is invalid");
        }
        std::set<std::string> storedExpectedIdentities;
        for (std::uint32_t index = 0; index < expectedViewCount; ++index) {
            const std::string identity = reader.string();
            if (identity.empty() ||
                !storedExpectedIdentities.insert(identity).second) {
                throw CacheValidationError(
                    "analysis cache expected view order is invalid"
                );
            }
            cache.expectedViewIdentities.push_back(identity);
            cache.expectedViewMaskDigests.push_back(reader.string());
            validateDigest(
                cache.expectedViewMaskDigests.back(),
                "stored analysis view mask digest"
            );
        }
        if (cache.expectedViewIdentities != expectedViewIdentities ||
            cache.expectedViewMaskDigests != expectedViewMaskDigests) {
            throw CacheValidationError(
                "analysis cache view or mask binding is stale"
            );
        }
        const std::uint64_t gaussianCount = reader.scalar<std::uint64_t>();
        if (gaussianCount != expectedGaussianCount) {
            throw CacheValidationError(
                "analysis cache Gaussian count is stale"
            );
        }
        cache.gaussianCount = expectedGaussianCount;
        const std::uint32_t viewCount = reader.scalar<std::uint32_t>();
        if (viewCount > cache.expectedViewIdentities.size()) {
            throw CacheValidationError("analysis cache has too many views");
        }
        for (std::uint32_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            ReducedView view;
            view.identity = reader.string();
            if (view.identity != cache.expectedViewIdentities[viewIndex]) {
                throw CacheValidationError(
                    "analysis cache completed views are out of order"
                );
            }
            const std::uint8_t heldOut = reader.scalar<std::uint8_t>();
            if (heldOut > 1) throw CacheValidationError("analysis cache role is invalid");
            view.heldOut = heldOut == 1;
            view.gaussians.resize(cache.gaussianCount);
            for (GaussianViewObservation &gaussian : view.gaussians) {
                gaussian.assignedInstance = reader.scalar<std::uint16_t>();
                const std::uint8_t observed = reader.scalar<std::uint8_t>();
                const std::uint8_t reserved = reader.scalar<std::uint8_t>();
                gaussian.visibleWeight = reader.scalar<double>();
                gaussian.foregroundWeight = reader.scalar<double>();
                gaussian.assignedInstanceWeight = reader.scalar<double>();
                gaussian.projectionCentrality = reader.scalar<double>();
                if (observed > 1 || reserved != 0) {
                    throw CacheValidationError("analysis cache Gaussian is invalid");
                }
                gaussian.sufficientlyObserved = observed == 1;
                validateCachedObservation(
                    gaussian,
                    "analysis cache Gaussian is invalid"
                );
            }
            cache.views.push_back(std::move(view));
        }
        reader.exactEnd();
        return cache;
    } catch (...) {
        closeDescriptor(descriptor);
        throw;
    }
}

} // namespace easysplat::isolation
