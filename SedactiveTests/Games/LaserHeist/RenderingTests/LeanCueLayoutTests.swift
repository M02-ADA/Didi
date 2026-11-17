import Testing
import UIKit
@testable import Sedactive

@MainActor struct LeanCueLayoutTests {
    @Test(arguments: [CGSize(width: 1376, height: 1032), CGSize(width: 1210, height: 834)])
    func largerCueOccupiesMeasuredBandWithoutChangingCamera(viewport: CGSize) throws {
        let head: CGFloat = viewport.width == 1376 ? 337.75 / 1032 : 279.09 / 834
        let p = try #require(LeanCuePlacement.make(viewport: viewport, headTopFraction: head))
        let k = min(viewport.width / 1210, viewport.height / 834)
        #expect(p.frame.minY > 123 * k + 12)
        #expect(p.frame.maxY + 12 < head * viewport.height)
        #expect(p.frame.midY > viewport.height * 0.19 + 30)
        #expect(p.frame.midX == viewport.width / 2)
        #expect(72 * p.scale > 52.7 * k * 1.3)
        #expect(LeanInstructionArtwork.left.size == LeanInstructionArtwork.right.size)
    }
    @Test func unavailableProjectionCannotInventAPlacement() {
        #expect(LeanCuePlacement.make(viewport: .zero, headTopFraction: 0.3) == nil)
        #expect(LeanCuePlacement.make(viewport: CGSize(width: 1210, height: 834), headTopFraction: nil) == nil)
        #expect(LeanCuePlacement.make(viewport: CGSize(width: 1210, height: 834), headTopFraction: -1) == nil)
    }
}
