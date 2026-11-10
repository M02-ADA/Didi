//
//  RoundCountdownOverlay.swift
//  Sedactive
//

import SwiftUI

/// The pre-round countdown over the gameplay scene (Sketch "Hi-Fi Revisi 6
/// NOV" › Game Set Up, artboard "Home Copy 28"): the scene dimmed to 34 % and a
/// large glowing number.
///
/// Presentation only. PENDING Jevon: the session's pre-round state supplies the
/// number (see `LaserHeist-Integration-Test-Checklist.md`, section 6). This view
/// keeps no clock, and the round's game time does not advance while it shows.
struct RoundCountdownOverlay: View {
    /// The number to show, as the session reports it.
    let value: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SketchArtboard(opaque: false) {
            Color.black.opacity(0.66)
        } content: { k in
            Text(value, format: .number)
                .font(.system(size: 362 * k, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.91), radius: 0, x: 21 * k, y: 34 * k)
                .shadow(color: .black.opacity(0.25), radius: 27 * k, x: 0, y: 27 * k)
                .shadow(color: .white.opacity(0.48), radius: 18 * k, x: 0, y: 4 * k)
                .frame(width: 1210 * k, height: 432 * k)
                .offset(y: 160 * k)
                .id(value)
                .transition(reduceMotion ? .opacity : .scale(scale: 1.25).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting in \(value)")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("roundCountdown")
    }
}

#Preview(traits: .landscapeLeft) {
    RoundCountdownOverlay(value: 3)
}
