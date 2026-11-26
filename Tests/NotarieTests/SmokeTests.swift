import Testing
@testable import Notarie

@Suite struct SmokeTests {
    @Test func defaultModelIsLargeV3() {
        #expect(TranscriptionModel.default == .largeV3)
    }
}
