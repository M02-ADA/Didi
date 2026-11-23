import CoreGraphics
import SwiftUI
import Testing
@testable import Sedactive

/// The blink's eyelids (`DiamondTimeBlinkView`, 21 November 2026): two lids that cover the whole
/// screen only while shut, nothing while open, and under Reduce Motion no travel at all.
@MainActor
struct DiamondTimeBlinkTests {
    static let sizes = [CGSize(width: 1210, height: 834), CGSize(width: 1366, height: 1024), CGSize(width: 1180, height: 820)]

    /// Whether every sampled point of the screen is under a lid.
    static func covered(_ closure: Double, _ size: CGSize) -> Bool {
        let upper = DiamondTimeBlinkView.lidPath(upper: true, closure: closure, size: size)
        let lower = DiamondTimeBlinkView.lidPath(upper: false, closure: closure, size: size)
        for x in stride(from: 1.0, to: Double(size.width), by: 23) {
            for y in stride(from: 0.5, to: Double(size.height), by: 1) { // every pixel row: a sliver must not slip through
                let p = CGPoint(x: x, y: y)
                if !upper.contains(p) && !lower.contains(p) { return false }
            }
        }
        return true
    }

    @Test func theLidsCoverTheScreenOnlyWhenShut() {
        for size in Self.sizes {
            #expect(Self.covered(1, size), "\(size): shut covers everything, edge to edge")
            for c in [0.0, 0.3, 0.7, 0.95] { #expect(!Self.covered(c, size), "\(size): at \(c) the view still shows") }
        }
    }

    /// The upper lid comes down and the lower one up; their edges leave an almond opening (the
    /// corners close first, the middle last) and straighten as they shut.
    @Test func theLidsMeetFromAboveAndBelow() {
        let size = CGSize(width: 1210, height: 834)
        let (base, sag) = DiamondTimeBlinkView.edge(closure: 0.5, height: size.height)
        #expect(base > 0 && sag > 0)
        let shut = DiamondTimeBlinkView.edge(closure: 1, height: size.height)
        #expect(shut.sag == 0 && shut.base > size.height / 2, "shut: straight, past the middle")
        let upper = DiamondTimeBlinkView.lidPath(upper: true, closure: 0.5, size: size)
        #expect(upper.contains(CGPoint(x: 605, y: 5)) && !upper.contains(CGPoint(x: 605, y: 829)))
        // Nearly shut: the corners are closed while the middle still shows a sliver.
        let lower = DiamondTimeBlinkView.lidPath(upper: false, closure: 0.9, size: size)
        let top = DiamondTimeBlinkView.lidPath(upper: true, closure: 0.9, size: size)
        let mid = CGPoint(x: 605, y: 417), corner = CGPoint(x: 3, y: 417)
        #expect(!top.contains(mid) && !lower.contains(mid) && (top.contains(corner) || lower.contains(corner)))
    }

    /// Reduce Motion: the lids never travel; the screen is covered for the middle of the blink (which
    /// holds the switch) and clear otherwise.
    @Test func reduceMotionCoversWithoutTravel() {
        let t = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        var shown: Set<Double> = []
        for step in 0...Int(t.end * 240) {
            shown.insert(DiamondTimeBlinkView.shown(t.blinkClosure(at: Double(step) / 240), reduceMotion: true))
        }
        #expect(shown == [0, 1], "only open or covered")
        #expect(DiamondTimeBlinkView.shown(t.blinkClosure(at: t.blinkSwitch), reduceMotion: true) == 1, "covered at the switch")
    }
}
