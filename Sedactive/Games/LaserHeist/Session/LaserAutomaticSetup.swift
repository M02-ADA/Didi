import Foundation

/// What the setup screen shows for one player. Derived from the producer's tracking state and
/// calibration progress; never evidence, never a reason to start a round.
nonisolated enum LaserSetupPlayerStatus: Equatable, Sendable {
    /// Not linked yet.
    case searching
    /// Linked to their lane (P1 left, P2 right).
    case linked
    /// Standing calibration: `progress` 0...1 and the latest reason a sample was refused.
    case calibrating(progress: Double, issue: StandingSampleIssue?)
    /// Accepted standing reference for this round.
    case ready
}

/// The automatic setup's live view model, refreshed by the coordinator's setup tick.
nonisolated struct LaserSetupPresence: Equatable, Sendable {
    /// People the camera currently sees (raw pose candidates, capped at 2). Not identity.
    var peopleInView: Int = 0
    var players: [PlayerID: LaserSetupPlayerStatus] = [.player1: .searching, .player2: .searching]
    /// The upright prompt is showing; calibration begins when it ends.
    var promptingUpright = false
    /// Automatic calibration attempts made, and whether more will follow by themselves.
    var attempts = 0
    var willRetry = false
    /// Why the last attempt did not finish (player-facing hint), if it failed.
    var lastIssue: StandingSampleIssue?
}

/// Timing for the automatic flow. None of these change evidence, freshness or identity rules.
nonisolated enum LaserAutomaticSetupPolicy {
    /// Tick period of the setup driver (status reads only; controls run outside callbacks).
    static let tick: Duration = .milliseconds(100)
    /// How long "Stand still and upright!" shows before calibration samples are taken.
    static let uprightPrompt = 1.5
    /// Pause before an automatic retry after a calibration attempt fails.
    static let retryDelay = 2.0
    /// Automatic calibration attempts before the screen asks the players to try again.
    static let maximumAttempts = 3
}

#if DEBUG
/// DEBUG timing of the onboarding, printed as `[LaserSetupTiming]` lines and kept for tests.
nonisolated struct LaserSetupTimeline: Sendable {
    private(set) var origin: Double?
    private(set) var marks: [(name: String, at: Double)] = []
    mutating func mark(_ name: String, at time: Double, detail: String = "") {
        guard !marks.contains(where: { $0.name == name }) else { return }
        let start = origin ?? time
        origin = start
        marks.append((name, time))
        print(String(format: "[LaserSetupTiming] +%6.2f s  %@%@", time - start, name, detail.isEmpty ? "" : "  " + detail))
    }
    func elapsed(_ name: String) -> Double? {
        guard let origin, let mark = marks.first(where: { $0.name == name }) else { return nil }
        return mark.at - origin
    }
}
#endif
