import Foundation

/// Explicit owner-approved round inputs, NOT calibration or a production geometry default.
/// Construct only after E05 acceptance, against the current exact producer context.
nonisolated struct LaserLiveWristRoundPlan: Sendable {
    let expectedContext: BodyInputContext
    let configuration: LaserRoundConfiguration
    let encounters: [LaserEncounter]
    let timing: LaserLiveTimingPolicy
    let diamonds: LaserWristDiamondConfiguration

    init(expectedContext: BodyInputContext, configuration: LaserRoundConfiguration,
         encounters: [LaserEncounter], timing: LaserLiveTimingPolicy,
         diamonds: LaserWristDiamondConfiguration) throws {
        try requireLaserValue(expectedContext.isActive && expectedContext.wristContact != nil
            && Set(expectedContext.calibrationRevisions.keys) == Set(PlayerID.allCases)
            && expectedContext.calibrationRevisions.values.allSatisfy { $0 > 0 }
            && configuration.diamondPoints == LaserRoundConfiguration.approvedDiamondPoints
            && !encounters.isEmpty && Set(encounters.map(\.id)).count == encounters.count
            && Set(encounters.map(\.attemptID)).count == encounters.count
            && encounters.allSatisfy { encounter in
                Set(encounter.targets.map(\.playerID)) == Set(PlayerID.allCases)
                    && encounter.targets.allSatisfy { expectedContext.calibrationRevisions[$0.playerID] == $0.calibrationRevision }
            }, "accepted live wrist context/round plan")
        self.expectedContext = expectedContext; self.configuration = configuration
        self.encounters = encounters; self.timing = timing; self.diamonds = diamonds
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
