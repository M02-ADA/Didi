//
//  BodySnapshot.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum TrackingStatus: String, Sendable, Codable { case reliable, uncertain, lost }
nonisolated enum JumpPhase: String, Sendable, Codable { case grounded, takingOff, airborne, landing, unknown }

nonisolated struct JumpState: Equatable, Sendable, Codable {
    let phase: JumpPhase
    let validity: EvidenceValidity
    func validate() throws {
        try requireBodyValue((phase == .unknown) == (validity != .valid), "jump phase/validity")
    }
}

nonisolated struct PlayerBodySample: Equatable, Sendable, Codable {
    let playerID: PlayerID
    let calibrationRevision: UInt64?
    let trackingStatus: TrackingStatus
    let geometry: BodyGeometry
    let jumpState: JumpState
    /// POSE-FIRST CANDIDATE (Kevin, 14 Nov 2026 — needs Edo's and Jevon's review): `true` when the
    /// tracker holds this player's identity only by squat presence (status stays `.uncertain`)
    /// and these measurements come from the landmarks Vision saw on that partial body. Set only by
    /// the DEBUG candidate; nil (absent) in production, which keeps today's rule below.
    var presenceOnly: Bool? = nil
    var isPresenceHeld: Bool { presenceOnly == true && trackingStatus == .uncertain }
    /// The player is in view as a tracked or presence-held body (not whether any action can be judged).
    var isPresent: Bool { trackingStatus == .reliable || isPresenceHeld }

    func validate() throws {
        try jumpState.validate()
        if let calibrationRevision { try requireBodyValue(calibrationRevision > 0, "sample calibration revision") }
        if (trackingStatus != .reliable && !isPresenceHeld) || calibrationRevision == nil {
            try requireBodyValue(geometry.measurements.allSatisfy { $0.validity != .valid }
                                 && jumpState.validity != .valid, "uncertain/uncalibrated evidence")
        }
    }
}

/// One capture, explicit P1/P2 samples even before binding/calibration. No delivery time or game state.
nonisolated struct BodySnapshot: Equatable, Sendable, Codable {
    let sessionGeneration: UUID
    let frameID: UInt64
    let capturedAt: Double
    let cameraGeometryRevision: UInt64
    let players: [PlayerID: PlayerBodySample]
    let wristContact: WristContactAttachmentV1?

    init(sessionGeneration: UUID, frameID: UInt64, capturedAt: Double,
         cameraGeometryRevision: UInt64, players: [PlayerID: PlayerBodySample],
         wristContact: WristContactAttachmentV1? = nil) {
        self.sessionGeneration = sessionGeneration; self.frameID = frameID; self.capturedAt = capturedAt
        self.cameraGeometryRevision = cameraGeometryRevision; self.players = players
        self.wristContact = wristContact
    }

    func validate() throws {
        try requireBodyValue(capturedAt.isFinite && capturedAt >= 0, "capturedAt")
        try requireBodyValue(cameraGeometryRevision > 0 && Set(players.keys) == Set(PlayerID.allCases),
                             "snapshot requires player1 and player2")
        try wristContact?.validate(matching: self)
        for (id, sample) in players {
            try requireBodyValue(id == sample.playerID, "sample dictionary identity")
            try sample.validate()
        }
    }
}
