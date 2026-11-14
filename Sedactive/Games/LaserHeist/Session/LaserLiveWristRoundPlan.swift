import Foundation

/// Explicit owner-approved round inputs, NOT calibration or a production geometry default.
/// Construct only after E05 acceptance, against the current exact producer context.
nonisolated struct LaserLiveWristRoundPlan: Sendable {
    let expectedContext: BodyInputContext
    let configuration: LaserRoundConfiguration
    let encounters: [LaserEncounter]
    let timing: LaserLiveTimingPolicy
    let diamonds: LaserWristDiamondConfiguration
    /// When set, the director registers its own schedule as the round reaches it, and
    /// `encounters` is that whole schedule (validated here, not registered up front).
    let director: LaserLiveRoundDirector?

    init(expectedContext: BodyInputContext, configuration: LaserRoundConfiguration,
         encounters: [LaserEncounter], timing: LaserLiveTimingPolicy,
         diamonds: LaserWristDiamondConfiguration, director: LaserLiveRoundDirector? = nil) throws {
        try requireLaserValue(director.map { $0.baseEncounters.map(\.id) == encounters.map(\.id)
            && $0.layout == diamonds.layout } ?? true, "director schedule matches the plan")
        try requireLaserValue(expectedContext.isActive && expectedContext.wristContact != nil
            && Set(expectedContext.calibrationRevisions.keys) == Set(director?.roster ?? PlayerID.allCases)
            && expectedContext.calibrationRevisions.values.allSatisfy { $0 > 0 }
            && configuration.diamondPoints == LaserRoundConfiguration.approvedDiamondPoints
            && !encounters.isEmpty && Set(encounters.map(\.id)).count == encounters.count
            && Set(encounters.map(\.attemptID)).count == encounters.count
            && encounters.allSatisfy { encounter in
                Set(encounter.targets.map(\.playerID)) == Set(director?.roster ?? PlayerID.allCases)
                    && encounter.targets.allSatisfy { expectedContext.calibrationRevisions[$0.playerID] == $0.calibrationRevision }
            }, "accepted live wrist context/round plan")
        self.expectedContext = expectedContext; self.configuration = configuration
        self.encounters = encounters; self.timing = timing; self.diamonds = diamonds
        self.director = director
    }

    /// The live round: the complete replay's schedule and rules, built from the producer's
    /// ACCEPTED calibrations for this exact context. Nothing here is evidence or a verdict.
    /// - Parameter segmentLength: 60 for a real round; DEBUG `-liveShortRound` passes less.
    static func completeRound(context: BodyInputContext, calibrations: [PlayerID: PlayerCalibration],
                              layout: PlayerPlaneLayout, seed: UInt64 = 1,
                              segmentLength: Double = 60, roster: [PlayerID] = PlayerID.allCases) throws -> Self {
        try requireLaserValue(Set(calibrations.keys) == Set(roster)
            && roster.allSatisfy { context.calibrationRevisions[$0] == calibrations[$0]?.revision },
                              "accepted calibrations for this context")
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        let director = try LaserLiveRoundDirector(calibrations: calibrations, layout: layout,
            configuration: configuration, seed: seed, segmentLength: segmentLength, roster: roster)
        let standingHeights = calibrations.mapValues {
            LaserLiveRoundGeometryV1.standingHeight($0, layout: layout)
        }
        return try Self(expectedContext: context, configuration: configuration,
            encounters: director.baseEncounters, timing: liveTiming,
            diamonds: .init(layout: layout, radius: director.diamondRadius, replacementPlanner: director.planner,
                            standingHeights: standingHeights),
            director: director)
    }

    /// Live readiness timing for device rounds (owner-approved 11 November 2026, pending
    /// device measurement): 1 s of steady, valid tracking before Start, evidence older than
    /// 0.5 s pauses the round, and a 3 s countdown.
    /// During play, a missing or unusable body observation pauses the round. Before play,
    /// brief flickers still have the normal evidence-age allowance during the countdown.
    static var liveTiming: LaserLiveTimingPolicy {
        try! LaserLiveTimingPolicy(settlingDuration: 1, maximumEvidenceAge: 0.5, countdownDuration: 3,
                                   preservesCountdownOnTrackingFlicker: true,
                                   // POSE-FIRST TRACKING (production default; DEBUG `-trackingBaseline` turns it off).
                                   absenceGrace: PoseFirstCandidate.isEnabled ? PoseFirstCandidate.absenceGrace : nil)
    }
}

/// Presentation projection only. A zero blocker count NEVER replaces J03/producer admission.
nonisolated enum LaserLiveWristBlocker: String, Hashable, Sendable {
    case source, binding, calibration, geometry, roundPlan, measurements, paused
    var explanation: String {
        switch self {
        case .source: "Camera source is stopped or unavailable."
        case .binding: "Genuine current pair binding and player confirmation are required."
        case .calibration: "E05 has not accepted both standing references. Current collection cannot validate crown and independent soles."
        case .geometry: "Production diamond radius, reach and placement plan are not configured."
        case .roundPlan: "No context-bound live round plan is installed."
        case .measurements: "J03 requires fresh valid crown, wrists, both soles and airborne/grounded evidence before admitting gameplay."
        case .paused: "Contact is refused while paused, restarting or stopped."
        }
    }
}
