//
//  LaserFinalVaultEntry.swift
//  Sedactive
//

import Foundation

/// The scripted way into the final vault, between the last Dual Key Vault and
/// Diamond Time (Sketch Home Copy 31 → 34 → 33 → 32): the vault at the end of
/// the corridor comes up, its round door opens, Lemon jumps through the doorway,
/// then Tangerine (co-op only), the view follows them inside and they land in
/// the vault room. Seconds from the start of the entry.
///
/// A presentation script, not gameplay: nobody's jump is detected or judged and
/// nothing is scored. The live session holds `GameClock` while it plays
/// (`LaserLiveReadiness.holdClock`), so Diamond Time's active seconds start
/// after it and no evidence captured during it can collect a diamond.
nonisolated struct LaserFinalVaultTimeline: Equatable, Sendable {
    /// The vault slides up the corridor to its stop.
    static let approach = 0.0...1.5
    /// The closed door's wheel unlocks (a short shake).
    static let unlock = 1.5...1.75
    /// The closed art gives way to the open art; the room shows through the doorway.
    static let open = 1.75...2.4
    static let firstJump = 2.5
    /// One mascot after the other: the second leaves while the first is inside.
    static let jumpSpacing = 0.85
    static let jumpDuration = 1.0
    /// The crouch before take-off, at the start of each jump.
    static let anticipation = 0.22
    /// The view follows them through the doorway.
    static let pushDuration = 0.7
    /// They drop into their places inside the room.
    static let landDuration = 0.55

    /// The mascots that jump, in order: Lemon (P1) first.
    let jumpers: [PlayerID]

    init(roster: [PlayerID]) {
        jumpers = PlayerID.allCases.filter(roster.contains)
    }

    /// When `player` jumps, or `nil` if they are not in the round.
    func jump(of player: PlayerID) -> ClosedRange<Double>? {
        guard let index = jumpers.firstIndex(of: player) else { return nil }
        let start = Self.firstJump + Self.jumpSpacing * Double(index)
        return start...(start + Self.jumpDuration)
    }

    var push: ClosedRange<Double> {
        let start = (jumpers.indices.last.map { Self.firstJump + Self.jumpSpacing * Double($0) + Self.jumpDuration }
            ?? Self.open.upperBound) + 0.05
        return start...(start + Self.pushDuration)
    }

    var land: ClosedRange<Double> { push.upperBound...(push.upperBound + Self.landDuration) }

    var total: Double { land.upperBound }
}

/// One final-vault entry in progress: how much of its script has played. Only
/// running time counts (`advance` is not called while the round is paused),
/// so a pause holds the scene where it is.
nonisolated struct LaserFinalVaultEntry: Equatable, Sendable {
    let timeline: LaserFinalVaultTimeline
    private(set) var elapsed = 0.0

    init(roster: [PlayerID]) {
        timeline = LaserFinalVaultTimeline(roster: roster)
    }

    var isComplete: Bool { elapsed >= timeline.total }

    mutating func advance(by seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        elapsed = min(timeline.total, elapsed + seconds)
    }
}
