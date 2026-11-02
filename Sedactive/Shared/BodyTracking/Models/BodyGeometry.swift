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
    var measurements: [EstimatedScalar] { [crownY, leftWristY, rightWristY, leftSoleY, rightSoleY, centerX] }
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

    func centerX(for playerID: PlayerID, selection: SelectedPlayers) throws -> Double {
        if playerID == selection.firstID { return leftCenterX }
        if playerID == selection.secondID { return rightCenterX }
        throw BodyInputContractError.incompatibleContext
    }
}
