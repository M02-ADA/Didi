//
//  LaserCollisionJudge.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// One immutable capture with separately supplied clock conversion and arrival metadata.
nonisolated struct LaserBodyEvidence: Equatable, Sendable {
    let snapshot: BodySnapshot
    let capturedGameTime: Double
    let arrivedGameTime: Double
}

nonisolated enum LaserEvidenceSelection: Equatable, Sendable {
    case pending
    case selected(LaserBodyEvidence)
    case unavailable(LaserUnavailableReason)
    case withdrawn
}

nonisolated struct LaserCollisionJudge: Sendable {
    /// Pure target-local geometry check. Nil means withdrawn, never an implicit CLEAR.
    func judge(target: LaserTarget, selection: LaserEvidenceSelection, clearanceMargin: Double,
               context: BodyInputContext) throws -> Judgement? {
        try requireLaserValue(clearanceMargin.isFinite && clearanceMargin >= 0, "clearance margin")
        switch selection {
        case .pending: return .pending(.awaitingFinalization)
        case .withdrawn: return nil
        case .unavailable(let reason): return .unavailable(reason)
        case .selected(let evidence):
            if let reason = unavailableReason(target: target, snapshot: evidence.snapshot, context: context) {
                return .unavailable(reason)
            }
            guard let sample = evidence.snapshot.players[target.playerID] else { return .unavailable(.incompatibleContext) }
            switch target.requiredMove {
            case .duck:
                // Required validity checked above; no other player's measurements are consulted.
                guard let crown = sample.geometry.crownY.value,
                      let left = sample.geometry.leftWristY.value,
                      let right = sample.geometry.rightWristY.value else { return .unavailable(.incompatibleContext) }
                return max(crown, left, right) + clearanceMargin < target.beam.lowerY
                    ? .clear : .hit(.insufficientClearance)
            case .jump:
                guard let left = sample.geometry.leftSoleY.value,
                      let right = sample.geometry.rightSoleY.value else { return .unavailable(.incompatibleContext) }
                guard min(left, right) - clearanceMargin > target.beam.upperY else {
                    return .hit(.insufficientClearance)
                }
                return sample.jumpState.phase == .airborne ? .clear : .hit(.notAirborne)
            }
        }
    }

    func select(target: LaserTarget, history: [LaserBodyEvidence], timing: LaserEvidenceTiming,
                context: BodyInputContext) -> LaserEvidenceSelection {
        let window = timing.captureWindow(crossing: target.crossingTime)
        let deadline = timing.finalizationTime(crossing: target.crossingTime)
        let arrived = history.filter { $0.arrivedGameTime <= deadline }
        let eligible = arrived.filter { window.contains($0.capturedGameTime) }
        let ordered = eligible.sorted {
            let left = abs($0.capturedGameTime - target.crossingTime)
            let right = abs($1.capturedGameTime - target.crossingTime)
            if left != right { return left < right }
            if $0.capturedGameTime != $1.capturedGameTime { return $0.capturedGameTime < $1.capturedGameTime }
            return $0.snapshot.frameID < $1.snapshot.frameID
        }
        for evidence in ordered {
            if unavailableReason(target: target, snapshot: evidence.snapshot, context: context) == nil {
                return .selected(evidence)
            }
        }
        if let nearest = ordered.first,
           let reason = unavailableReason(target: target, snapshot: nearest.snapshot, context: context) {
            return .unavailable(reason)
        }
        if arrived.contains(where: { $0.capturedGameTime < window.lowerBound }) { return .unavailable(.stale) }
        return .unavailable(.noSample)
    }

    private func unavailableReason(target: LaserTarget, snapshot: BodySnapshot,
                                   context: BodyInputContext) -> LaserUnavailableReason? {
        guard context.accepts(snapshot, playerID: target.playerID),
              let sample = snapshot.players[target.playerID],
              sample.calibrationRevision == target.calibrationRevision else { return .incompatibleContext }
        guard sample.trackingStatus == .reliable else {
            return .invalidEvidence(target.requiredMove == .duck ? .crown : .leftSole, .identityUncertain)
        }
        let required: [(LaserEvidenceRequirement, EstimatedScalar)] = target.requiredMove == .duck
            ? [(.crown, sample.geometry.crownY), (.leftWrist, sample.geometry.leftWristY), (.rightWrist, sample.geometry.rightWristY)]
            : [(.leftSole, sample.geometry.leftSoleY), (.rightSole, sample.geometry.rightSoleY)]
        for (name, scalar) in required where scalar.validity != .valid {
            return .invalidEvidence(name, scalar.validity)
        }
        if target.requiredMove == .jump && sample.jumpState.validity != .valid {
            return .invalidEvidence(.jumpPhase, sample.jumpState.validity)
        }
        if target.requiredMove == .jump {
            do { try sample.jumpState.validate() }
            catch { return .incompatibleContext }
        }
        return nil
    }
}
