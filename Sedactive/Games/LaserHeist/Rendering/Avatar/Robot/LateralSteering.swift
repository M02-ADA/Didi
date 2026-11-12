//
//  LateralSteering.swift
//  Sedactive
//

import Foundation

/// River-raft steering of the mascots' hoverboards across the corridor (approved movement
/// contract, owner, 12 November 2026). Presentation only (TEAM_ALIGNMENT §C): it moves what is
/// drawn, on RealityKit frame time; nothing judged reads it.
///
/// - A lean is a lateral SPEED (`RobotRetargeter.steerSpeed`): held, the board keeps moving;
///   upright, it brakes to a stop and stays where it is (no recentring, no lane snapping); the
///   other way, it brakes and reverses.
/// - Each board's centre moves between `bounds`: the corridor walls at the players' plane, or the
///   camera's view of it where that is narrower, less the board's half-width. No lane or
///   corridor-half limit: in a Solo round Lemon crosses the whole corridor.
/// - Co-op: P1 stays left of P2, and the two boards keep `minimumSeparation` between their centres
///   (their combined half-widths plus a gap), measured from where each board actually is.
///   Simultaneous inward motion is resolved deterministically: the overlap goes back to each in
///   proportion to how far it moved inward this step, so neither is pushed back past where it was.
///   A blocked board loses only its inward velocity.
struct LateralSteering: Equatable {
    /// How the boards respond (`LeanSteeringTuning`; the lean side lives in `RobotRetargeter`).
    struct Tuning: Equatable {
        /// Speed cap (m/s).
        var maximumSpeed: Float
        /// Speeding up toward a lean (m/s²), and braking when it eases or reverses (m/s²).
        var acceleration: Float
        var braking: Float
        /// First iPad build (12 November 2026): worked, but felt slow to start and to travel.
        static let initial = Tuning(maximumSpeed: 1.5, acceleration: 4, braking: 6)
        /// Responsive (owner, 12 November 2026, after the physical test): the Solo corridor in
        /// about 2 s at a strong lean; from rest a held lean is at 0.7 m/s in 0.1 s; upright brakes
        /// 0.7 m/s within about 3 cm.
        static let responsive = Tuning(maximumSpeed: 2.0, acceleration: 7, braking: 8)
    }
    static let tuning = Tuning.responsive
    static var maximumSpeed: Float { tuning.maximumSpeed }
    /// This controller's tuning (the shipped one unless a measurement compares another).
    var tuning: Tuning = Self.tuning
    /// Gap between the two boards' edges at the closest they may come (metres).
    static let partnerGap: Float = 0.04
    /// Room kept between a board's edge and the wall (metres).
    static let wallClearance: Float = 0.05

    /// What limited a board this step (DEBUG telemetry).
    enum Constraint: String, Equatable {
        case free, leftLimit = "left limit", rightLimit = "right limit", partner
    }

    struct Rider: Equatable {
        /// The lane centre's world X (the mascot's starting place).
        let laneX: Float
        /// Steering travel from the lane centre (world metres).
        var travel: Float = 0
        /// Current lateral velocity (m/s, + to screen right).
        var velocity: Float = 0
        var constraint: Constraint = .free
    }

    /// One rider's input for a step: its lean speed and the hip shift shown this frame (lane metres),
    /// which the board also carries.
    struct Input: Equatable {
        var targetSpeed: Float = 0
        var sway: Float = 0
    }

    private(set) var riders: [PlayerID: Rider]
    /// Range of a board centre's world X.
    let bounds: ClosedRange<Float>
    /// The board's half-width (world metres).
    let halfWidth: Float
    var minimumSeparation: Float { 2 * halfWidth + Self.partnerGap }
    /// The hip shift each rider's board carried at the last step.
    private(set) var sways: [PlayerID: Float] = [:]

    init(lanes: [PlayerID: Float], bounds: ClosedRange<Float>, halfWidth: Float) {
        riders = lanes.mapValues { Rider(laneX: $0) }
        self.bounds = bounds
        self.halfWidth = halfWidth
    }

    /// The bounds of a board centre from the corridor's walls at the players' plane and what the
    /// camera shows of that plane (its half-width there, for the narrowest landscape iPad).
    static func bounds(corridorWidth: Float, visibleHalfWidth: Float?, halfWidth: Float) -> ClosedRange<Float> {
        let edge = min(corridorWidth / 2, visibleHalfWidth ?? .infinity) - wallClearance
        let limit = max(0, edge - halfWidth)
        return -limit...limit
    }

    /// Half the width the camera shows at `depth` metres in front of it, for a vertical field of
    /// view and the narrowest display aspect (width ÷ height).
    static func visibleHalfWidth(depth: Float, verticalFieldOfViewDegrees: Float, aspect: Float) -> Float {
        depth * tan(verticalFieldOfViewDegrees * .pi / 360) * aspect
    }

    /// A board centre's world X.
    func boardX(_ player: PlayerID) -> Float? {
        riders[player].map { $0.laneX + $0.travel + (sways[player] ?? 0) }
    }

    /// Advances every rider by `dt` seconds of frame time.
    mutating func step(dt: Float, inputs: [PlayerID: Input]) {
        let dt = min(dt, 0.1)
        guard dt > 0 else { return } // the same instant again (one call per player): nothing moves
        var start: [PlayerID: Float] = [:]
        var x: [PlayerID: Float] = [:]
        for player in PlayerID.allCases {
            guard var r = riders[player] else { continue }
            let input = inputs[player] ?? Input()
            let cap = tuning.maximumSpeed
            let target = input.targetSpeed.isFinite ? min(cap, max(-cap, input.targetSpeed)) : 0
            let speeding = target * r.velocity >= 0 && abs(target) > abs(r.velocity)
            let rate = (speeding ? tuning.acceleration : tuning.braking) * dt
            r.velocity += min(rate, max(-rate, target - r.velocity))
            let sway = input.sway.isFinite ? input.sway : 0
            start[player] = r.laneX + r.travel + (sways[player] ?? sway)
            sways[player] = sway
            var p = r.laneX + r.travel + sway + r.velocity * dt
            r.constraint = .free
            if p <= bounds.lowerBound {
                if r.velocity < 0 || target < 0 { r.constraint = .leftLimit }
                p = bounds.lowerBound; r.velocity = max(0, r.velocity)
            } else if p >= bounds.upperBound {
                if r.velocity > 0 || target > 0 { r.constraint = .rightLimit }
                p = bounds.upperBound; r.velocity = min(0, r.velocity)
            }
            x[player] = p
            riders[player] = r
        }
        if var a = x[.player1], var b = x[.player2], b - a < minimumSeparation {
            let a0 = start[.player1] ?? a, b0 = start[.player2] ?? b
            let inA = max(0, a - a0), inB = max(0, b0 - b)
            // The room that was left between them, shared in proportion to each one's inward move;
            // a board that moved outward keeps its move. In contact (no room) both stay exactly put.
            let baseA = inA > 0 ? a0 : a, baseB = inB > 0 ? b0 : b
            // In contact the room is 0 up to float rounding: never treat that as overlap.
            let room = max(0, (baseB - baseA) - minimumSeparation)
            if inA + inB > 0, (baseB - baseA) - minimumSeparation >= -1e-4 {
                let shareA = inA / (inA + inB)
                if inA > 0 { a = a0 + room * shareA }
                if inB > 0 { b = b0 - room * (1 - shareA) }
            } else {
                // Already too close without steering (the hips' own shift): part evenly.
                let need = minimumSeparation - (b - a)
                a -= need / 2
                b += need / 2
            }
            // A board at a wall cannot give way: its partner takes the rest.
            if a < bounds.lowerBound { b += bounds.lowerBound - a; a = bounds.lowerBound }
            if b > bounds.upperBound { a -= b - bounds.upperBound; b = bounds.upperBound }
            x[.player1] = a
            x[.player2] = b
            if var r = riders[.player1] { r.velocity = min(0, r.velocity); r.constraint = .partner; riders[.player1] = r }
            if var r = riders[.player2] { r.velocity = max(0, r.velocity); r.constraint = .partner; riders[.player2] = r }
        }
        for (player, p) in x {
            guard var r = riders[player] else { continue }
            r.travel = p - r.laneX - (sways[player] ?? 0)
            riders[player] = r
        }
    }
}
