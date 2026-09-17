import Testing
@testable import MacVolumeMixer

@Test func newerPatchVersionIsDetected() {
    #expect(UpdateChecker.isVersion("0.1.1", newerThan: "0.1.0"))
    #expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.1.1"))
}

@Test func newerMinorAndMajorVersionsAreDetected() {
    #expect(UpdateChecker.isVersion("0.2.0", newerThan: "0.1.9"))
    #expect(UpdateChecker.isVersion("1.0.0", newerThan: "0.9.9"))
}

@Test func equalVersionsAreNotNewer() {
    #expect(!UpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"))
}

@Test func differingSegmentCountsCompareCorrectly() {
    #expect(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
    #expect(!UpdateChecker.isVersion("1.0", newerThan: "1.0.1"))
}
