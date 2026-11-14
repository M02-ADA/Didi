import Foundation

/// Planner input, not approval of production recovery/comfort policy. No default planner is installed.
nonisolated struct LaserLiveRecoveryRequest: Sendable {
    let withdrawn: [LaserEncounter]
    let gameTime: Double
    let hostTime: Double
    let context: BodyInputContext
}

nonisolated enum LaserLiveRecovery {
    /// Preserve judge geometry and require full warnings. The injected owner-reviewed planner must
    /// additionally approve physical jump reservations, comfort, and segment/vault boundaries.
    /// - Parameter boundary: the live director's current vault time; replacements must be
    ///   judged before it. Without a director, the round's activity duration (no vault pauses).
    static func validate(_ replacements: [LaserEncounter], request: LaserLiveRecoveryRequest,
                         configuration: LaserRoundConfiguration, boundary: Double? = nil) throws {
        try requireLaserValue(Set(replacements.map(\.id)) == Set(request.withdrawn.map(\.id))
            && replacements.count == request.withdrawn.count
            && Set(replacements.map(\.attemptID)).count == replacements.count, "complete recovery plan")
        let oldIDs = Set(request.withdrawn.map(\.attemptID))
        for encounter in replacements {
            guard let old = request.withdrawn.first(where: { $0.id == encounter.id }) else {
                throw LaserDataError.invalidValue("unknown recovery encounter")
            }
            try requireLaserValue(!oldIDs.contains(encounter.attemptID), "fresh recovery attempt")
            for target in encounter.targets {
                let previous = old.targets.first { $0.playerID == target.playerID }!
                try requireLaserValue(target.requiredMove == previous.requiredMove && target.beam == previous.beam
                    && target.calibrationRevision == request.context.calibrationRevisions[target.playerID]
                    && target.warningTime >= request.gameTime
                    && target.crossingTime - target.warningTime >= previous.crossingTime - previous.warningTime
                    && configuration.evidenceTiming.finalizationTime(crossing: target.crossingTime)
                        < (boundary ?? configuration.activityDuration), "recovery geometry/warning/boundary")
            }
        }
    }
}
