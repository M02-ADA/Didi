import Testing
@testable import Sedactive

@MainActor struct FTUEDiamondTimeDemoTests {
    @Test func scriptedPickupsAreOrderedAndDoNotCatchUpOnResume() {
        let demo = FTUEDiamondTimeDemo()
        #expect(demo.collectedCount == 0)
        for index in 0...10 { _ = demo.advance(at: Double(index) / 10, active: true) }
        #expect(demo.collectedCount == 0)
        _ = demo.advance(at: 1.1, active: true)
        #expect(demo.collectedCount == 1)
        _ = demo.advance(at: 30, active: false)
        _ = demo.advance(at: 60, active: true)
        #expect(demo.elapsed == 1.1)
        for index in 1...47 { _ = demo.advance(at: 60 + Double(index) / 10, active: true) }
        #expect(demo.collectedCount == 4)
        #expect(demo.advance(at: 64.8, active: true))
        demo.reset()
        #expect(demo.elapsed == 0 && demo.collectedCount == 0)
    }
}
