import Foundation

/// Explicit inputs: LH-07 does not promote candidate timing values into production defaults.
nonisolated struct LaserEvidenceTiming: Equatable, Sendable {
    let windowBefore: Double
    let windowAfter: Double
    let deliveryAllowance: Double

    init(windowBefore: Double, windowAfter: Double, deliveryAllowance: Double) throws {
        try requireLaserValue([windowBefore, windowAfter, deliveryAllowance].allSatisfy { $0.isFinite && $0 >= 0 }
                              && (windowBefore + windowAfter + deliveryAllowance).isFinite, "evidence timing")
        self.windowBefore = windowBefore
        self.windowAfter = windowAfter
        self.deliveryAllowance = deliveryAllowance
    }

    func captureWindow(crossing: Double) -> ClosedRange<Double> {
        (crossing - windowBefore)...(crossing + windowAfter)
    }

    func finalizationTime(crossing: Double) -> Double {
        crossing + windowAfter + deliveryAllowance
    }
}

nonisolated struct LaserRoundConfiguration: Equatable, Sendable {
    let evidenceTiming: LaserEvidenceTiming
    let clearanceMargin: Double
    /// Nil until the owner approves the diamond reward; never silently substitute a value.
    let diamondPoints: Int?
    let scheduling: LaserSchedulingConfiguration?
    let initialTeamHealth = 5
    let clearTargetPoints = 100
    let activityDuration = 300.0
    let diamondTimeDuration = 15.0
    let vaultDuration = 5.0
    let maximumActiveBonusDiamonds = 4
    let missionGateTarget: Int
    let actionCueLead: Double?
    let primaryPlayerID: PlayerID?

    init(evidenceTiming: LaserEvidenceTiming, clearanceMargin: Double, diamondPoints: Int?,
         scheduling: LaserSchedulingConfiguration? = nil, missionGateTarget: Int = 5,
         actionCueLead: Double? = nil, primaryPlayerID: PlayerID? = nil) throws {
        try requireLaserValue(clearanceMargin.isFinite && clearanceMargin >= 0, "clearance margin")
        try requireLaserValue(diamondPoints.map { $0 >= 0 } ?? true, "diamond reward")
        self.evidenceTiming = evidenceTiming
        self.clearanceMargin = clearanceMargin
        self.diamondPoints = diamondPoints
        self.scheduling = scheduling
        try requireLaserValue(missionGateTarget > 0, "mission gate target")
        self.missionGateTarget = missionGateTarget
        try requireLaserValue(actionCueLead.map { $0.isFinite && $0 > 0 } ?? true, "action cue lead")
        self.actionCueLead = actionCueLead
        self.primaryPlayerID = primaryPlayerID
    }
}

nonisolated struct LaserPlayerDifficulty: Equatable, Sendable {
    let requestedCrownDropShare: Double
    let requestedSoleLiftShare: Double
    let beamThicknessShare: Double
    let maximumCrownDropShare: Double
    let maximumSoleLiftShare: Double
    /// Strict clearance needs reserve below the maximum, not a threshold exactly at the cap.
    let clearanceReserveShare: Double
    let maximumJumpsInWindow: Int
    let jumpWindow: Double
    let minimumJumpSpacing: Double
    let maximumConsecutiveJumps: Int
    let minimumTargetSpacing: Double
    let warningLead: Double
    let cueLead: Double
    let crossingOffset: Double

    func validate() throws {
        for share in [requestedCrownDropShare, requestedSoleLiftShare, beamThicknessShare,
                      maximumCrownDropShare, maximumSoleLiftShare] {
            try requireLaserValue(share.isFinite && share > 0 && share < 1, "difficulty/comfort share")
        }
        try requireLaserValue(clearanceReserveShare.isFinite && clearanceReserveShare > 0 && clearanceReserveShare < 1,
                              "clearance reserve")
        try requireLaserValue(maximumJumpsInWindow > 0 && maximumConsecutiveJumps > 0, "jump counts")
        try requireLaserValue([jumpWindow, minimumJumpSpacing, minimumTargetSpacing, warningLead, cueLead]
            .allSatisfy { $0.isFinite && $0 > 0 }, "scheduling durations")
        try requireLaserValue(warningLead >= cueLead && crossingOffset.isFinite && crossingOffset >= 0,
                              "cue/warning/crossing offset")
    }

    /// LH-01 review candidates only, not device/playtest validated safety thresholds.
    static let conservativeCandidate = Self(requestedCrownDropShare: 0.08, requestedSoleLiftShare: 0.02,
        beamThicknessShare: 0.01, maximumCrownDropShare: 0.10, maximumSoleLiftShare: 0.04,
        clearanceReserveShare: 0.1, maximumJumpsInWindow: 3, jumpWindow: 30,
        minimumJumpSpacing: 8, maximumConsecutiveJumps: 1, minimumTargetSpacing: 5,
        warningLead: 3, cueLead: 1.4, crossingOffset: 0)
}

nonisolated struct LaserSchedulingConfiguration: Equatable, Sendable {
    let players: [PlayerID: LaserPlayerDifficulty]
    let searchStep: Double
    let maximumSearchSteps: Int

    init(players: [PlayerID: LaserPlayerDifficulty], searchStep: Double, maximumSearchSteps: Int) throws {
        try requireLaserValue(Set(players.keys) == Set(PlayerID.allCases), "both scheduling profiles required")
        try requireLaserValue(searchStep.isFinite && searchStep > 0 && maximumSearchSteps > 0, "bounded schedule search")
        for profile in players.values { try profile.validate() }
        self.players = players
        self.searchStep = searchStep
        self.maximumSearchSteps = maximumSearchSteps
    }

    func actionCueTime(for target: LaserTarget) -> Double {
        // Configuration construction requires exactly the two shared slots.
        target.crossingTime - players[target.playerID]!.cueLead
    }
}
