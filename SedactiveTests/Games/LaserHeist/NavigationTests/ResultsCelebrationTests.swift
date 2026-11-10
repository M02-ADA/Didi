import CoreGraphics
import Foundation
import Testing
@testable import Sedactive

/// The completed-round celebration: the mascot starts entirely below the
/// screen and rises into its Sketch place, the diamonds follow once it has
/// landed, and the whole reveal fits inside the (provisional) time it is shown.
@MainActor
struct ResultsCelebrationTests {
    @Test func theEntranceFinishesBeforeTheScoreAppears() {
        let shown = Double(ResultsView.celebrationDuration.components.seconds)
        let mascotLands = ResultsCelebration.mascotDelay + ResultsCelebration.mascotRise
        let lastDiamondStarts = ResultsCelebration.diamondDelay + 2 * ResultsCelebration.diamondStagger
        // A diamond's spring settles in about 0.45 s.
        #expect(lastDiamondStarts + 0.45 < shown)
        #expect(ResultsCelebration.mascotDelay > 0, "the background shows alone first")
        #expect(ResultsCelebration.diamondDelay >= ResultsCelebration.mascotDelay + 0.6 * ResultsCelebration.mascotRise,
                "diamonds follow the mascot's arrival")
        #expect(ResultsCelebration.idleStart >= max(mascotLands, lastDiamondStarts), "the idle never fights an entrance")
        #expect(ResultsCelebration.idleStart + ResultsCelebration.idleRamp < shown, "the idle motion is visible before the score")
    }

    /// 11-inch and 13-inch iPads in landscape, and a wider and a taller window.
    @Test(arguments: [CGSize(width: 1210, height: 834), CGSize(width: 1376, height: 1032),
                      CGSize(width: 1400, height: 800), CGSize(width: 1000, height: 900)])
    func theMascotStartsEntirelyBelowTheScreen(screen: CGSize) {
        let k = min(screen.width / 1210, screen.height / 834)
        let artboardTop = (screen.height - 834 * k) / 2
        let settledTop = artboardTop + ResultsCelebration.mascotFrame.minY * k
        let offset = ResultsCelebration.entranceOffset(screen: screen)
        #expect(settledTop + offset >= screen.height, "the mascot's top edge starts below the screen")
        #expect(settledTop + offset <= screen.height + 20, "and only just below it, so it is on screen quickly")
    }
}
