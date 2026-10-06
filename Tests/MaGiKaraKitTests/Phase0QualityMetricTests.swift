import Testing
@testable import MaGiKaraKit

@Suite struct Phase0QualityMetricTests {

    @Test func autoAcceptRequiresBothEdgesWithinTolerance() {
        #expect(Phase0Runner.boundariesWithinAutoAcceptTolerance(startError: 0.5, endError: -0.5))
        #expect(!Phase0Runner.boundariesWithinAutoAcceptTolerance(startError: 0.1, endError: 0.5001))
        #expect(!Phase0Runner.boundariesWithinAutoAcceptTolerance(startError: -0.6, endError: 0.1))
    }

    @Test func confidencePassIsNotMistakenForTruthQualifiedAutoAccept() {
        #expect(Phase0Runner.isTruthQualifiedAutoAccept(
            needsReview: false, startError: 0.2, endError: -0.3))
        #expect(Phase0Runner.isFalseAutoAccept(
            needsReview: false, startError: 1.2, endError: 0.1))
        #expect(!Phase0Runner.isTruthQualifiedAutoAccept(
            needsReview: true, startError: 0.1, endError: 0.1))
        #expect(!Phase0Runner.isFalseAutoAccept(
            needsReview: true, startError: 1.2, endError: 0.1))
    }

    @Test func invalidNumbersFailClosed() {
        #expect(!Phase0Runner.boundariesWithinAutoAcceptTolerance(startError: .nan, endError: 0))
        #expect(!Phase0Runner.boundariesWithinAutoAcceptTolerance(startError: 0, endError: .infinity))
    }
}
