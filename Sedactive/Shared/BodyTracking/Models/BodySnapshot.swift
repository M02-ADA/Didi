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

    func validate() throws {
        try jumpState.validate()
        if let calibrationRevision { try requireBodyValue(calibrationRevision > 0, "sample calibration revision") }
        if trackingStatus != .reliable || calibrationRevision == nil {
            try requireBodyValue(geometry.measurements.allSatisfy { $0.validity != .valid }
                                 && jumpState.validity != .valid, "uncertain/uncalibrated evidence")
        }
    }
}

/// One capture, two explicit selected-player samples. Delivery time is deliberately absent.
nonisolated struct BodySnapshot: Equatable, Sendable, Codable {
    let sessionGeneration: UUID
    let frameID: UInt64
    let capturedAt: Double
    let cameraGeometryRevision: UInt64
    let players: [PlayerID: PlayerBodySample]

    func validate() throws {
        try requireBodyValue(capturedAt.isFinite && capturedAt >= 0, "capturedAt")
        try requireBodyValue(cameraGeometryRevision > 0 && players.count == 2, "snapshot envelope")
        for (id, sample) in players {
            try requireBodyValue(id == sample.playerID, "sample dictionary identity")
            try sample.validate()
        }
    }
}
