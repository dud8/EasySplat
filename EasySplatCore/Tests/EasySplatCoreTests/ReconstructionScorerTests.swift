import Testing
@testable import EasySplatCore

struct ReconstructionScorerTests {
    @Test func parseModelAnalyzerOutput() {
        let sample = """
        Registered images: 120 / 200
        Mean reprojection error: 1.23
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        #expect(score.registeredImages == 120)
        #expect(score.totalImages == 200)
        #expect(score.meanReprojectionError != nil)
        #expect(abs((score.meanReprojectionError ?? 0) - 1.23) < 0.01)
    }

    @Test func parseModelAnalyzerOutputMissingReprojection() {
        let sample = """
        Registered images: 10 / 20
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        #expect(score.registeredImages == 10)
        #expect(score.totalImages == 20)
        #expect(score.meanReprojectionError == nil)
    }

    @Test func acceptableThresholds() {
        let score = ReconstructionScore(registeredImages: 70, totalImages: 100, meanReprojectionError: 1.0)
        #expect(ReconstructionScorer.isAcceptable(score, mode: .object))
        let low = ReconstructionScore(registeredImages: 40, totalImages: 100, meanReprojectionError: 1.0)
        #expect(!ReconstructionScorer.isAcceptable(low, mode: .object))
    }
}
