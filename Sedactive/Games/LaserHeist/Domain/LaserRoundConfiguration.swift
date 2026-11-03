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
    let initialTeamHealth = 5
    let clearTargetPoints = 100
    let activityDuration = 300.0
    let diamondTimeDuration = 15.0
    let vaultDuration = 5.0
    let maximumActiveBonusDiamonds = 4

    init(evidenceTiming: LaserEvidenceTiming, clearanceMargin: Double, diamondPoints: Int?) throws {
        try requireLaserValue(clearanceMargin.isFinite && clearanceMargin >= 0, "clearance margin")
        try requireLaserValue(diamondPoints.map { $0 >= 0 } ?? true, "diamond reward")
        self.evidenceTiming = evidenceTiming
        self.clearanceMargin = clearanceMargin
        self.diamondPoints = diamondPoints
    }
}
