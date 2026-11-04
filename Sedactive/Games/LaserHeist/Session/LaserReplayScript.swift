import Foundation

/// Small synthetic fixture based on Edo's schema-v2 calibration/body contract. No camera.
nonisolated struct LaserReplayScript: Sendable {
    let input: ReplayFixture
    let encounters: [LaserEncounter]
    let configuration: LaserRoundConfiguration
    let duration = 38.0
    let activityDuration = 32.0
    let vaultID = UUID(uuidString: "12000000-0000-4000-8000-000000000100")!
    /// Synthetic verified wrist-contact results; this is not a wrist-to-target detector.
    var vaultActions: [(time: Double, player: PlayerID?, button: LaserVaultButton?)] {
        [(17, nil, nil), (17.4, .player1, .bottom), (18, .player1, .top),
         (18.6, .player1, .middle), (19.2, .player2, .top), (20, .player2, .bottom), (21, .player2, .middle)]
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "laser-replay-slice", withExtension: "json") else {
            throw LaserDataError.invalidValue("missing bundled laser-replay-slice.json")
        }
        let fixture = try ReplayFixture.decode(Data(contentsOf: url))
        let context = BodyInputContext(sessionGeneration: fixture.configuration.sessionGeneration,
            cameraGeometryRevision: fixture.cameraGeometryRevision,
            calibrationRevisions: fixture.configuration.calibrations.mapValues(\.revision),
            cutovers: fixture.configuration.calibrations.mapValues {
                BodyInputCutover(frameID: $0.sourceFrameID, capturedAt: $0.capturedAt)
            }, isActive: true)
        try requireLaserValue(fixture.records.allSatisfy { record in
            guard let snapshot = record.snapshot else { return false }
            return context.accepts(snapshot)
        }, "slice requires compatible snapshot-only records")
        let config = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: 1) // Short demo: one co-op checkpoint.
        let encounters = try [4.0, 10.0, 16.0].enumerated().map { index, time in
            let move: LaserMove = index == 1 ? .jump : .duck
            let band = try LaserBeamBand(lowerY: move == .duck ? 1.45 : 0.005,
                                         upperY: move == .duck ? 1.5 : 0.015)
            let targets = try PlayerID.allCases.map { player in
                try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: move,
                                beam: band, warningTime: time - 3, crossingTime: time)
            }
            let id = UUID(uuidString: String(format: "12000000-0000-4000-8000-%012d", index + 1))!
            return try LaserEncounter(id: id, attemptID: id, targets: targets)
        }
        return Self(input: fixture, encounters: encounters, configuration: config)
    }
}
