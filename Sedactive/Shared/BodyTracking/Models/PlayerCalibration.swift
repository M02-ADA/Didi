//
//  PlayerCalibration.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//  stores calibration result

import Foundation

/// Camera references only. Scale and lane centers belong to PlayerPlaneLayout.
nonisolated struct ImageToPlayerPlaneMapping: Equatable, Sendable, Codable {
    let imageAspectRatio: Double
    let floorImageY: Double
    let originImageX: Double

    func validate() throws {
        try requireBodyValue(imageAspectRatio.isFinite && imageAspectRatio > 0, "imageAspectRatio")
        try requireBodyValue(floorImageY.isFinite && (0...1).contains(floorImageY), "floorImageY")
        try requireBodyValue(originImageX.isFinite && (0...1).contains(originImageX), "originImageX")
    }

    func gameY(imageY: Double, layout: PlayerPlaneLayout) -> Double {
        (imageY - floorImageY) * layout.gameUnitsPerImageHeight
    }

    func gameX(imageX: Double, playerID: PlayerID, selection: SelectedPlayers,
               layout: PlayerPlaneLayout) throws -> Double {
        let center = try layout.centerX(for: playerID, selection: selection)
        return center + (imageX - originImageX) * imageAspectRatio * layout.gameUnitsPerImageHeight
    }
}

/// Immutable standing reference, not a calibration algorithm or a live measurement.
nonisolated struct PlayerCalibration: Equatable, Sendable, Codable {
    let playerID: PlayerID
    let sessionGeneration: UUID
    let revision: UInt64
    let cameraGeometryRevision: UInt64
    let sourceFrameID: UInt64
    let capturedAt: Double
    let standingCrownImageY: Double
    let standingLeftSoleImageY: Double
    let standingRightSoleImageY: Double
    let standingHipImageY: Double
    let standingBodyImageHeight: Double
    let standingTorsoImageLength: Double
    let headOffsetFromNoseShare: Double
    let leftFootOffsetShare: Double
    let rightFootOffsetShare: Double
    let mapping: ImageToPlayerPlaneMapping

    func validate() throws {
        try mapping.validate()
        try requireBodyValue(revision > 0 && cameraGeometryRevision > 0, "calibration revisions")
        try requireBodyValue(capturedAt.isFinite && capturedAt >= 0, "calibration capturedAt")
        for y in [standingCrownImageY, standingLeftSoleImageY, standingRightSoleImageY, standingHipImageY] {
            try requireBodyValue(y.isFinite && (0...1).contains(y), "standing image Y")
        }
        try requireBodyValue(standingBodyImageHeight > 0 && standingBodyImageHeight.isFinite, "body height")
        let height = standingCrownImageY - min(standingLeftSoleImageY, standingRightSoleImageY)
        try requireBodyValue(abs(height - standingBodyImageHeight) < 0.000001, "standing span")
        try requireBodyValue(standingTorsoImageLength.isFinite && standingTorsoImageLength > 0, "torso length")
        for offset in [headOffsetFromNoseShare, leftFootOffsetShare, rightFootOffsetShare] {
            try requireBodyValue(offset.isFinite && offset >= 0, "calibration offset")
        }
    }
}
