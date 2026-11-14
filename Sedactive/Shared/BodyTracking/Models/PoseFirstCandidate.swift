//
//  PoseFirstCandidate.swift
//  Sedactive
//

import Foundation

/// POSE-FIRST TEMPORAL TRACKING (Kevin, 14 November 2026). PRODUCTION DEFAULT in Debug and
/// Release (approved by the task owner after the iPad tests in
/// `Docs/LaserHeist-Pose-First-Candidate.md`). A DEBUG build launched with `-trackingBaseline`
/// runs the previous rules for comparison. Each component takes the switch as an explicit value
/// so tests can run both.
///
/// What it changes (Edo's and Jevon's areas, recorded for their review):
/// - Edo (producer): a player whose identity is held by squat presence (both shoulders exactly
///   where they just were, hips hidden) is still MEASURED from the landmarks Vision did see
///   (`PlayerBodySample.presenceOnly`); the crown is the higher of the nose estimate and a
///   shoulder estimate, so a head bow alone cannot lower it; JUMP's airborne state needs the hips
///   to rise with the soles and ends after a credible flight time.
/// - Jevon (readiness, judging, recovery): a running round pauses on ABSENCE (no full or present
///   partial body for `absenceGrace`), not on one weak frame; a presence-held sample can be judged;
///   an UNAVAILABLE verdict while the player is present is unscored without a pause, up to
///   `UnavailableBudget`, after which the round pauses and the existing recovery retries.
/// Nothing here fabricates a joint: missing landmarks stay missing and are judged UNAVAILABLE.
nonisolated enum PoseFirstCandidate {
    /// On in every build; off only in a DEBUG build launched with `-trackingBaseline`.
    static let isEnabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-trackingBaseline")
        #else
        true
        #endif
    }()

    /// A running round tolerates frames without admissible evidence while the player is present,
    /// and pauses once nobody (full or presence-held body) has been seen for this long. 0.6 s is the
    /// gameplay rules' proposed `lostTimeout` (§C1, G15: Proposed, to tune on device).
    static let absenceGrace = 0.6

    /// TIMED JUMP EVENT (needs Jevon's and the task owner's review: it replaces the CP1 low-laser
    /// rule in the candidate). A low laser is CLEAR when an AIRBORNE RUN of this player (consecutive
    /// captures the jump estimator calls airborne, both soles valid) lasts at least
    /// `jumpMinimumFlight` and covers the crossing time within `jumpTimingTolerance`. No sole height
    /// is compared with the drawn laser. Values from the iPad logs of 14 November 2026:
    /// - ankle jitter stayed above the take-off threshold for 1–2 frames (0.03–0.07 s); the
    ///   smallest real jumps for 6–8 frames (0.20–0.23 s): 0.1 s keeps every real jump seen and
    ///   rejects the jitter seen;
    /// - the tolerance is one 30 fps frame plus capture jitter: a jump must be in the air AT the
    ///   crossing, not merely somewhere in the 0.6 s evidence window.
    /// Quick tiptoes (8–11 frames above the threshold, 0.08–0.12 lift) overlap real small jumps
    /// in height and duration; this rule cannot separate them. Held tiptoes (> 0.7 s), jitter and
    /// squat recovery are rejected by the estimator.
    static let jumpMinimumFlight = 0.1
    static let jumpTimingTolerance = 0.05

    /// UNAVAILABLE without a pause, per player: at most this many in a row, and this many per round.
    nonisolated struct UnavailableBudget: Equatable, Sendable {
        var consecutive = 2
        var perRound = 4
    }
}

/// The candidate's crown: the higher of the nose-based estimate and a shoulder-based one.
/// The shoulder estimate is the shoulder midpoint plus this player's own upright
/// shoulder-to-nose height (learned from upright frames, never from a bowed head) plus the
/// calibrated nose-to-crown offset. In a real squat the two agree; in a head bow the nose drops
/// but the shoulders do not, so the crown stays up. Taking the higher one can only turn a
/// doubtful CLEAR into a HIT, never the reverse.
nonisolated struct HeadHeightReference: Sendable {
    /// Upright shoulder-to-nose heights (game units) from recent frames.
    private var samples: [Double] = []
    static let capacity = 600       // ~20 s at 30 fps
    static let minimumSamples = 15  // ~0.5 s before the shoulder estimate is used

    /// The player's upright shoulder-to-nose height: a high percentile, so bowed frames (smaller)
    /// never set it and a briefly tilted-back head (larger) cannot dominate it.
    var upright: Double? {
        guard samples.count >= Self.minimumSamples else { return nil }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.8))]
    }

    mutating func observe(noseY: Double, shoulderY: Double) {
        let gap = noseY - shoulderY
        guard gap.isFinite, gap > 0 else { return }
        samples.append(gap)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The conservative crown (game units), or nil when neither estimate is available.
    func crown(noseCrown: Double?, shoulderY: Double?, noseToCrown: Double) -> Double? {
        let fromShoulders = shoulderY.flatMap { s in upright.map { s + $0 + noseToCrown } }
        switch (noseCrown, fromShoulders) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}
