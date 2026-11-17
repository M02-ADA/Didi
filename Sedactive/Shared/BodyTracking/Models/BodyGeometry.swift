//
//  BodyGeometry.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum BodyInputContractError: Error, Equatable, Sendable {
    case invalidValue(String)
    case incompatibleContext
    case conflictingObservation
}

nonisolated func requireBodyValue(_ condition: Bool, _ field: String) throws {
    if !condition { throw BodyInputContractError.invalidValue(field) }
}

nonisolated enum EvidenceValidity: String, Sendable, Codable, CaseIterable {
    case valid, lowConfidence, missingLandmarks, outOfFrame, stale, identityUncertain, notCalibrated
}

nonisolated struct EstimatedScalar: Equatable, Sendable, Codable {
    let value: Double?
    let validity: EvidenceValidity

    init(value: Double?, validity: EvidenceValidity) throws {
        try requireBodyValue(validity == .valid ? (value?.isFinite == true) : value == nil,
                             "valid scalar requires finite value; invalid scalar requires nil")
        self.value = value
        self.validity = validity
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: values.decodeIfPresent(Double.self, forKey: .value),
                      validity: values.decode(EvidenceValidity.self, forKey: .validity))
    }
}

/// Upright, UNMIRRORED player-plane units; Y up from floor 0.
/// Anatomical left/right remain unchanged by the eventual display reflection.
nonisolated struct BodyGeometry: Equatable, Sendable, Codable {
    let crownY: EstimatedScalar
    let leftWristY: EstimatedScalar
    let rightWristY: EstimatedScalar
    let leftSoleY: EstimatedScalar
    let rightSoleY: EstimatedScalar
    let centerX: EstimatedScalar
    /// LEAN evidence (vertical lasers, 16 November 2026): how far the trunk leans sideways, in the
    /// same UNMIRRORED player-plane units as `centerX`: the shoulders' centre past the hips' centre,
    /// confirmed by the head (`BodyMeasurementExtractor.trunkLean`), + toward image +X. Nil in
    /// recordings made before it existed (decoded as absent, never as upright).
    var trunkLeanX: EstimatedScalar? = nil
    var measurements: [EstimatedScalar] {
        [crownY, leftWristY, rightWristY, leftSoleY, rightSoleY, centerX] + (trunkLeanX.map { [$0] } ?? [])
    }
}

nonisolated struct PlayerPlaneLayout: Equatable, Sendable, Codable {
    let leftCenterX: Double
    let rightCenterX: Double
    let gameUnitsPerImageHeight: Double

    func validate() throws {
        try requireBodyValue(leftCenterX.isFinite && rightCenterX.isFinite && leftCenterX < rightCenterX,
                             "lane centers")
        try requireBodyValue(gameUnitsPerImageHeight.isFinite && gameUnitsPerImageHeight > 0, "shared scale")
    }

    func centerX(for playerID: PlayerID) -> Double {
        switch playerID {
        case .player1: leftCenterX
        case .player2: rightCenterX
        }
    }
}
