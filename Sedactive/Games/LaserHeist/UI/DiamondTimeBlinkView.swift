//
//  DiamondTimeBlinkView.swift
//  Sedactive
//

import SwiftUI

/// The blink into Diamond Time (Kevin, 21 November 2026): after the final vault's landing the
/// players blink. Two eyelids, the upper coming down and the lower coming up, leave an almond-shaped
/// opening like an eye's: they meet at the corners first and over the middle last, just past it;
/// while they are shut Diamond Time's own view (the paw board) takes over; they open on it. Screen
/// space, over the 3D view and the HUD.
///
/// Driven only by `closure` (0 open … 1 shut), from the entry's held-time script
/// (`LaserFinalVaultTimeline.blinkClosure`): a pause holds it where it is, and once the entry is
/// complete (or gone: restart, end, replay) nothing is drawn, so it can never stay over gameplay.
/// Reduce Motion: no travel; the screen is simply covered for the middle of the blink, which
/// contains the switch.
struct DiamondTimeBlinkView: View {
    let closure: Double
    /// DEBUG review only (`-finalVaultPreview reduce`): draw as with Reduce Motion on.
    var forcesReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcesReducedMotion }

    /// The lids' colour: the vault's deepest indigo, not black.
    static let lid = Color(red: 0.055, green: 0.043, blue: 0.13)
    /// The lash line along each lid's edge, a little darker.
    static let lash = Color(red: 0.02, green: 0.016, blue: 0.06)

    /// What is drawn for `closure`: under Reduce Motion, fully shut or nothing.
    static func shown(_ closure: Double, reduceMotion: Bool) -> Double {
        let c = min(1, max(0, closure))
        return reduceMotion ? (c >= 0.5 ? 1 : 0) : c
    }

    var body: some View {
        let c = Self.shown(closure, reduceMotion: reduceMotion)
        if c > 0 {
            Canvas { context, size in
                for upper in [true, false] {
                    let lid = Self.lidPath(upper: upper, closure: c, size: size)
                    context.fill(lid, with: .color(Self.lid))
                    context.stroke(Self.edgePath(upper: upper, closure: c, size: size), with: .color(Self.lash),
                                   style: StrokeStyle(lineWidth: max(3, size.height * 0.008), lineCap: .round))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where a lid's edge is at `closure`: its outer ends at `base`, its middle `sag` behind them
    /// (the almond opening). Shut, the edge is straight and past the middle, so the two lids overlap
    /// edge to edge.
    static func edge(closure c: Double, height: CGFloat) -> (base: CGFloat, sag: CGFloat) {
        let c = min(1, max(0, c))
        // The corners meet at 85 % of the close; the middle trails and meets just before shut.
        let base = height * 0.53 * CGFloat(min(1, c / 0.85))
        let middle = height * 0.53 * CGFloat(pow(c, 1.3))
        return (base, base - middle)
    }

    /// The upper lid fills from the top down to its edge; the lower one from the bottom up.
    static func lidPath(upper: Bool, closure: Double, size: CGSize) -> Path {
        let (base, sag) = edge(closure: closure, height: size.height)
        let w = size.width, h = size.height
        var path = Path()
        if upper {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: base))
            path.addQuadCurve(to: CGPoint(x: 0, y: base), control: CGPoint(x: w / 2, y: base - 2 * sag))
        } else {
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: h - base))
            path.addQuadCurve(to: CGPoint(x: 0, y: h - base), control: CGPoint(x: w / 2, y: h - base + 2 * sag))
        }
        path.closeSubpath()
        return path
    }

    static func edgePath(upper: Bool, closure: Double, size: CGSize) -> Path {
        let (base, sag) = edge(closure: closure, height: size.height)
        let w = size.width, h = size.height
        let y = upper ? base : h - base, bend = upper ? -2 * sag : 2 * sag
        var path = Path()
        path.move(to: CGPoint(x: w, y: y))
        path.addQuadCurve(to: CGPoint(x: 0, y: y), control: CGPoint(x: w / 2, y: y + bend))
        return path
    }
}
