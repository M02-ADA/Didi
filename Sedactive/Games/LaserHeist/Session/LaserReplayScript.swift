import Foundation

/// Small synthetic fixture based on Edo's schema-v2 calibration/body contract. No camera.
nonisolated struct LaserReplayScript: Sendable {
    let input: ReplayFixture
    let encounters: [LaserEncounter]
    let configuration: LaserRoundConfiguration
    let fullRound: LaserFullReplayPlan?
    var duration: Double { fullRound?.duration ?? (17 + configuration.vaultDuration + configuration.diamondTimeDuration + 1) }
    var activityDuration: Double { fullRound == nil ? 17 + configuration.diamondTimeDuration : 310 }

    init(input: ReplayFixture, encounters: [LaserEncounter], configuration: LaserRoundConfiguration,
         fullRound: LaserFullReplayPlan? = nil) {
        self.input = input; self.encounters = encounters; self.configuration = configuration; self.fullRound = fullRound
    }

    enum Scenario: Hashable, Sendable {
        case standard, healthDepleted, vaultTimeout

        static var launchSelection: Self {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-replayAllHits") { return .healthDepleted }
            if arguments.contains("-replayVaultTimeout") { return .vaultTimeout }
            #endif
            return .standard
        }
    }

    static func complete(seed: UInt64 = 1, bundle: Bundle = .main,
                         scenario: Scenario = .launchSelection) throws -> Self {
        try LaserFullReplayPlan.make(base: load(bundle: bundle).input, seed: seed, scenario: scenario)
    }
    let vaultID = UUID(uuidString: "12000000-0000-4000-8000-000000000100")!
    /// Script-declared synthetic tracking coverage, not inferred physical movement between frames.
    var trackedCoverage: ClosedRange<Double> { 0.1...(fullRound?.bonusStart ?? 17) }
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
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: 1, actionCueLead: 1.4)
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

    /// A new lifecycle namespace for the same immutable synthetic recording; no profile identity inferred.
    func freshRound(generation: UUID) throws -> Self {
        func replaceGeneration(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.mapValues { replaceGeneration($0) }.merging(
                    object["sessionGeneration"] == nil ? [:] : ["sessionGeneration": generation.uuidString]) { _, new in new }
            }
            if let values = value as? [Any] { return values.map(replaceGeneration) }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        let data = try JSONSerialization.data(withJSONObject: replaceGeneration(object), options: [.sortedKeys])
        return Self(input: try ReplayFixture.decode(data), encounters: encounters, configuration: configuration, fullRound: fullRound)
    }
}
