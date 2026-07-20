import CoreVideo
import CoreMedia
import XCTest
@testable import EasySplatCore

final class FrameExtractorLogicTests: XCTestCase {
    func testPrimaryTrackSelectionPrefersFullResolutionOverPreviewTrack() {
        let descriptors = [
            VideoTrackDescriptor(
                index: 0,
                trackID: 1,
                width: 3_840,
                height: 2_160,
                nominalFrameRate: 29.97,
                durationSeconds: 60,
                estimatedDataRate: 80_000_000,
                isEnabled: true
            ),
            VideoTrackDescriptor(
                index: 1,
                trackID: 4,
                width: 1_280,
                height: 720,
                nominalFrameRate: 0,
                durationSeconds: 60,
                estimatedDataRate: 8_000_000,
                isEnabled: true
            ),
        ]

        XCTAssertEqual(FrameExtractor.test_primaryTrackIndex(descriptors), 0)
    }

    func testPrimaryTrackSelectionDoesNotMistakeVariableFrameRateForAStillTrack() {
        let descriptors = [
            VideoTrackDescriptor(
                index: 0,
                trackID: 1,
                width: 3_840,
                height: 2_160,
                nominalFrameRate: 0,
                durationSeconds: 60,
                estimatedDataRate: 80_000_000,
                isEnabled: true
            ),
            VideoTrackDescriptor(
                index: 1,
                trackID: 4,
                width: 1_280,
                height: 720,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 8_000_000,
                isEnabled: true
            ),
        ]

        XCTAssertEqual(FrameExtractor.test_primaryTrackIndex(descriptors), 0)
    }

    func testPrimaryTrackSelectionIgnoresTinyAuxiliaryDurationDifference() {
        let descriptors = [
            VideoTrackDescriptor(
                index: 0,
                trackID: 1,
                width: 3_840,
                height: 2_160,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 80_000_000,
                isEnabled: true
            ),
            VideoTrackDescriptor(
                index: 1,
                trackID: 4,
                width: 1_280,
                height: 720,
                nominalFrameRate: 30,
                durationSeconds: 60.02,
                estimatedDataRate: 8_000_000,
                isEnabled: true
            ),
        ]

        XCTAssertEqual(FrameExtractor.test_primaryTrackIndex(descriptors), 0)
    }

    func testPrimaryTrackSelectionRejectsAuxiliaryAndUndecodableTracks() {
        let descriptors = [
            VideoTrackDescriptor(
                index: 0,
                trackID: 1,
                width: 4_096,
                height: 2_160,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 100_000_000,
                isEnabled: true,
                isDecodable: true,
                isAuxiliary: true
            ),
            VideoTrackDescriptor(
                index: 1,
                trackID: 2,
                width: 3_840,
                height: 2_160,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 90_000_000,
                isEnabled: true,
                isDecodable: false
            ),
            VideoTrackDescriptor(
                index: 2,
                trackID: 3,
                width: 1_920,
                height: 1_080,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 20_000_000,
                isEnabled: true,
                isDecodable: true,
                isAuxiliary: false
            ),
        ]

        XCTAssertEqual(FrameExtractor.test_primaryTrackIndex(descriptors), 2)
    }

    func testPrimaryTrackSelectionDoesNotOverflowForMalformedPixelAreas() {
        let descriptors = [
            VideoTrackDescriptor(
                index: 0,
                trackID: 1,
                width: Int.max,
                height: Int.max,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 1,
                isEnabled: true
            ),
            VideoTrackDescriptor(
                index: 1,
                trackID: 2,
                width: 1_920,
                height: 1_080,
                nominalFrameRate: 30,
                durationSeconds: 60,
                estimatedDataRate: 1,
                isEnabled: true
            ),
        ]

        XCTAssertEqual(FrameExtractor.test_primaryTrackIndex(descriptors), 0)
    }

    func testPixelDimensionRejectsNonFiniteAndUnrepresentableMetadata() {
        XCTAssertEqual(FrameExtractor.test_pixelDimension(3_840), 3_840)
        XCTAssertEqual(FrameExtractor.test_pixelDimension(-2_160), 2_160)
        XCTAssertEqual(FrameExtractor.test_pixelDimension(.infinity), 0)
        XCTAssertEqual(FrameExtractor.test_pixelDimension(.nan), 0)
        XCTAssertEqual(FrameExtractor.test_pixelDimension(.greatestFiniteMagnitude), 0)
    }

    func testAnalysisDimensionsUseEven384PixelLongEdge() {
        XCTAssertEqual(
            FrameExtractor.test_analysisDimensions(width: 3_840, height: 2_160),
            FrameAnalysisDimensions(width: 384, height: 216)
        )
        XCTAssertEqual(
            FrameExtractor.test_analysisDimensions(width: 2_160, height: 3_840),
            FrameAnalysisDimensions(width: 216, height: 384)
        )
        XCTAssertEqual(
            FrameExtractor.test_analysisDimensions(width: 403, height: 301),
            FrameAnalysisDimensions(width: 384, height: 286)
        )
    }

    func testAnalysisRateProvidesThreeCandidatesPerOutputWithoutTrustingNominalFPSAsACap() {
        let options = FrameExtractionOptions(
            targetCount: 250,
            maxDimension: 1_600,
            targetFPS: 3
        )

        XCTAssertEqual(
            FrameExtractor.test_analysisFrameRate(
                options: options,
                duration: 60,
                videoFPS: 29.97
            ),
            12.5,
            accuracy: 0.02
        )
        XCTAssertEqual(
            FrameExtractor.test_analysisFrameRate(
                options: options,
                duration: 600,
                videoFPS: 29.97
            ),
            3,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            FrameExtractor.test_analysisFrameRate(
                options: options,
                duration: 10,
                videoFPS: 0
            ),
            30
        )
        XCTAssertEqual(
            FrameExtractor.test_analysisFrameRate(
                options: options,
                duration: 10,
                videoFPS: 29.97
            ),
            75,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FrameExtractor.test_analysisFrameRate(
                options: options,
                duration: 60,
                videoFPS: 1
            ),
            12.5,
            accuracy: 0.001
        )
    }

    func testAnalysisRateRemainsFiniteForTinyUnknownRateVideo() {
        let rate = FrameExtractor.test_analysisFrameRate(
            options: FrameExtractionOptions(
                targetCount: 250,
                maxDimension: 1_600,
                targetFPS: 3
            ),
            duration: Double.leastNonzeroMagnitude,
            videoFPS: 0
        )

        XCTAssertTrue(rate.isFinite)
        XCTAssertGreaterThan(rate, 0)
    }

    func testTimelineSelectionKeepsBalancedCoverageAtKnownRegressionScale() {
        var frames: [TimedFrameCandidate] = []
        frames.reserveCapacity(750)
        for index in 0..<750 {
            let candidate = SmartFrameCandidate(
                index: index * 2,
                sharpness: 80 + Double(index % 7),
                brightness: 0.5,
                clippedFraction: 0,
                motionScore: Double(index % 5) / 5,
                dHash: UInt64(index)
            )
            frames.append(TimedFrameCandidate(
                frameIndex: index * 2,
                timestampSeconds: Double(index) * 60 / 749,
                candidate: candidate
            ))
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 250,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(selected.count, 250)
        XCTAssertLessThanOrEqual(selected.first?.timestampSeconds ?? .infinity, 1)
        XCTAssertGreaterThanOrEqual(selected.last?.timestampSeconds ?? 0, 59)
        XCTAssertEqual(Set(selected.map(\.frameIndex)).count, selected.count)
        XCTAssertTrue(zip(selected, selected.dropFirst()).allSatisfy {
            $1.timestampSeconds > $0.timestampSeconds
        })
    }

    func testTimelineSelectionDoesNotForceUnusableBoundaryRanges() {
        let frames = (0...750).map { index in
            let isBoundary = index <= 11 || index >= 739
            return TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index) * 0.04,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: isBoundary ? 0 : 100,
                    brightness: isBoundary ? 1 : 0.5,
                    clippedFraction: isBoundary ? 1 : 0,
                    dHash: UInt64(index)
                )
            )
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 250,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(selected.count, 250)
        XCTAssertGreaterThan(selected.first?.frameIndex ?? 0, 11)
        XCTAssertLessThan(selected.last?.frameIndex ?? .max, 739)
        XCTAssertFalse(selected.contains { $0.frameIndex <= 11 || $0.frameIndex >= 739 })
        XCTAssertLessThanOrEqual(selected.first?.timestampSeconds ?? .infinity, 1)
        XCTAssertGreaterThanOrEqual(selected.last?.timestampSeconds ?? 0, 29)
    }

    func testTimelineSelectionRebasesSpacingAfterAnOpeningFade() {
        let frames = (0...750).map { index in
            let isOpeningFade = index <= 11
            return TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index) * 0.08,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: isOpeningFade ? 0 : 100,
                    brightness: isOpeningFade ? 0 : 0.5,
                    clippedFraction: isOpeningFade ? 1 : 0,
                    dHash: UInt64(index)
                )
            )
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 250,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(selected.count, 250)
        XCTAssertEqual(selected.first?.frameIndex, 12)
        for (first, second) in zip(selected.prefix(10), selected.dropFirst().prefix(9)) {
            XCTAssertGreaterThanOrEqual(
                second.timestampSeconds - first.timestampSeconds,
                0.2,
                "Opening fade caused adjacent keyframes to bunch at \(first.frameIndex) and \(second.frameIndex)"
            )
        }
    }

    func testTimelineSelectionDoesNotCompressTheUsableTail() {
        let frames = (0...750).map { index in
            TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index) * 0.08,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: 100,
                    brightness: 0.5,
                    dHash: UInt64(index)
                )
            )
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 250,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(selected.count, 250)
        for (first, second) in zip(selected.suffix(10), selected.suffix(9)) {
            XCTAssertGreaterThanOrEqual(
                second.timestampSeconds - first.timestampSeconds,
                0.2,
                "Trailing boundary search compressed keyframes at \(first.frameIndex) and \(second.frameIndex)"
            )
        }
    }

    func testTimelineSelectionKeepsEmptyWindowFallbackNearItsTarget() {
        let timestamps = [0.0, 0.2, 1.2, 1.7, 1.9, 2.1, 2.3]
        let sharpness = [100.0, 20, 60, 1_000, 50, 50, 100]
        let frames = timestamps.indices.map { index in
            TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: timestamps[index],
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: sharpness[index],
                    brightness: 0.5
                )
            )
        }

        for minimumDistance in [0.0, 0.2] {
            let selected = SmartFrameSelection.selectTimeline(
                frames,
                targetCount: 4,
                minimumTimeDistance: minimumDistance
            )

            XCTAssertEqual(selected.map(\.timestampSeconds), [0, 1.2, 1.7, 2.3])
            XCTAssertEqual(Set(selected.map(\.frameIndex)).count, 4)
        }
    }

    func testLargeAreaSpacingDoesNotReduceRequestedFrameCount() {
        var frames: [TimedFrameCandidate] = []
        frames.reserveCapacity(1_000)
        for index in 0..<1_000 {
            frames.append(TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index) * 60 / 999,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: 80,
                    brightness: 0.5,
                    dHash: UInt64(index)
                )
            ))
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 375,
            minimumTimeDistance: 0.3
        )

        XCTAssertEqual(selected.count, 375)
    }

    func testTimelineSelectionUsesLocalQualityInsteadOfDroppingDimSegments() {
        let frames = [
            TimedFrameCandidate(
                frameIndex: 0,
                timestampSeconds: 0,
                candidate: SmartFrameCandidate(index: 0, sharpness: 100, brightness: 0.5)
            ),
            TimedFrameCandidate(
                frameIndex: 1,
                timestampSeconds: 0.5,
                candidate: SmartFrameCandidate(index: 1, sharpness: 95, brightness: 0.5)
            ),
            TimedFrameCandidate(
                frameIndex: 2,
                timestampSeconds: 1.5,
                candidate: SmartFrameCandidate(index: 2, sharpness: 42, brightness: 0.14)
            ),
            TimedFrameCandidate(
                frameIndex: 3,
                timestampSeconds: 2,
                candidate: SmartFrameCandidate(index: 3, sharpness: 45, brightness: 0.16)
            ),
            TimedFrameCandidate(
                frameIndex: 4,
                timestampSeconds: 3,
                candidate: SmartFrameCandidate(index: 4, sharpness: 90, brightness: 0.5)
            ),
            TimedFrameCandidate(
                frameIndex: 5,
                timestampSeconds: 4,
                candidate: SmartFrameCandidate(index: 5, sharpness: 92, brightness: 0.5)
            ),
        ]

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 3,
            minimumTimeDistance: 0.1
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertTrue(selected.contains { (1.25...2.25).contains($0.timestampSeconds) })
        XCTAssertLessThanOrEqual(selected.first?.timestampSeconds ?? .infinity, 0.5)
        XCTAssertGreaterThanOrEqual(selected.last?.timestampSeconds ?? 0, 3)
    }

    func testTimelineSelectionIsIndependentOfCandidateInputOrder() {
        let ordered: [TimedFrameCandidate] = (0..<12).map { index -> TimedFrameCandidate in
            TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index) / 3,
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: Double(50 + index % 3),
                    brightness: 0.5,
                    dHash: UInt64(index * 17)
                )
            )
        }

        let forward = SmartFrameSelection.selectTimeline(
            ordered,
            targetCount: 4,
            minimumTimeDistance: 0.2
        )
        let shuffled = SmartFrameSelection.selectTimeline(
            [ordered[8], ordered[1], ordered[10], ordered[3], ordered[0], ordered[7],
             ordered[5], ordered[11], ordered[2], ordered[9], ordered[4], ordered[6]],
            targetCount: 4,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(
            forward.map { candidate in candidate.frameIndex },
            shuffled.map { candidate in candidate.frameIndex }
        )
    }

    func testTimelineSelectionUsesTimeRatherThanVFRCandidateDensity() {
        let slowHalf = (0..<50).map { second in
            TimedFrameCandidate(
                frameIndex: second,
                timestampSeconds: Double(second),
                candidate: SmartFrameCandidate(index: second, sharpness: 100)
            )
        }
        let denseHalf = (0..<150).map { offset in
            TimedFrameCandidate(
                frameIndex: 50 + offset,
                timestampSeconds: 50 + Double(offset) / 3,
                candidate: SmartFrameCandidate(index: 50 + offset, sharpness: 100)
            )
        }

        let selected = SmartFrameSelection.selectTimeline(
            slowHalf + denseHalf,
            targetCount: 10,
            minimumTimeDistance: 0
        )

        XCTAssertEqual(selected.count, 10)
        XCTAssertEqual(selected.filter { $0.timestampSeconds < 50 }.count, 5)
        let spacing = ((selected.last?.timestampSeconds ?? 0)
            - (selected.first?.timestampSeconds ?? 0)) / 9
        for (index, frame) in selected.enumerated() {
            let expected = Double(index) * spacing
            XCTAssertEqual(frame.timestampSeconds, expected, accuracy: 0.7)
        }
    }

    func testTimelineSelectionDoesNotPenalizeAUsefulOrbitRevisit() {
        let frames = (0..<10).map { index in
            let sharpness = [0, 2, 4, 6].contains(index) ? 200.0 : 50.0
            let hashes: [UInt64] = [
                0x0000_0000_0000_0000,
                0x0f0f_0f0f_0f0f_0f0f,
                0xffff_ffff_ffff_ffff,
                0xf0f0_f0f0_f0f0_f0f0,
                0xaaaa_aaaa_aaaa_aaaa,
                0x3333_3333_3333_3333,
                0x0000_0000_0000_0000,
                0x5555_5555_5555_5555,
                0x9999_9999_9999_9999,
                0x6666_6666_6666_6666,
            ]
            return TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index),
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: sharpness,
                    brightness: 0.5,
                    dHash: hashes[index]
                )
            )
        }

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 5,
            minimumTimeDistance: 0.2
        )

        XCTAssertEqual(selected.map(\.frameIndex), [0, 2, 4, 6, 9])
    }

    func testMotionBonusCannotOverrideMeaningfullySharperFrame() {
        let frames = [
            TimedFrameCandidate(
                frameIndex: 0,
                timestampSeconds: 0,
                candidate: SmartFrameCandidate(
                    index: 0,
                    sharpness: 100,
                    brightness: 0.5,
                    motionScore: 1
                )
            ),
            TimedFrameCandidate(
                frameIndex: 1,
                timestampSeconds: 1,
                candidate: SmartFrameCandidate(
                    index: 1,
                    sharpness: 108,
                    brightness: 0.5,
                    motionScore: 0
                )
            ),
        ]

        let selected = SmartFrameSelection.selectTimeline(
            frames,
            targetCount: 1,
            minimumTimeDistance: 0
        )

        XCTAssertEqual(selected.map(\.frameIndex), [1])
    }

    func testTimelineSelectionPrefersCleanFrameOverClippedSharperNeighbor() {
        let frames = [
            TimedFrameCandidate(
                frameIndex: 0,
                timestampSeconds: 0,
                candidate: SmartFrameCandidate(
                    index: 0,
                    sharpness: 120,
                    brightness: 0.96,
                    clippedFraction: 0.65,
                    dHash: 1
                )
            ),
            TimedFrameCandidate(
                frameIndex: 1,
                timestampSeconds: 0.03,
                candidate: SmartFrameCandidate(
                    index: 1,
                    sharpness: 60,
                    brightness: 0.52,
                    clippedFraction: 0.01,
                    dHash: 2
                )
            ),
        ]

        XCTAssertEqual(
            SmartFrameSelection.selectTimeline(
                frames,
                targetCount: 1,
                minimumTimeDistance: 0
            ).map(\.frameIndex),
            [1]
        )
    }

    func testTimelineSelectionAvoidsImmediateNearDuplicateWhenAlternativeExists() {
        let frames = [
            TimedFrameCandidate(
                frameIndex: 0,
                timestampSeconds: 0,
                candidate: SmartFrameCandidate(index: 0, sharpness: 100, dHash: 0b1111)
            ),
            TimedFrameCandidate(
                frameIndex: 1,
                timestampSeconds: 0.2,
                candidate: SmartFrameCandidate(index: 1, sharpness: 20, dHash: 0xffff)
            ),
            TimedFrameCandidate(
                frameIndex: 2,
                timestampSeconds: 1,
                candidate: SmartFrameCandidate(index: 2, sharpness: 110, dHash: 0b1110)
            ),
            TimedFrameCandidate(
                frameIndex: 3,
                timestampSeconds: 1.2,
                candidate: SmartFrameCandidate(
                    index: 3,
                    sharpness: 80,
                    dHash: 0xffff_ffff_ffff_0000
                )
            ),
        ]

        XCTAssertEqual(
            SmartFrameSelection.selectTimeline(
                frames,
                targetCount: 2,
                minimumTimeDistance: 0
            ).map(\.frameIndex),
            [0, 3]
        )
    }

    func testTimelineSelectionStillFillsEverySlotWhenAllFramesArePoor() {
        let frames = (0..<30).map { index in
            TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index),
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: 0,
                    brightness: index.isMultiple(of: 2) ? 0 : 1,
                    clippedFraction: 1,
                    dHash: UInt64(index)
                )
            )
        }

        XCTAssertEqual(
            SmartFrameSelection.selectTimeline(
                frames,
                targetCount: 10,
                minimumTimeDistance: 0.2
            ).count,
            10
        )
    }

    func testTimelineSelectionPinsClipEndpointsAtMinimumAllocation() {
        let frames = (0..<4).map { index in
            TimedFrameCandidate(
                frameIndex: index,
                timestampSeconds: Double(index),
                candidate: SmartFrameCandidate(
                    index: index,
                    sharpness: [1, 1_000, 1_000, 1][index],
                    brightness: 0.5,
                    dHash: UInt64(index)
                )
            )
        }

        XCTAssertEqual(
            SmartFrameSelection.selectTimeline(
                frames,
                targetCount: 2,
                minimumTimeDistance: 0
            ).map(\.frameIndex),
            [0, 3]
        )
    }

    func testMotionScoreIgnoresAUniformExposureShift() {
        let first = (0..<(64 * 64)).map { UInt8(40 + $0 % 80) }
        let brighter = first.map { UInt8(min(255, Int($0) + 30)) }

        XCTAssertLessThan(
            FrameExtractor.test_lumaMotionScore(brighter, previous: first),
            0.01
        )
    }

    func testLumaScoringDetectsDetailAndExposureWithoutAFullResolutionImage() {
        let flat = [UInt8](repeating: 110, count: 64 * 64)
        let checkerboard = (0..<(64 * 64)).map { index -> UInt8 in
            ((index / 64) + (index % 64)).isMultiple(of: 2) ? 40 : 200
        }

        let flatScore = FrameScoring.scoreLumaPixels(flat, width: 64, height: 64)
        let detailedScore = FrameScoring.scoreLumaPixels(
            checkerboard,
            width: 64,
            height: 64
        )

        XCTAssertGreaterThan(detailedScore.blurScore, flatScore.blurScore)
        XCTAssertGreaterThan(detailedScore.laplacianScore, flatScore.laplacianScore)
        XCTAssertGreaterThan(detailedScore.brightness, flatScore.brightness)
    }

    func testTimestampRepairIsStrictlyMonotonicForBrokenPresentationTimes() {
        let first = FrameExtractor.test_monotonicTimestamp(
            1,
            frameIndex: 0,
            sourceFPS: 30,
            previous: nil
        )
        let duplicate = FrameExtractor.test_monotonicTimestamp(
            1,
            frameIndex: 1,
            sourceFPS: 30,
            previous: first
        )
        let backwards = FrameExtractor.test_monotonicTimestamp(
            0.5,
            frameIndex: 2,
            sourceFPS: 30,
            previous: duplicate
        )
        let invalid = FrameExtractor.test_monotonicTimestamp(
            .nan,
            frameIndex: 3,
            sourceFPS: 30,
            previous: backwards
        )

        XCTAssertGreaterThan(duplicate, first)
        XCTAssertGreaterThan(backwards, duplicate)
        XCTAssertGreaterThan(invalid, backwards)
    }

    func testAnalysisSchedulerRemainsBoundedAfterOneDuplicateTimestamp() {
        var scheduler = FrameAnalysisScheduler(analysisRate: 3, sourceFPS: 30)
        var previous: Double?
        var selectedCount = 0
        for frameIndex in 0..<3_000 {
            let nominal = Double(frameIndex) / 30
            let raw = frameIndex == 10 ? Double(9) / 30 : nominal
            let repaired = FrameExtractor.test_monotonicTimestamp(
                raw,
                frameIndex: frameIndex,
                sourceFPS: 30,
                previous: previous
            )
            previous = repaired
            if scheduler.shouldAnalyze(repaired) {
                selectedCount += 1
            }
        }

        XCTAssertGreaterThan(selectedCount, 295)
        XCTAssertLessThan(selectedCount, 305)
    }

    func testAnalysisSchedulerAdvancesAcrossHugeTimestampJumpInConstantTime() {
        var scheduler = FrameAnalysisScheduler(
            analysisRate: Double.greatestFiniteMagnitude,
            sourceFPS: 0
        )

        XCTAssertTrue(scheduler.shouldAnalyze(0))
        XCTAssertTrue(scheduler.shouldAnalyze(1_000_000_000_000))
        XCTAssertFalse(scheduler.shouldAnalyze(1_000_000_000_000))
        XCTAssertTrue(scheduler.shouldAnalyze(1_000_000_000_001))
    }

    func testSecondPassUsesSparseDecodeOnlyAtOrBelowFivePercent() {
        let exact = (0..<5).map { index in
            TimedFrameCandidate(
                frameIndex: index * 20,
                timestampSeconds: Double(index),
                candidate: SmartFrameCandidate(index: index, sharpness: 1),
                presentationTime: CMTime(value: CMTimeValue(index), timescale: 1)
            )
        }

        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: exact,
                decodedFrameCount: 100,
                hadRepairedTimestamps: false
            ),
            .sparse
        )
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: exact + [TimedFrameCandidate(
                    frameIndex: 99,
                    timestampSeconds: 5,
                    candidate: SmartFrameCandidate(index: 5, sharpness: 1),
                    presentationTime: CMTime(value: 5, timescale: 1)
                )],
                decodedFrameCount: 100,
                hadRepairedTimestamps: false
            ),
            .sequential
        )
    }

    func testSecondPassRejectsSparseDecodeWhenTimingIsUncertain() {
        let exactTime = CMTime(value: 3, timescale: 2)
        let exact = TimedFrameCandidate(
            frameIndex: 45,
            timestampSeconds: 1.5,
            candidate: SmartFrameCandidate(index: 45, sharpness: 1),
            presentationTime: exactTime
        )
        XCTAssertEqual(exact.presentationTime, exactTime)
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: [exact],
                decodedFrameCount: 20,
                hadRepairedTimestamps: true
            ),
            .sequential
        )

        var missingTime = exact
        missingTime.presentationTime = nil
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: [missingTime],
                decodedFrameCount: 20,
                hadRepairedTimestamps: false
            ),
            .sequential
        )
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: [exact],
                decodedFrameCount: 0,
                hadRepairedTimestamps: false
            ),
            .sequential
        )
    }

    func testPresentationTimeNormalizationMarksEveryRepair() {
        let first = FrameExtractor.test_normalizedPresentationTime(
            CMTime(value: 30, timescale: 30),
            frameIndex: 0,
            sourceFPS: 30,
            previous: nil
        )
        XCTAssertFalse(first.wasRepaired)
        XCTAssertEqual(first.presentationTime, CMTime(value: 30, timescale: 30))

        for raw in [
            CMTime(value: 30, timescale: 30),
            CMTime(value: 20, timescale: 30),
            CMTime(value: -1, timescale: 30),
            .invalid,
            CMTime(value: 61, timescale: 60, flags: .valid, epoch: 1),
        ] {
            let normalized = FrameExtractor.test_normalizedPresentationTime(
                raw,
                frameIndex: 1,
                sourceFPS: 30,
                previous: first.seconds
            )
            XCTAssertTrue(normalized.wasRepaired, "Expected repair for \(raw)")
            XCTAssertNil(normalized.presentationTime)
            XCTAssertGreaterThan(normalized.seconds, first.seconds)
        }
    }

    func testByteLumaSamplerRejectsTenBitPixelBuffers() throws {
        let eightBit = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let tenBit = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

        XCTAssertEqual(FrameExtractor.test_sampledLumaPixels(from: eightBit)?.count, 64 * 64)
        XCTAssertNil(FrameExtractor.test_sampledLumaPixels(from: tenBit))
    }

    func testFrameOutputFormatMappings() {
        XCTAssertEqual(FrameOutputFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(FrameOutputFormat.png.fileExtension, "png")
        XCTAssertEqual(FrameOutputFormat.jpeg.utType, .jpeg)
        XCTAssertEqual(FrameOutputFormat.png.utType, .png)
    }

    func testTimestampedFrameNamesRoundTripExactVideoTime() {
        let name = FrameExtractor.test_timestampedFilename(
            index: 7,
            seconds: 12.345678,
            format: .jpeg
        )

        XCTAssertEqual(name, "frame_000007_t000012345678.jpg")
        XCTAssertEqual(
            FrameExtractor.test_timestampSeconds(from: name) ?? -1,
            12.345678,
            accuracy: 0.000001
        )
        XCTAssertNil(FrameExtractor.test_timestampSeconds(from: "frame_000007.jpg"))
    }

    func testTimestampedFrameNameClampsUnrepresentableMediaTime() {
        let name = FrameExtractor.test_timestampedFilename(
            index: 1,
            seconds: .greatestFiniteMagnitude,
            format: .jpeg
        )

        XCTAssertEqual(name, "frame_000001_t9223372036854775807.jpg")
        XCTAssertNotNil(FrameExtractor.test_timestampSeconds(from: name))
    }

    private func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            64,
            64,
            format,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "FrameExtractorLogicTests", code: Int(status))
        }
        return buffer
    }

}
