import SwiftUI

/// The vault's game clock also drives the aura, so its brightness holds while paused.
struct VaultCountdownAura: View {
    let secondsRemaining: Double
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights

    var body: some View {
        Image("LaserHeistUI/vault-countdown-aura")
            .resizable()
            .opacity(Self.opacity(secondsRemaining: secondsRemaining, duration: duration,
                                  steady: reduceMotion || dimFlashingLights))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    nonisolated static func opacity(secondsRemaining: Double, duration: Double, steady: Bool) -> Double {
        guard secondsRemaining.isFinite, secondsRemaining > 0,
              duration.isFinite, duration > 0 else { return 0 }
        if steady { return 0.4 }
        let elapsed = max(0, duration - secondsRemaining)
        let progress = elapsed / duration
        // Integrate a frequency ramp from 0.8 to 2 pulses per second to keep the wave continuous.
        let cycles = elapsed * (0.8 + 0.6 * progress)
        let pulse = (1 - cos(2 * .pi * cycles)) / 2
        return 0.22 + (0.40 + 0.28 * progress) * pulse
    }
}
