//
//  AvatarFairnessProbe.swift
//  Sedactive
//

import RealityKit
import simd

// K04 (presentation diagnostic; evidence for the PENDING D07 policy).
//
// Measures where the shown mascot's laser-relevant extremities are, from the
// actual solved rig transforms and the scene's own world mapping, and puts
// them beside the band the beam is drawn from and the authoritative verdict
// that `LaserCollisionJudge` gave the human evidence. It reports signed
// margins and whether their sign agrees with the verdict. It is NOT a
// collision judge: nothing here feeds gameplay, readiness or scoring, and no
// threshold here is an acceptance criterion.

/// The shown avatar's laser-relevant extremities, in game units above the
/// calibrated floor (world metres ÷ `metersPerGameUnit`).
struct AvatarExtremities: Equatable {
    /// Top of the head mesh (the bind head top carried by the posed Head joint).
    var headTopY: Double
    /// Hand joint centres (the mitten's own radius is not added).
    var leftHandY: Double
    var rightHandY: Double
    /// Sole of each foot (posed ankle joint minus its bind height above the sole).
    var leftSoleY: Double
    var rightSoleY: Double

    var highestY: Double { max(headTopY, leftHandY, rightHandY) }
    var lowestSoleY: Double { min(leftSoleY, rightSoleY) }
}

enum AvatarFairness {
    enum Agreement: String, Equatable {
        /// The shown margin's sign matches the verdict.
        case agrees
        /// Authoritative CLEAR, but the avatar is drawn into the beam.
        case avatarLooksHit
        /// Authoritative HIT, but the avatar is drawn clear of the beam.
        case avatarLooksClear
        /// No CLEAR/HIT (unavailable, pending, withdrawn): nothing to compare.
        case notJudged
    }

    struct Comparison: Equatable {
        let move: LaserMove
        let authoritative: Judgement?
        /// Human evidence clearance (game units, + = clear side), before the
        /// judge's margin; `nil` when that evidence is missing.
        let humanMargin: Double?
        /// The shown avatar's clearance of the drawn band (+ = clear side).
        let shownMargin: Double
        let agreement: Agreement
    }

    /// Duck: band bottom minus the highest of head and hands. Jump: the lower
    /// sole minus the band top.
    static func shownMargin(move: LaserMove, band: LaserBeamBand, extremities: AvatarExtremities) -> Double {
        switch move {
        case .duck: band.lowerY - extremities.highestY
        case .jump: extremities.lowestSoleY - band.upperY
        }
    }

    /// The same quantity for the human evidence (crown and both wrists; both soles).
    static func humanMargin(move: LaserMove, band: LaserBeamBand, geometry: BodyGeometry) -> Double? {
        switch move {
        case .duck:
            guard let crown = geometry.crownY.value, let left = geometry.leftWristY.value,
                  let right = geometry.rightWristY.value else { return nil }
            return band.lowerY - max(crown, left, right)
        case .jump:
            guard let left = geometry.leftSoleY.value, let right = geometry.rightSoleY.value else { return nil }
            return min(left, right) - band.upperY
        }
    }

    /// `displayedBand`: where the gate is actually drawn (game units), when it
    /// differs from the judged band (the D07 normalized candidate); the shown
    /// margin is measured against what is drawn, the human margin against what is judged.
    static func compare(target: LaserTarget, authoritative: Judgement?, geometry: BodyGeometry?,
                        extremities: AvatarExtremities, displayedBand: ClosedRange<Float>? = nil) -> Comparison {
        let drawn = displayedBand.flatMap { try? LaserBeamBand(lowerY: Double($0.lowerBound), upperY: Double($0.upperBound)) } ?? target.beam
        let shown = shownMargin(move: target.requiredMove, band: drawn, extremities: extremities)
        let agreement: Agreement = switch authoritative {
        case .clear?: shown > 0 ? .agrees : .avatarLooksHit
        case .hit?: shown > 0 ? .avatarLooksClear : .agrees
        default: .notJudged
        }
        return Comparison(move: target.requiredMove, authoritative: authoritative,
                          humanMargin: geometry.flatMap { humanMargin(move: target.requiredMove, band: target.beam, geometry: $0) },
                          shownMargin: shown, agreement: agreement)
    }
}

extension RobotAvatarLayer {
    /// World positions of one avatar's laser-relevant extremities, as currently
    /// posed: head top, hand centres, soles (in that order).
    func extremityPoints(of player: PlayerID) -> (headTop: SIMD3<Float>, leftHand: SIMD3<Float>, rightHand: SIMD3<Float>,
                                                  leftSole: SIMD3<Float>, rightSole: SIMD3<Float>)? {
        guard let robot = robots[player] else { return nil }
        let skeleton = robot.solver.skeleton
        guard let head = skeleton("Head"), let leftHand = skeleton("Hand_L"), let rightHand = skeleton("Hand_R"),
              let leftFoot = skeleton("Foot_L"), let rightFoot = skeleton("Foot_R") else { return nil }
        let bind = skeleton.world(skeleton.bind)
        let posed = skeleton.world(robot.model.jointTransforms)
        // The head mesh top, rigid with the Head joint: its bind offset, carried by the posed joint.
        let bindTop = SIMD3<Float>(bind.position[head].x, RobotSkeleton.modelHeight, bind.position[head].z)
        let headOffset = bind.rotation[head].inverse.act(bindTop - bind.position[head])
        let sole = SIMD3<Float>(0, robot.bindAnkleY, 0)
        func world(_ modelPoint: SIMD3<Float>) -> SIMD3<Float> { robot.model.convert(position: modelPoint, to: nil) }
        return (world(posed.position[head] + posed.rotation[head].act(headOffset)),
                world(posed.position[leftHand]), world(posed.position[rightHand]),
                world(posed.position[leftFoot] - sole), world(posed.position[rightFoot] - sole))
    }

    /// The shown extremities of one player's avatar, as currently posed.
    func extremities(of player: PlayerID, mapping: GameWorldMapping) -> AvatarExtremities? {
        guard let p = extremityPoints(of: player) else { return nil }
        func gameY(_ point: SIMD3<Float>) -> Double { Double(point.y / mapping.metersPerGameUnit) }
        return AvatarExtremities(headTopY: gameY(p.headTop), leftHandY: gameY(p.leftHand), rightHandY: gameY(p.rightHand),
                                 leftSoleY: gameY(p.leftSole), rightSoleY: gameY(p.rightSole))
    }
}
