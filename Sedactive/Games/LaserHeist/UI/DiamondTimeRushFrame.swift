import SwiftUI

/// A visual countdown cue. Gameplay time comes from the HUD model, so pauses
/// freeze the pulse and diamond pickups cannot accelerate it.
struct DiamondTimeRushFrame: View {
    let secondsRemaining: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights

    var body: some View {
        Image("LaserHeistUI/diamond-time-rush-frame")
            .resizable()
            .ignoresSafeArea()
            .opacity(Self.opacity(secondsRemaining: secondsRemaining, reduceMotion: reduceMotion || dimFlashingLights))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    nonisolated static func opacity(secondsRemaining: Double, reduceMotion: Bool) -> Double {
        guard secondsRemaining.isFinite, secondsRemaining > 0 else { return 0 }
        if reduceMotion && secondsRemaining <= 5 { return 0.24 }
        let rhythm: (start: Double, cyclesPerSecond: Double, resting: Double, peak: Double) =
            switch secondsRemaining {
            case ...5: (5, 3.0, 0.30, 1.0)
            case ...10: (10, 2.4, 0.16, 0.62)
            default: (10, 1.5, 0.09, 0.36)
            }
        guard !reduceMotion else { return rhythm.resting }
        // A continuous wave rises and falls without holding between pulses.
        let phase = (rhythm.start - secondsRemaining) * rhythm.cyclesPerSecond * 2 * Double.pi
        let pulse = (1 - cos(phase)) / 2
        return rhythm.resting + (rhythm.peak - rhythm.resting) * pulse
    }
}
