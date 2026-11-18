//
//  LaserTeamOutcome.swift
//  Sedactive
//

import Foundation

/// The team's word for one laser encounter: PERFECT! when every player cleared it, ZAPPED! when
/// anyone was hit. Presentation only: it reads the game's finalized verdicts and decides nothing.
nonisolated enum LaserTeamCalloutKind: String, Sendable, CaseIterable {
    case perfect, zapped
}

nonisolated struct LaserTeamCallout: Equatable, Sendable {
    let kind: LaserTeamCalloutKind
    /// The logical encounter: a lone encounter's ID, or a combined sequence's vertical layer ID.
    let groupID: UUID
    /// Game time of the verdict that completed the callout (the frame it is shown).
    let gameTime: Double
}

/// Aggregates the per-player verdicts of one LOGICAL encounter into at most one team callout.
///
/// - A lone encounter (both players' DUCK, JUMP or LEAN targets): ZAPPED! on the first HIT (the
///   frame it is judged, with the player's own zap), PERFECT! once every target is CLEAR.
/// - A COMBINED sequence (a vertical LEAN layer, then its full-width DUCK `LaserWaveBeat.layerGap`
///   later) is one logical encounter: PERFECT! only once the DUCK is cleared too; ZAPPED! on the
///   first HIT of either laser. One callout per sequence, never one per laser.
/// - UNAVAILABLE (tracking) is never a success or a failure: a sequence with an UNAVAILABLE verdict
///   and no HIT gets no callout (the players' own neutral badges stay).
/// - A withdrawn attempt (recovery) does not count; its replacement attempt gets its own callout.
/// Per-player badges, zaps, sounds, health and score are untouched: this only adds the team word.
nonisolated struct LaserTeamOutcomeTracker: Sendable {
    /// Each combined sequence's vertical layer ID → its full-width DUCK's ID (the beat after it in
    /// the five-stage script; replay and live use the script's IDs).
    static let layerPartner: [UUID: UUID] = {
        let beats = LaserWaveBeat.fiveMinuteScript()
        var partners: [UUID: UUID] = [:]
        for (layer, laser) in zip(beats, beats.dropFirst()) where laser.followsLayer { partners[layer.id] = laser.id }
        return partners
    }()
    /// Every combined sequence member → its layer's ID (the sequence's group ID).
    static let groupOf: [UUID: UUID] = {
        var groups: [UUID: UUID] = [:]
        for (layer, laser) in layerPartner { groups[layer] = layer; groups[laser] = layer }
        return groups
    }()

    private var settled: Set<String> = []

    mutating func reset() { settled = [] }

    /// Call when a player's verdict for `encounterID` is shown. Returns the team callout when this
    /// verdict completes one; nil otherwise (still pending, already called out, or neutral).
    mutating func verdictShown(encounterID: UUID, in state: LaserGameState,
                               withdrawn: Set<UUID> = []) -> LaserTeamCallout? {
        let group = Self.groupOf[encounterID] ?? encounterID
        let memberIDs = Self.layerPartner[group].map { [group, $0] } ?? [encounterID]
        let members = memberIDs.compactMap { id in
            state.encounters.first { $0.encounter.id == id && !withdrawn.contains($0.encounter.attemptID) }
        }
        let key = ([group.uuidString] + members.map(\.encounter.attemptID.uuidString)).joined(separator: "/")
        guard !settled.contains(key) else { return nil }
        let verdicts = members.flatMap { member in
            member.encounter.targets.map { member.judgements[$0.playerID] }
        }
        var anyHit = false, allClear = members.count == memberIDs.count, resolved = allClear
        for verdict in verdicts {
            switch verdict {
            case .hit?: anyHit = true; allClear = false
            case .clear?: break
            case .unavailable?: allClear = false
            case .pending?, nil: allClear = false; resolved = false
            }
        }
        let kind: LaserTeamCalloutKind
        if anyHit { kind = .zapped } else if allClear { kind = .perfect } else {
            if resolved { settled.insert(key) } // neutral: UNAVAILABLE without a HIT
            return nil
        }
        settled.insert(key)
        return LaserTeamCallout(kind: kind, groupID: group, gameTime: state.gameTime)
    }
}
