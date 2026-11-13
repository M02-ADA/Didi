//
//  GateTravelEase.swift
//  Sedactive
//

import Foundation

/// The corridor's travel easing INTO a gate (presentation only; game time, encounters and the
/// judges are unchanged). Before, travel stopped from full speed to zero the instant a gate began.
/// Now:
/// - Arrival: over the last `duration` T seconds before the gate the corridor (and the door and its
///   consoles, which ride in the corridor) decelerates smoothly, never faster than cruise, to a stop
///   exactly at the gate's start: speed share f(l) = 2l/T − l²/T² (1 with no kink at l = T, 0 at
///   l = 0). The door's distance-to-go is the integral of that speed: v·(l²/T − l³/3T²) inside the
///   last T, and v·(l − T/3) before it (the eased stop is reached T/3 of cruise sooner, so the door
///   stands that much nearer while it cruises in; its speed always matches the corridor's).
/// Lasers still in flight are placed from their own crossing times (unchanged) and none fly at a
/// gate's start; gates already anchored in the corridor slow with it, as they should.
/// NOT eased: the restart after a gate. Lasers that appear as travel resumes are anchored to the
/// corridor's distance and must reach the players exactly at their crossing time; an ease-in would
/// make them up to v·T/3 (1.4 m) late against the judged crossing. Travel therefore resumes at
/// cruise, as before, while the door is still opening.
nonisolated enum GateTravelEase {
    static let duration: Double = 0.8

    /// How far the gate still is when `lead` seconds of activity remain before it.
    static func distance(lead: Double, speed: Float) -> Float {
        let l = max(0, lead), t = duration
        guard l < t else { return speed * Float(l - t / 3) }
        return speed * Float(l * l / t - l * l * l / (3 * t * t))
    }

    /// The share of cruise speed now, easing into a gate `lead` seconds ahead.
    static func speedFactor(lead: Double?) -> Float {
        guard let lead, lead >= 0, lead < duration else { return 1 }
        return Float(max(0, lead * (2 * duration - lead) / (duration * duration)))
    }
}
