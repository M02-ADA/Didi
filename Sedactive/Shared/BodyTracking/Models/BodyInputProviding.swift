//
//  BodyInputProviding.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum BodyInputOperationError: Error, Equatable, Sendable {
    case notRunning, configurationChanged, generationReused, wrongGeneration
    case consumerAlreadyClaimed, observerAlreadyRegistered, reentrantControl
}

nonisolated enum BodyInputFailure: String, Sendable, Codable {
    case permissionDenied, cameraUnavailable, processingFailure, clockNormalizationFailure
}
nonisolated enum BodyInputInterruption: String, Sendable, Codable {
    case system, cameraUnavailable
}
nonisolated enum BodyInputStatus: Equatable, Sendable, Codable {
    case stopped, starting, running
    case interrupted(BodyInputInterruption)
    case failed(BodyInputFailure)
}
nonisolated enum BodyInputProgress: String, Sendable { case waiting, progressing, suspectedStall }
nonisolated enum BodyInputDelivery: String, Sendable { case prepared, claimed, closed }
nonisolated enum BodyInputTerminationReason: String, Sendable {
    case released, cancelled, finished, stopped, failed
}

nonisolated enum NoProgressPolicy: Equatable, Sendable, Codable {
    case disabled
    /// Diagnostic only, never a pause/failure or production timeout.
    case diagnostic(threshold: Double)
    func validate() throws {
        if case let .diagnostic(threshold) = self {
            try requireBodyValue(threshold.isFinite && threshold > 0, "stall investigation threshold")
        }
    }
}

nonisolated struct BodyInputConfiguration: Equatable, Sendable, Codable {
    let sessionGeneration: UUID
    let selectedPlayers: SelectedPlayers
    let calibrations: [PlayerID: PlayerCalibration]
    let playerPlaneLayout: PlayerPlaneLayout
    let snapshotBufferCapacity: Int
    let noProgressPolicy: NoProgressPolicy

    init(sessionGeneration: UUID, selectedPlayers: SelectedPlayers,
         calibrations: [PlayerID: PlayerCalibration], playerPlaneLayout: PlayerPlaneLayout,
         snapshotBufferCapacity: Int = 8, noProgressPolicy: NoProgressPolicy = .disabled) {
        self.sessionGeneration = sessionGeneration
        self.selectedPlayers = selectedPlayers
        self.calibrations = calibrations
        self.playerPlaneLayout = playerPlaneLayout
        self.snapshotBufferCapacity = snapshotBufferCapacity
        self.noProgressPolicy = noProgressPolicy
    }

    func validate() throws {
        try selectedPlayers.validate()
        try playerPlaneLayout.validate()
        try noProgressPolicy.validate()
        try requireBodyValue(snapshotBufferCapacity > 0, "snapshotBufferCapacity")
        for (id, calibration) in calibrations {
            try calibration.validate()
            try requireBodyValue(id == calibration.playerID && selectedPlayers.ids.contains(id)
                                 && calibration.sessionGeneration == sessionGeneration, "calibration identity")
        }
        try requireBodyValue(Set(calibrations.values.map(\.cameraGeometryRevision)).count <= 1,
                             "mixed camera calibration geometry")
    }

    func replacingCalibrations(_ values: [PlayerID: PlayerCalibration]) -> Self {
        Self(sessionGeneration: sessionGeneration, selectedPlayers: selectedPlayers, calibrations: values,
             playerPlaneLayout: playerPlaneLayout, snapshotBufferCapacity: snapshotBufferCapacity,
             noProgressPolicy: noProgressPolicy)
    }
}

nonisolated struct BodyInputCutover: Equatable, Sendable {
    let frameID: UInt64
    let capturedAt: Double
}

/// Read this AGAIN after suspension and before accepting evidence into gameplay history.
nonisolated struct BodyInputContext: Equatable, Sendable {
    let sessionGeneration: UUID
    let selectedPlayers: SelectedPlayers
    let cameraGeometryRevision: UInt64
    let calibrationRevisions: [PlayerID: UInt64]
    let cutovers: [PlayerID: BodyInputCutover]
    let isActive: Bool

    func accepts(_ snapshot: BodySnapshot, playerID: PlayerID) -> Bool {
        guard isActive, snapshot.sessionGeneration == sessionGeneration,
              snapshot.cameraGeometryRevision == cameraGeometryRevision,
              selectedPlayers.ids.contains(playerID), let sample = snapshot.players[playerID],
              sample.playerID == playerID,
              sample.calibrationRevision == calibrationRevisions[playerID] else { return false }
        if let cutover = cutovers[playerID] {
            return snapshot.frameID > cutover.frameID && snapshot.capturedAt > cutover.capturedAt
        }
        return true
    }

    func accepts(_ snapshot: BodySnapshot) -> Bool {
        Set(snapshot.players.keys) == Set(selectedPlayers.ids)
            && selectedPlayers.ids.allSatisfy { accepts(snapshot, playerID: $0) }
    }
}

nonisolated struct BodyInputDiagnostics: Equatable, Sendable {
    private(set) var droppedSnapshotCount: UInt64 = 0
    private(set) var terminatedYieldCount: UInt64 = 0
    private(set) var subscriptionTerminationCount: UInt64 = 0
    private(set) var rejectedSnapshotCount: UInt64 = 0
    private(set) var lastTerminationReason: BodyInputTerminationReason?

    mutating func dropped() { if droppedSnapshotCount < .max { droppedSnapshotCount += 1 } }
    mutating func terminatedYield() { if terminatedYieldCount < .max { terminatedYieldCount += 1 } }
    mutating func terminated(_ reason: BodyInputTerminationReason) {
        if subscriptionTerminationCount < .max { subscriptionTerminationCount += 1 }
        lastTerminationReason = reason
    }
    mutating func rejected() { if rejectedSnapshotCount < .max { rejectedSnapshotCount += 1 } }
}

nonisolated struct BodyInputStatusEvent: Equatable, Sendable {
    let sessionGeneration: UUID?
    let occurredAt: Double
    let statusRevision: UInt64
    let status: BodyInputStatus
    let context: BodyInputContext?
    let delivery: BodyInputDelivery
    let progress: BodyInputProgress
}

/// App-module shared surface. No capture, clock conversion, evidence selection or verdicts here.
@MainActor
protocol BodyInputProviding: AnyObject {
    var latestSnapshot: BodySnapshot? { get }
    var currentContext: BodyInputContext? { get }
    var status: BodyInputStatus { get }
    var diagnostics: BodyInputDiagnostics { get }
    func start(configuration: BodyInputConfiguration) async throws
    func stop() async
    @discardableResult
    func setCalibrations(_ values: [PlayerID: PlayerCalibration], generation: UUID) async throws -> BodyInputContext
    func snapshotStream(generation: UUID) throws -> AsyncStream<BodySnapshot>
    func releaseSnapshotSubscription(generation: UUID) throws
    @discardableResult
    func statusUpdates(_ observer: @escaping @MainActor (BodyInputStatusEvent) -> Void) throws -> UUID
    func removeStatusObserver(_ token: UUID) throws
}
