// Modified by the EasySplat project in 2026 from msplat 1.1.3.
#include "isolation.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace easysplat::isolation;

namespace {

void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message);
}

void requireNear(double actual, double expected, const std::string &message) {
    if (std::abs(actual - expected) > 1.0e-8) {
        throw std::runtime_error(
            message + ": expected " + std::to_string(expected) +
            ", got " + std::to_string(actual)
        );
    }
}

template <typename Expected, typename Callable>
void requireThrows(Callable &&callable, const std::string &message) {
    try {
        callable();
    } catch (const Expected &) {
        return;
    } catch (const std::exception &error) {
        throw std::runtime_error(
            message + ": wrong exception: " + error.what()
        );
    }
    throw std::runtime_error(message);
}

fs::path temporaryPath(const std::string &name) {
    return fs::temp_directory_path() /
        ("easysplat-isolation-" + name + "-" + std::to_string(::getpid()));
}

LiftedView makeView(
    const std::string &identity,
    std::size_t gaussianCount,
    const std::function<std::uint16_t(std::size_t)> &label,
    double foregroundWeight = 0.9,
    double backgroundWeight = 0.1,
    double centrality = 0.9
) {
    LiftedView view;
    view.identity = identity;
    view.labels = {0, 1, 7};
    view.gaussians.resize(gaussianCount);
    for (std::size_t index = 0; index < gaussianCount; ++index) {
        auto &gaussian = view.gaussians[index];
        gaussian.labelWeights.assign(view.labels.size(), 0.0);
        const std::uint16_t instance = label(index);
        if (instance == 0) {
            gaussian.labelWeights[0] = foregroundWeight + backgroundWeight;
        } else {
            const auto found = std::find(view.labels.begin(), view.labels.end(), instance);
            require(found != view.labels.end(), "fixture label is not declared");
            gaussian.labelWeights[0] = backgroundWeight;
            gaussian.labelWeights[static_cast<std::size_t>(found - view.labels.begin())] =
                foregroundWeight;
        }
        gaussian.centralityWeight = centrality * (foregroundWeight + backgroundWeight);
    }
    return view;
}

std::vector<Point3> twoClusters(std::size_t countPerCluster, double gap = 4.0) {
    std::vector<Point3> points;
    points.reserve(countPerCluster * 2);
    for (std::size_t cluster = 0; cluster < 2; ++cluster) {
        const double offset = cluster == 0 ? 0.0 : gap;
        for (std::size_t index = 0; index < countPerCluster; ++index) {
            points.push_back({
                offset + 0.01 * static_cast<double>(index % 10),
                0.01 * static_cast<double>((index / 10) % 10),
                0.001 * static_cast<double>(index),
            });
        }
    }
    return points;
}

void testAlphaTransmittanceLifting() {
    const std::vector<WeightedPixelContribution> contributions = {
        {0, 1, 0.50, 0.80, 0.75},
        {0, 1, 0.10, 0.30, 0.50}, // 0.03 is below the 0.04 contribution floor.
        {0, 0, 0.25, 0.40, 0.25},
        {1, 7, 0.20, 0.50, 0.90},
    };
    const LiftedView lifted = liftContributions("frame-0001.png", 2, contributions);
    require(lifted.labels == std::vector<std::uint16_t>({0, 1, 7}),
            "labels are not canonical and deterministic");
    requireNear(lifted.gaussians[0].labelWeights[0], 0.10, "background lift changed");
    requireNear(lifted.gaussians[0].labelWeights[1], 0.40, "foreground lift changed");
    requireNear(lifted.gaussians[0].centralityWeight, 0.325, "centrality lift changed");
    requireNear(lifted.gaussians[1].labelWeights[2], 0.10, "frame-local label lift changed");
}

void testPolicyThresholdBoundaries() {
    const double metalContributionFloor = static_cast<double>(0.04f);
    const LiftedView contributionBoundary = liftContributions(
        "threshold.png",
        1,
        {
            {0, 1, metalContributionFloor, 1.0, 1.0},
            {
                0,
                7,
                std::nextafter(metalContributionFloor, 0.0),
                1.0,
                1.0,
            },
        }
    );
    require(contributionBoundary.labels == std::vector<std::uint16_t>({0, 1}),
            "Metal float contribution boundary changed");
    const ReducedView contributionBoundaryReduced =
        reduceLiftedView(contributionBoundary);
    require(
        contributionBoundaryReduced.gaussians[0].sufficientlyObserved &&
            contributionBoundaryReduced.gaussians[0].assignedInstance == 1,
        "Metal float contribution boundary did not produce an observation assignment"
    );

    LiftedView assignment;
    assignment.identity = "assignment.png";
    assignment.labels = {0, 1};
    assignment.gaussians.resize(2);
    assignment.gaussians[0].labelWeights = {0.45, 0.55};
    assignment.gaussians[1].labelWeights = {0.450001, 0.549999};
    const ReducedView reduced = reduceLiftedView(assignment);
    require(reduced.gaussians[0].assignedInstance == 1,
            "0.55 instance-share boundary was rejected");
    require(reduced.gaussians[1].assignedInstance == 0,
            "sub-0.55 instance share did not abstain");

    LiftedView classification;
    classification.identity = "classification.png";
    classification.labels = {0, 1};
    classification.gaussians.resize(5);
    classification.gaussians[0].labelWeights = {0.35, 0.65};
    classification.gaussians[1].labelWeights = {0.65, 0.35};
    classification.gaussians[2].labelWeights = {0.50, 0.50};
    classification.gaussians[3].labelWeights = {0.350001, 0.649999};
    classification.gaussians[4].labelWeights = {0.649999, 0.350001};
    const auto classes = classifyGaussians({reduceLiftedView(classification)});
    require(classes[0].classification == GaussianClass::foreground,
            "0.65 foreground boundary was rejected");
    require(classes[1].classification == GaussianClass::background,
            "0.35 background boundary was rejected");
    require(classes[2].classification == GaussianClass::uncertain,
            "uncertain classification band changed");
    require(classes[3].classification == GaussianClass::uncertain,
            "foreground probability below 0.65 was classified as foreground");
    require(classes[4].classification == GaussianClass::uncertain,
            "foreground probability above 0.35 was classified as background");

    ReducedView observed;
    observed.identity = "observed.png";
    observed.gaussians = {{1, 1.0, 0.65, 0.65, 0.5, true}};
    ReducedView insufficient;
    insufficient.identity = "insufficient.png";
    insufficient.gaussians = {{0, 100.0, 0.0, 0.0, 0.5, false}};
    require(
        classifyGaussians({observed, insufficient})[0].classification ==
            GaussianClass::foreground,
        "insufficiently observed view changed the cross-view denominator"
    );

    requireNear(componentRankScore(0.6, 0.5, 0.25), 0.50,
                "component ranking weights changed");
    require(autoSelectionAllowed(0.60, 0.15, 0.001),
            "inclusive lower auto-selection boundaries were rejected");
    require(autoSelectionAllowed(0.60, 0.15, 0.90),
            "inclusive upper retained boundary was rejected");
    require(!autoSelectionAllowed(0.599999, 0.15, 0.5),
            "sub-threshold coverage was accepted");
    require(!autoSelectionAllowed(0.60, 0.149999, 0.5),
            "sub-threshold lead was accepted");
    require(!autoSelectionAllowed(0.60, 0.15, 0.000999),
            "retained fraction below 0.001 was accepted");
    require(!autoSelectionAllowed(0.60, 0.15, 0.900001),
            "retained fraction above 0.90 was accepted");
    require(!shouldPruneAsBackground(0.80),
            "inclusive 0.80 background fraction was pruned");
    require(shouldPruneAsBackground(0.800001),
            "background fraction above 0.80 was retained");
    require(minimumComponentSize(63) == 64,
            "63-source component floor is not 64");
    require(minimumComponentSize(64) == 64,
            "64-source component floor is not inclusive");
    require(minimumComponentSize(64'000) == 64,
            "64,000-source proportional floor changed");
    require(minimumComponentSize(64'001) == 65,
            "64,001-source proportional floor did not round up");
}

GaussianEvidence graphEvidence(
    std::initializer_list<std::pair<std::uint16_t, bool>> observations,
    double foregroundProbability = 0.9
) {
    GaussianEvidence evidence;
    evidence.classification = GaussianClass::foreground;
    evidence.foregroundProbability = foregroundProbability;
    for (const auto &[instance, observed] : observations) {
        evidence.observations.push_back({
            instance,
            observed ? 1.0 : 0.0,
            observed ? 0.9 : 0.0,
            observed && instance != 0 ? 0.9 : 0.0,
            0.5,
            observed,
        });
    }
    return evidence;
}

void testGraphThresholdBoundaries() {
    const GaussianEvidence left = graphEvidence({{1, true}, {1, true}, {1, true}, {7, true}, {7, true}});
    const GaussianEvidence right = graphEvidence({{1, true}, {1, true}, {1, true}, {3, true}, {3, true}});
    require(graphEdgeAllowed(2.5, 1.0, 1.0, left, right),
            "2.5 local-distance and 0.60 agreement boundaries were rejected");
    require(!graphEdgeAllowed(2.500001, 1.0, 1.0, left, right),
            "distance above 2.5 local distance was accepted");
    const GaussianEvidence belowAgreement =
        graphEvidence({{1, true}, {1, true}, {3, true}, {3, true}, {3, true}}, 0.7);
    require(!graphEdgeAllowed(2.5, 1.0, 1.0, left, belowAgreement),
            "normal graph path accepted agreement below 0.60");

    const GaussianEvidence oneObservation =
        graphEvidence({{1, true}, {0, false}}, 0.8);
    require(graphEdgeAllowed(1.5, 1.0, 1.0, oneObservation, oneObservation),
            "1.5 close fallback boundary was rejected");
    require(!graphEdgeAllowed(1.500001, 1.0, 1.0, oneObservation, oneObservation),
            "distance above 1.5 close fallback was accepted");

    const GaussianEvidence lowConfidence =
        graphEvidence({{1, true}}, 0.799999);
    require(!graphEdgeAllowed(1.0, 1.0, 1.0, lowConfidence, lowConfidence),
            "close fallback accepted foreground probability below 0.80");

    const GaussianEvidence oneCommonLeft =
        graphEvidence({{1, true}, {0, false}}, 0.7);
    const GaussianEvidence oneCommonRight =
        graphEvidence({{1, true}, {0, false}}, 0.7);
    require(!graphEdgeAllowed(1.0, 1.0, 1.0, oneCommonLeft, oneCommonRight),
            "normal graph path accepted fewer than two common observations");
    const GaussianEvidence contradictionLeft =
        graphEvidence({{1, true}}, 0.8);
    const GaussianEvidence contradictionRight =
        graphEvidence({{7, true}}, 0.8);
    require(!graphEdgeAllowed(
                1.0,
                1.0,
                1.0,
                contradictionLeft,
                contradictionRight
            ),
            "close fallback accepted contradictory assigned instances");
}

SelectionResult selectionAtCoverage(std::size_t coveredViewCount) {
    constexpr std::size_t subjectCount = 64;
    constexpr std::size_t sourceCount = 72;
    constexpr std::size_t viewCount = 10;
    std::vector<Point3> points;
    points.reserve(sourceCount);
    for (std::size_t index = 0; index < sourceCount; ++index) {
        points.push_back({
            index < subjectCount
                ? 0.001 * static_cast<double>(index)
                : 10.0 + static_cast<double>(index),
            0,
            0,
        });
    }
    std::vector<ReducedView> views(viewCount);
    for (std::size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
        ReducedView &view = views[viewIndex];
        view.identity = "coverage-" + std::to_string(viewIndex) + ".png";
        view.gaussians.resize(sourceCount);
        for (std::size_t index = 0; index < sourceCount; ++index) {
            GaussianViewObservation &observation = view.gaussians[index];
            if (index < subjectCount && viewIndex < coveredViewCount) {
                observation = {1, 1.0, 0.9, 0.9, 0.5, true};
            } else if (index >= subjectCount) {
                observation = {0, 1.0, 0.0, 0.0, 0.5, true};
            }
        }
    }
    return selectSubject(
        points,
        classifyGaussians(views),
        views,
        Anchor{"coverage-0.png", 1},
        {1.0}
    );
}

void testNoSubjectCoverageBoundary() {
    require(selectionAtCoverage(3).outcome == SelectionOutcome::selected,
            "exact 0.30 component coverage was treated as no subject");
    require(selectionAtCoverage(2).outcome == SelectionOutcome::noSubject,
            "component coverage below 0.30 was not treated as no subject");
}

SelectionResult selectionWithComponentSize(std::size_t componentSize) {
    constexpr std::size_t sourceCount = 72;
    std::vector<Point3> points;
    points.reserve(sourceCount);
    ReducedView view;
    view.identity = "component-floor.png";
    view.gaussians.resize(sourceCount);
    for (std::size_t index = 0; index < sourceCount; ++index) {
        points.push_back({
            index < componentSize
                ? 0.001 * static_cast<double>(index)
                : 10.0 + static_cast<double>(index),
            0,
            0,
        });
        view.gaussians[index] = index < componentSize
            ? GaussianViewObservation{1, 1.0, 0.9, 0.9, 0.5, true}
            : GaussianViewObservation{0, 1.0, 0.0, 0.0, 0.5, true};
    }
    return selectSubject(
        points,
        classifyGaussians({view}),
        {view},
        Anchor{"component-floor.png", 1},
        {1.0}
    );
}

void testMinimumComponentMembershipBoundary() {
    require(selectionWithComponentSize(63).outcome == SelectionOutcome::noSubject,
            "63-Gaussian component passed the 64-Gaussian floor");
    require(selectionWithComponentSize(64).outcome == SelectionOutcome::selected,
            "64-Gaussian component failed the inclusive component floor");
}

void testNoSubjectConsidersEveryComponent() {
    constexpr std::size_t componentSize = 64;
    constexpr std::size_t viewCount = 10;
    const std::vector<Point3> points = twoClusters(componentSize);
    std::vector<ReducedView> views(viewCount);
    for (std::size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
        ReducedView &view = views[viewIndex];
        view.identity = "all-components-" + std::to_string(viewIndex) + ".png";
        view.gaussians.resize(points.size());
        for (std::size_t index = 0; index < points.size(); ++index) {
            if (index < componentSize && viewIndex < 2) {
                view.gaussians[index] = {1, 10.0, 10.0, 10.0, 1.0, true};
            } else if (index >= componentSize && viewIndex < 3) {
                view.gaussians[index] = {7, 1.0, 1.0, 1.0, 0.0, true};
            }
        }
    }
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(views),
        views,
        Anchor{"all-components-0.png", 7},
        {0.0, 1.0}
    );
    require(result.outcome == SelectionOutcome::selected,
            "a lower-ranked component at 0.30 coverage was treated as no subject");
    require(!result.selectedIndices.empty() &&
                result.selectedIndices.front() == componentSize,
            "anchor did not select the qualifying lower-ranked component");
}

void testFrameLocalIdentifiersDoNotNeedCrossFrameIdentity() {
    constexpr std::size_t count = 72;
    const std::vector<Point3> points = twoClusters(count);
    std::vector<LiftedView> views;
    views.push_back(makeView("frame-a.png", points.size(), [=](std::size_t index) {
        return index < count ? 1 : 7;
    }));
    views.push_back(makeView("frame-b.png", points.size(), [=](std::size_t index) {
        return index < count ? 7 : 1;
    }));
    const auto reduced = reduceLiftedViews(views);
    const auto evidence = classifyGaussians(reduced);
    const SelectionResult result = selectSubject(points, evidence, reduced, std::nullopt);
    require(result.outcome == SelectionOutcome::ambiguous,
            "two equally supported subjects should remain ambiguous");
    require(result.components.size() == 2, "frame-local ID changes split a 3D component");
    require(result.components[0].indices.size() == count, "first component size changed");
    require(result.components[1].indices.size() == count, "second component size changed");
}

void testTwoCenteredObjectsRemainAmbiguous() {
    constexpr std::size_t count = 72;
    const std::vector<Point3> points = twoClusters(count);
    std::vector<LiftedView> views;
    for (int frame = 0; frame < 4; ++frame) {
        views.push_back(makeView(
            "centered-" + std::to_string(frame) + ".png",
            points.size(),
            [=](std::size_t index) { return index < count ? 1 : 7; },
            0.9,
            0.1,
            0.95
        ));
    }
    const auto reduced = reduceLiftedViews(views);
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(reduced),
        reduced,
        std::nullopt
    );
    require(result.outcome == SelectionOutcome::ambiguous,
            "equal centered objects were auto-selected");
    require(result.components.size() == 2, "centered object evidence was lost");
    require(result.components[0].keyframeContributions.size() == 4,
            "ambiguity omitted keyframe/instance evidence");
}

void testTouchingSurfacesRequireInstanceAgreement() {
    constexpr std::size_t count = 72;
    std::vector<Point3> points = twoClusters(count, 0.12);
    std::vector<LiftedView> views;
    for (int frame = 0; frame < 3; ++frame) {
        views.push_back(makeView(
            "touching-" + std::to_string(frame) + ".png",
            points.size(),
            [=](std::size_t index) { return index < count ? 1 : 7; }
        ));
    }
    const auto reduced = reduceLiftedViews(views);
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(reduced),
        reduced,
        std::nullopt
    );
    require(result.components.size() == 2,
            "proximity joined touching surfaces with different frame-local instances");
}

void testThinHighConfidenceStructureUsesCloseFallback() {
    constexpr std::size_t subjectCount = 80;
    constexpr std::size_t count = 90;
    std::vector<Point3> points;
    points.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        points.push_back({
            index < subjectCount
                ? 0.01 * static_cast<double>(index)
                : 10.0 + static_cast<double>(index),
            0.0,
            0.0,
        });
    }
    std::vector<LiftedView> views = {
        makeView("thin.png", count, [](std::size_t index) {
            return index < subjectCount ? 1 : 0;
        }, 0.95, 0.05),
    };
    const auto reduced = reduceLiftedViews(views);
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(reduced),
        reduced,
        Anchor{"thin.png", 1},
        {1.0}
    );
    require(result.outcome == SelectionOutcome::selected,
            "high-confidence thin structure did not use the close fallback");
    require(result.selectedIndices.size() == subjectCount, "thin structure was fragmented");
}

void testUncertainBoundaryRepairIsBoundedToTwoPasses() {
    constexpr std::size_t count = 70;
    std::vector<GaussianEvidence> evidence(count);
    for (std::size_t index = 0; index < count; ++index) {
        evidence[index].classification = index < 64
            ? GaussianClass::foreground
            : (index < 67 ? GaussianClass::uncertain : GaussianClass::background);
    }
    std::vector<NeighborList> neighbors(count);
    for (std::size_t index = 0; index < 64; ++index) {
        for (std::size_t slot = 0; slot < kNeighborCount; ++slot) {
            neighbors[index][slot] = (index + slot + 1) % 64;
        }
    }
    for (std::size_t slot = 0; slot < kNeighborCount; ++slot) {
        neighbors[64][slot] = slot < 13 ? slot : 65 + (slot - 13);
        neighbors[65][slot] = slot < 12 ? slot : 64 + (slot - 12);
        if (slot < 11) {
            neighbors[66][slot] = slot;
        } else {
            constexpr std::array<std::size_t, 5> boundaryNeighbors = {64, 65, 67, 68, 69};
            neighbors[66][slot] = boundaryNeighbors[slot - 11];
        }
    }
    for (std::size_t index = 67; index < count; ++index) {
        for (std::size_t slot = 0; slot < kNeighborCount; ++slot) {
            neighbors[index][slot] = (index + slot + 1) % count;
        }
    }
    std::vector<bool> selected(count, false);
    std::fill(selected.begin(), selected.begin() + 64, true);
    repairUncertainGaussians(neighbors, evidence, selected);
    require(selected[64], "first repair pass did not restore an 0.80-supported boundary");
    require(selected[65], "second repair pass did not restore a newly supported boundary");
    require(!selected[66], "repair continued beyond two passes");
}

void testUncertainRepairCountsUniqueNeighbors() {
    constexpr std::size_t count = 18;
    std::vector<GaussianEvidence> evidence(count);
    for (std::size_t index = 0; index < count; ++index) {
        evidence[index].classification = index < 13
            ? GaussianClass::foreground
            : GaussianClass::uncertain;
    }
    std::vector<NeighborList> neighbors(count);
    for (NeighborList &list : neighbors) list.fill(17);
    for (std::size_t slot = 0; slot < 12; ++slot) {
        neighbors[13][slot] = slot;
    }
    for (std::size_t slot = 12; slot < kNeighborCount; ++slot) {
        neighbors[13][slot] = 0;
    }
    for (std::size_t slot = 0; slot < 13; ++slot) {
        neighbors[14][slot] = slot;
    }
    for (std::size_t slot = 13; slot < kNeighborCount; ++slot) {
        neighbors[14][slot] = 0;
    }
    std::vector<bool> selected(count, false);
    std::fill(selected.begin(), selected.begin() + 13, true);
    repairUncertainGaussians(neighbors, evidence, selected);
    require(!selected[13],
            "duplicate entries inflated 12 unique selected neighbors to 13");
    require(selected[14],
            "13 unique selected neighbors did not repair an uncertain Gaussian");
}

void testDeterministicGraphSelectionAndAnchorResolution() {
    constexpr std::size_t count = 72;
    const std::vector<Point3> points = twoClusters(count);
    std::vector<LiftedView> views;
    for (int frame = 0; frame < 4; ++frame) {
        LiftedView view = makeView(
            "anchor-" + std::to_string(frame) + ".png",
            points.size(),
            [=](std::size_t index) { return index < count ? 1 : 7; }
        );
        for (std::size_t index = count; index < points.size(); ++index) {
            view.gaussians[index].labelWeights = {0.01, 0.0, 0.09};
            view.gaussians[index].centralityWeight = 0.05;
        }
        views.push_back(std::move(view));
    }
    const auto reduced = reduceLiftedViews(views);
    const auto evidence = classifyGaussians(reduced);
    const SelectionResult first = selectSubject(points, evidence, reduced, std::nullopt);
    const SelectionResult second = selectSubject(points, evidence, reduced, std::nullopt);
    require(first.outcome == SelectionOutcome::selected, "dominant component was not selected");
    require(first.selectedIndices == second.selectedIndices,
            "graph selection changed across identical runs");

    const SelectionResult anchored = selectSubject(
        points,
        evidence,
        reduced,
        Anchor{"anchor-0.png", 7},
        {0.0, 1.0}
    );
    require(anchored.outcome == SelectionOutcome::selected, "valid anchor was not resolved");
    require(!anchored.selectedIndices.empty() && anchored.selectedIndices.front() >= count,
            "anchor did not choose the component with greatest instance contribution");

    const SelectionResult subWinningAnchor = selectSubject(
        points,
        evidence,
        reduced,
        Anchor{"anchor-0.png", 7},
        {2.0, 1.0}
    );
    require(
        subWinningAnchor.outcome == SelectionOutcome::selected &&
            !subWinningAnchor.selectedIndices.empty() &&
            subWinningAnchor.selectedIndices.front() < count,
        "anchor ignored exact sub-winning label weight from the selected frame"
    );
}

void testAsymmetricNeighborMembershipStillConnectsTheGraph() {
    constexpr std::size_t sourceCount = 80;
    constexpr std::size_t foregroundCount = 64;
    std::vector<Point3> points;
    points.reserve(sourceCount);
    for (std::size_t index = 0; index < 48; ++index) {
        points.push_back({0.001 * static_cast<double>(index), 0, 0});
    }
    for (std::size_t index = 0; index < 16; ++index) {
        points.push_back({0.067 + 0.001 * static_cast<double>(index), 0, 0});
    }
    for (std::size_t index = foregroundCount; index < sourceCount; ++index) {
        points.push_back({10.0 + static_cast<double>(index), 0, 0});
    }

    std::vector<LiftedView> views;
    for (int frame = 0; frame < 3; ++frame) {
        views.push_back(makeView(
            "asymmetric-" + std::to_string(frame) + ".png",
            sourceCount,
            [](std::size_t index) {
                return index < foregroundCount
                    ? static_cast<std::uint16_t>(1)
                    : static_cast<std::uint16_t>(0);
            }
        ));
    }
    const auto reduced = reduceLiftedViews(views);
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(reduced),
        reduced,
        std::nullopt
    );
    require(
        result.outcome == SelectionOutcome::selected &&
            result.selectedIndices.size() == foregroundCount,
        "an asymmetric listed 16-neighbor edge was dropped from the foreground graph"
    );
}

void testAdaptiveLocalDistanceRejectsASparseBridge() {
    constexpr std::size_t sourceCount = 80;
    constexpr std::size_t foregroundCount = 64;
    std::vector<Point3> points;
    points.reserve(sourceCount);
    for (std::size_t index = 0; index < 48; ++index) {
        points.push_back({0.001 * static_cast<double>(index), 0, 0});
    }
    for (std::size_t index = 0; index < 16; ++index) {
        points.push_back({0.077 + 0.001 * static_cast<double>(index), 0, 0});
    }
    for (std::size_t index = foregroundCount; index < sourceCount; ++index) {
        points.push_back({10.0 + static_cast<double>(index), 0, 0});
    }

    std::vector<LiftedView> views;
    for (int frame = 0; frame < 3; ++frame) {
        views.push_back(makeView(
            "sparse-bridge-" + std::to_string(frame) + ".png",
            sourceCount,
            [](std::size_t index) {
                return index < foregroundCount
                    ? static_cast<std::uint16_t>(1)
                    : static_cast<std::uint16_t>(0);
            }
        ));
    }
    const auto reduced = reduceLiftedViews(views);
    const SelectionResult result = selectSubject(
        points,
        classifyGaussians(reduced),
        reduced,
        std::nullopt
    );
    require(
        result.outcome == SelectionOutcome::noSubject,
        "the farthest listed neighbor made the adaptive distance gate vacuous"
    );
}

void writeFixturePly(const fs::path &path) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.exceptions(std::ios::failbit | std::ios::badbit);
    output
        << "ply\n"
        << "format binary_little_endian 1.0\n"
        << "comment attribute preservation fixture\n"
        << "element vertex 3\n"
        << "property float x\nproperty float y\nproperty float z\n"
        << "property float nx\nproperty float ny\nproperty float nz\n"
        << "property float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\n"
        << "property float opacity\n"
        << "property float scale_0\nproperty float scale_1\nproperty float scale_2\n"
        << "property float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\n"
        << "property ushort confidence\n"
        << "end_header\n";
    for (std::uint16_t rowIndex = 0; rowIndex < 3; ++rowIndex) {
        std::array<float, 17> row {};
        row[0] = static_cast<float>(rowIndex + 1);
        row[1] = static_cast<float>(rowIndex + 2);
        row[2] = static_cast<float>(rowIndex + 3);
        row[9] = 1.0f;
        row[13] = 1.0f;
        output.write(reinterpret_cast<const char *>(row.data()), sizeof(row));
        const std::uint16_t confidence = static_cast<std::uint16_t>(500 + rowIndex);
        output.write(reinterpret_cast<const char *>(&confidence), sizeof(confidence));
    }
}

void writeNonfiniteDoubleFixturePly(const fs::path &path) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.exceptions(std::ios::failbit | std::ios::badbit);
    output
        << "ply\n"
        << "format binary_little_endian 1.0\n"
        << "element vertex 1\n"
        << "property float x\nproperty float y\nproperty float z\n"
        << "property float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\n"
        << "property float opacity\n"
        << "property float scale_0\nproperty float scale_1\nproperty float scale_2\n"
        << "property float rot_0\nproperty float rot_1\nproperty float rot_2\n"
        << "property float rot_3\n"
        << "property double quality\n"
        << "end_header\n";
    std::array<float, 14> gaussian {};
    gaussian[6] = 1.0f;
    gaussian[10] = 1.0f;
    output.write(
        reinterpret_cast<const char *>(gaussian.data()),
        sizeof(gaussian)
    );
    const double nonfinite = std::numeric_limits<double>::quiet_NaN();
    output.write(
        reinterpret_cast<const char *>(&nonfinite),
        sizeof(nonfinite)
    );
}

std::vector<std::uint8_t> readBytes(const fs::path &path) {
    std::ifstream input(path, std::ios::binary);
    return {
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>(),
    };
}

void testBinaryPlyRowsPreserveEveryAttributeAndSource() {
    const fs::path source = temporaryPath("source.ply");
    const fs::path output = temporaryPath("filtered.ply");
    fs::remove(source);
    fs::remove(output);
    writeFixturePly(source);
    const std::vector<std::uint8_t> sourceBefore = readBytes(source);
    const BinaryPly ply = inspectBinaryPly(source, 1 << 20);
    require(ply.vertexCount == 3 && ply.rowBytes == 70, "fixture PLY layout changed");
    const FilteredPlyReceipt receipt = writeFilteredBinaryPly(
        ply,
        output,
        {0, 2},
        [] { return false; }
    );
    require(receipt.bounds.finite, "filtered PLY bounds are not finite");
    require(
        receipt.outputDevice != 0 &&
            receipt.outputInode != 0 &&
            receipt.outputBytes == fs::file_size(output),
        "filtered PLY publication receipt is incomplete"
    );
    require(readBytes(source) == sourceBefore, "source PLY changed during filtering");

    const BinaryPly filtered = inspectBinaryPly(output, 1 << 20);
    require(filtered.vertexCount == 2, "filtered PLY vertex count is wrong");
    const std::string expectedHeader =
        ply.headerPrefixBeforeVertexCount + "2" + ply.headerSuffixAfterVertexCount;
    require(
        filtered.header == std::vector<std::uint8_t>(
            expectedHeader.begin(),
            expectedHeader.end()
        ),
        "filtered PLY changed header bytes other than the vertex count"
    );
    const auto sourceRows = readVertexRows(ply, {0, 2});
    const auto filteredRows = readVertexRows(filtered, {0, 1});
    require(sourceRows == filteredRows, "surviving PLY attributes changed byte-for-byte");
    fs::remove(source);
    fs::remove(output);
}

void writeBytes(const fs::path &path, const std::vector<std::uint8_t> &bytes);

void testBinaryPlyPendingCollisionIsPreserved() {
    const fs::path source = temporaryPath("pending-source.ply");
    const fs::path output = temporaryPath("pending-output.ply");
    const fs::path pending = output.parent_path() /
        ("." + output.filename().string() + ".isolation." +
         std::to_string(::getpid()) + ".pending");
    fs::remove(source);
    fs::remove(output);
    fs::remove(pending);
    writeFixturePly(source);
    const std::vector<std::uint8_t> collisionBefore = {'k', 'e', 'e', 'p'};
    writeBytes(pending, collisionBefore);
    requireThrows<PlyValidationError>(
        [&] {
            (void)writeFilteredBinaryPly(
                inspectBinaryPly(source, 1 << 20),
                output,
                {0},
                [] { return false; }
            );
        },
        "existing PLY staging collision was accepted"
    );
    require(
        readBytes(pending) == collisionBefore,
        "pre-existing PLY staging collision was removed or changed"
    );
    require(!fs::exists(output), "staging collision published an output");
    fs::remove(source);
    fs::remove(pending);
}

void writeBytes(const fs::path &path, const std::vector<std::uint8_t> &bytes) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.exceptions(std::ios::failbit | std::ios::badbit);
    output.write(
        reinterpret_cast<const char *>(bytes.data()),
        static_cast<std::streamsize>(bytes.size())
    );
}

void testBinaryPlyRejectsMalformedUnsafeAndCollidingInputs() {
    const fs::path valid = temporaryPath("strict-source.ply");
    const fs::path malformed = temporaryPath("malformed.ply");
    const fs::path list = temporaryPath("list.ply");
    const fs::path trailing = temporaryPath("trailing.ply");
    const fs::path nonfinite = temporaryPath("nonfinite.ply");
    const fs::path extraNonfinite = temporaryPath("extra-nonfinite.ply");
    const fs::path doubleNonfinite = temporaryPath("double-nonfinite.ply");
    const fs::path hardlink = temporaryPath("hardlink.ply");
    const fs::path collision = temporaryPath("collision.ply");
    for (const fs::path &path :
         {valid, malformed, list, trailing, nonfinite, extraNonfinite,
          doubleNonfinite, hardlink, collision}) {
        fs::remove(path);
    }
    writeFixturePly(valid);
    const BinaryPly inspected = inspectBinaryPly(valid, 1 << 20);
    const std::vector<std::uint8_t> validBytes = readBytes(valid);

    std::vector<std::uint8_t> malformedBytes = validBytes;
    const std::string validCount = "element vertex 3";
    const auto malformedAt = std::search(
        malformedBytes.begin(),
        malformedBytes.end(),
        validCount.begin(),
        validCount.end()
    );
    require(malformedAt != malformedBytes.end(), "fixture vertex line disappeared");
    const std::string malformedCount = "element vertex x";
    std::copy(malformedCount.begin(), malformedCount.end(), malformedAt);
    writeBytes(malformed, malformedBytes);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(malformed, 1 << 20); },
        "malformed vertex count was accepted"
    );

    const std::string header(
        validBytes.begin(),
        validBytes.begin() +
            static_cast<std::ptrdiff_t>(inspected.vertexDataOffset)
    );
    std::string listHeader = header;
    const std::string scalarProperty = "property float nx\n";
    const std::size_t propertyAt = listHeader.find(scalarProperty);
    require(propertyAt != std::string::npos, "fixture scalar property disappeared");
    listHeader.replace(propertyAt, scalarProperty.size(), "property list uchar float nx\n");
    std::vector<std::uint8_t> listBytes(listHeader.begin(), listHeader.end());
    listBytes.insert(
        listBytes.end(),
        validBytes.begin() + static_cast<std::ptrdiff_t>(inspected.vertexDataOffset),
        validBytes.end()
    );
    writeBytes(list, listBytes);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(list, 1 << 20); },
        "list-valued vertex property was accepted"
    );

    std::vector<std::uint8_t> trailingBytes = validBytes;
    trailingBytes.push_back(0);
    writeBytes(trailing, trailingBytes);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(trailing, 1 << 20); },
        "trailing PLY payload bytes were accepted"
    );

    std::vector<std::uint8_t> nonfiniteBytes = validBytes;
    const float quietNaN = std::numeric_limits<float>::quiet_NaN();
    std::memcpy(
        nonfiniteBytes.data() + inspected.vertexDataOffset + inspected.xOffset,
        &quietNaN,
        sizeof(quietNaN)
    );
    writeBytes(nonfinite, nonfiniteBytes);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(nonfinite, 1 << 20); },
        "non-finite required Gaussian property was accepted"
    );

    const auto extraFloatOffset = std::find_if(
        inspected.allFloatOffsets.begin(),
        inspected.allFloatOffsets.end(),
        [&](std::size_t offset) {
            return std::find(
                inspected.finiteFloatOffsets.begin(),
                inspected.finiteFloatOffsets.end(),
                offset
            ) == inspected.finiteFloatOffsets.end();
        }
    );
    require(extraFloatOffset != inspected.allFloatOffsets.end(),
            "fixture no longer contains an extra float attribute");
    std::vector<std::uint8_t> extraNonfiniteBytes = validBytes;
    std::memcpy(
        extraNonfiniteBytes.data() +
            inspected.vertexDataOffset +
            *extraFloatOffset,
        &quietNaN,
        sizeof(quietNaN)
    );
    writeBytes(extraNonfinite, extraNonfiniteBytes);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(extraNonfinite, 1 << 20); },
        "non-finite extra float attribute was accepted"
    );

    writeNonfiniteDoubleFixturePly(doubleNonfinite);
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(doubleNonfinite, 1 << 20); },
        "non-finite float64 attribute was accepted"
    );

    require(::link(valid.c_str(), hardlink.c_str()) == 0,
            "could not create PLY hard-link fixture");
    requireThrows<PlyValidationError>(
        [&] { (void)inspectBinaryPly(valid, 1 << 20); },
        "multi-link source PLY was accepted"
    );
    fs::remove(hardlink);
    const std::vector<std::uint8_t> collisionBefore = {'k', 'e', 'e', 'p'};
    writeBytes(collision, collisionBefore);
    requireThrows<PlyValidationError>(
        [&] {
            (void)writeFilteredBinaryPly(
                inspectBinaryPly(valid, 1 << 20),
                collision,
                {0},
                [] { return false; }
            );
        },
        "existing output collision was overwritten"
    );
    require(readBytes(collision) == collisionBefore,
            "output collision contents changed");
    require(readBytes(valid) == validBytes,
            "strict PLY rejection changed the source");

    for (const fs::path &path :
         {valid, malformed, list, trailing, nonfinite, extraNonfinite,
          doubleNonfinite, collision}) {
        fs::remove(path);
    }
}

void testMemoryAdmissionAndCancellationPreserveSource() {
    bool rejected = false;
    try {
        (void)requiredWorkingSetBytes(
            std::numeric_limits<std::size_t>::max() / 2,
            64,
            4096,
            4096,
            256
        );
    } catch (const MemoryLimitError &) {
        rejected = true;
    }
    require(rejected, "overflowing isolation working set was admitted");
    const std::size_t required =
        requiredWorkingSetBytes(100, 8, 64, 64, 70);
    enforceMemoryBudget(required, required);
    requireThrows<MemoryLimitError>(
        [&] { enforceMemoryBudget(required, required - 1); },
        "working set one byte above the budget was admitted"
    );

    const fs::path source = temporaryPath("cancel-source.ply");
    const fs::path output = temporaryPath("cancel-output.ply");
    fs::remove(source);
    fs::remove(output);
    writeFixturePly(source);
    const auto sourceBefore = readBytes(source);
    const BinaryPly header = inspectBinaryPlyHeader(source, 1 << 20);
    require(
        header.vertexCount == 3 && header.rowBytes == 70,
        "header-only PLY inspection changed the admitted layout"
    );
    requireThrows<MemoryLimitError>(
        [&] {
            enforceMemoryBudget(
                requiredWorkingSetBytes(
                    static_cast<std::size_t>(header.vertexCount),
                    8,
                    4096,
                    4096,
                    header.rowBytes
                ),
                4096
            );
        },
        "oversized isolation working set reached PLY row traversal"
    );
    int scanPolls = 0;
    requireThrows<CancellationError>(
        [&] {
            validateBinaryPlyRows(
                header,
                [&] { return ++scanPolls == 1; }
            );
        },
        "PLY attribute scan ignored cancellation"
    );
    require(scanPolls == 1, "PLY attribute scan did not poll cancellation promptly");
    require(
        readBytes(source) == sourceBefore,
        "cancelled PLY attribute scan changed the source PLY"
    );
    const BinaryPly ply = inspectBinaryPly(source, 1 << 20);
    int polls = 0;
    bool cancelled = false;
    try {
        (void)writeFilteredBinaryPly(
            ply,
            output,
            {0, 1, 2},
            [&] { return ++polls >= 2; }
        );
    } catch (const CancellationError &) {
        cancelled = true;
    }
    require(cancelled, "PLY filter ignored cancellation");
    require(!fs::exists(output), "cancelled PLY filter published output");
    require(readBytes(source) == sourceBefore, "cancellation changed the source PLY");
    fs::remove(source);
}

void testAnalysisCacheReuseAndCorruptionRejection() {
    const fs::path cachePath = temporaryPath("analysis.cache");
    fs::remove(cachePath);
    AnalysisCache cache;
    cache.sourceDigest = std::string(64, 'a');
    cache.inputDigest = std::string(64, 'b');
    cache.geometryDigest = std::string(64, 'c');
    cache.selectedFramesDigest = std::string(64, 'd');
    cache.trainingDigest = std::string(64, 'e');
    cache.expectedViewIdentities = {"cached-a.png", "cached-b.png"};
    cache.expectedViewMaskDigests = {
        std::string(64, 'f'),
        std::string(64, '0'),
    };
    cache.gaussianCount = 2;
    cache.views.push_back(reduceLiftedView(liftContributions(
        "cached-a.png",
        2,
        {{0, 1, 0.5, 0.5, 1.0}}
    )));
    writeAnalysisCacheAtomically(cachePath, cache);
    AnalysisCache restored = readAnalysisCache(
        cachePath,
        cache.sourceDigest,
        cache.inputDigest,
        cache.geometryDigest,
        cache.selectedFramesDigest,
        cache.trainingDigest,
        cache.expectedViewIdentities,
        cache.expectedViewMaskDigests,
        cache.gaussianCount,
        1 << 20
    );
    require(restored.views.size() == 1, "partial analysis cache was not reusable");
    restored.views.push_back(reduceLiftedView(liftContributions(
        "cached-b.png",
        2,
        {{1, 7, 0.8, 0.8, 1.0}}
    )));
    writeAnalysisCacheAtomically(cachePath, restored);
    require(
        readAnalysisCache(
            cachePath,
            cache.sourceDigest,
            cache.inputDigest,
            cache.geometryDigest,
            cache.selectedFramesDigest,
            cache.trainingDigest,
            cache.expectedViewIdentities,
            cache.expectedViewMaskDigests,
            cache.gaussianCount,
            1 << 20
        ).views.size() == 2,
        "resumed analysis cache lost completed views"
    );
    requireThrows<CacheValidationError>(
        [&] {
            (void)readAnalysisCache(
                cachePath,
                cache.sourceDigest,
                cache.inputDigest,
                cache.geometryDigest,
                cache.selectedFramesDigest,
                cache.trainingDigest,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests,
                cache.gaussianCount + 1,
                1 << 20
            );
        },
        "analysis cache allocated a stale claimed Gaussian count"
    );

    const auto readCache = [&](const std::array<std::string, 5> &digests,
                               const std::vector<std::string> &identities,
                               const std::vector<std::string> &maskDigests) {
        return readAnalysisCache(
            cachePath,
            digests[0],
            digests[1],
            digests[2],
            digests[3],
            digests[4],
            identities,
            maskDigests,
            cache.gaussianCount,
            1 << 20
        );
    };
    const std::array<std::string, 5> validDigests = {
        cache.sourceDigest,
        cache.inputDigest,
        cache.geometryDigest,
        cache.selectedFramesDigest,
        cache.trainingDigest,
    };
    for (std::size_t index = 0; index < validDigests.size(); ++index) {
        std::array<std::string, 5> stale = validDigests;
        stale[index][0] = stale[index][0] == 'f' ? '0' : 'f';
        requireThrows<CacheValidationError>(
            [&] {
                (void)readCache(
                    stale,
                    cache.expectedViewIdentities,
                    cache.expectedViewMaskDigests
                );
            },
            "analysis cache accepted independently stale digest " +
                std::to_string(index)
        );
    }

    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                {"cached-b.png", "cached-a.png"},
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache ignored expected view order"
    );
    std::vector<std::string> staleMaskDigests =
        cache.expectedViewMaskDigests;
    staleMaskDigests[1][0] = '1';
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                staleMaskDigests
            );
        },
        "analysis cache accepted an independently stale mask digest"
    );
    AnalysisCache duplicateExpected = cache;
    duplicateExpected.expectedViewIdentities = {"cached-a.png", "cached-a.png"};
    requireThrows<CacheValidationError>(
        [&] { writeAnalysisCacheAtomically(cachePath, duplicateExpected); },
        "analysis cache writer accepted duplicate expected views"
    );
    AnalysisCache outOfOrder = restored;
    std::swap(outOfOrder.views[0], outOfOrder.views[1]);
    requireThrows<CacheValidationError>(
        [&] { writeAnalysisCacheAtomically(cachePath, outOfOrder); },
        "analysis cache writer accepted out-of-order completed views"
    );

    const std::vector<std::uint8_t> validCacheBytes = readBytes(cachePath);
    const std::string secondIdentity = "cached-b.png";
    const std::string firstIdentity = "cached-a.png";
    const auto expectedSecondIdentity = std::search(
        validCacheBytes.begin(),
        validCacheBytes.end(),
        secondIdentity.begin(),
        secondIdentity.end()
    );
    require(expectedSecondIdentity != validCacheBytes.end(),
            "serialized expected-view binding disappeared");
    const auto completedSecondIdentity = std::search(
        expectedSecondIdentity +
            static_cast<std::ptrdiff_t>(secondIdentity.size()),
        validCacheBytes.end(),
        secondIdentity.begin(),
        secondIdentity.end()
    );
    require(completedSecondIdentity != validCacheBytes.end(),
            "serialized completed-view order disappeared");

    std::vector<std::uint8_t> duplicateExpectedCorruption = validCacheBytes;
    std::copy(
        firstIdentity.begin(),
        firstIdentity.end(),
        duplicateExpectedCorruption.begin() +
            (expectedSecondIdentity - validCacheBytes.begin())
    );
    writeBytes(cachePath, duplicateExpectedCorruption);
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache reader accepted duplicate expected views"
    );

    std::vector<std::uint8_t> completedOrderCorruption = validCacheBytes;
    std::copy(
        firstIdentity.begin(),
        firstIdentity.end(),
        completedOrderCorruption.begin() +
            (completedSecondIdentity - validCacheBytes.begin())
    );
    writeBytes(cachePath, completedOrderCorruption);
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache reader accepted out-of-order completed views"
    );

    std::vector<std::uint8_t> versionCorruption = validCacheBytes;
    versionCorruption[8] = 99;
    writeBytes(cachePath, versionCorruption);
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache accepted an unsupported version"
    );

    writeBytes(
        cachePath,
        std::vector<std::uint8_t>(validCacheBytes.begin(), validCacheBytes.end() - 1)
    );
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache accepted truncation"
    );

    std::vector<std::uint8_t> trailingCorruption = validCacheBytes;
    trailingCorruption.push_back(0);
    writeBytes(cachePath, trailingCorruption);
    requireThrows<CacheValidationError>(
        [&] {
            (void)readCache(
                validDigests,
                cache.expectedViewIdentities,
                cache.expectedViewMaskDigests
            );
        },
        "analysis cache accepted trailing corruption"
    );
    fs::remove(cachePath);
}

void testHeldOutQuartileGate() {
    require(heldOutValidationPasses({0.50, 0.70, 0.70, 0.95}),
            "inclusive held-out thresholds were rejected");
    require(!heldOutValidationPasses({0.49, 0.80, 0.80, 0.95}),
            "held-out first-quartile failure was accepted");
    require(!heldOutValidationPasses({0.50, 0.69, 0.69, 0.95}),
            "held-out median failure was accepted");
}

} // namespace

int main() {
    try {
        testAlphaTransmittanceLifting();
        testPolicyThresholdBoundaries();
        testGraphThresholdBoundaries();
        testNoSubjectCoverageBoundary();
        testNoSubjectConsidersEveryComponent();
        testMinimumComponentMembershipBoundary();
        testFrameLocalIdentifiersDoNotNeedCrossFrameIdentity();
        testTwoCenteredObjectsRemainAmbiguous();
        testTouchingSurfacesRequireInstanceAgreement();
        testThinHighConfidenceStructureUsesCloseFallback();
        testUncertainBoundaryRepairIsBoundedToTwoPasses();
        testUncertainRepairCountsUniqueNeighbors();
        testDeterministicGraphSelectionAndAnchorResolution();
        testAsymmetricNeighborMembershipStillConnectsTheGraph();
        testAdaptiveLocalDistanceRejectsASparseBridge();
        testBinaryPlyRowsPreserveEveryAttributeAndSource();
        testBinaryPlyPendingCollisionIsPreserved();
        testBinaryPlyRejectsMalformedUnsafeAndCollidingInputs();
        testMemoryAdmissionAndCancellationPreserveSource();
        testAnalysisCacheReuseAndCorruptionRejection();
        testHeldOutQuartileGate();
        std::cout << "native subject isolation fixtures passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "isolation-tests: " << error.what() << '\n';
        return 1;
    }
}
