//
//  RobotFootPlanner.swift
//  Sedactive
//

import Foundation

/// Where each robot foot is, in HOVERBOARD space: the player entity's local
/// frame (metres, +X = screen right, Y up from the deck). The board stays put
/// in the gameplay camera while the corridor travels, so a planted foot is a
/// fixed X here and never slides when the pelvis (the robot container) moves.
///
/// Per foot: PLANTED (fixed X), STEPPING (a short arc to a new X) or AIRBORNE
/// (both feet hang under the body during a jump and re-plant where they land).
/// A planted foot is released only by evidence:
/// - tracked ankle: the player's ankle (relative to their own learned stance)
///   moved past `stepThreshold` for `confirmTime`, or visibly lifted;
/// - balance: no usable ankle for that foot, and the pelvis has drifted
///   `comfort` beyond the middle of the feet (a compact procedural step);
/// - reach: the foot would otherwise be further from the pelvis than the leg
///   should stretch (`maximumSpread`).
/// A lean (hips move, ankles stay) keeps both feet planted: the legs angle.
/// Presentation only: never a hit shape, never judged.
nonisolated struct RobotFootPlanner: Sendable {
    typealias Side = RobotPoseTargets.Side

    enum Contact: String, Sendable { case planted, stepping, airborne }
    enum Reason: String, Sendable {
        case none = "—", trackedAnkle = "tracked ankle", trackedLift = "foot lifted", balance = "balance (no ankle)"
        case reach = "reach limit", landing = "landed"
    }

    struct Foot: Sendable, Equatable {
        var x: Float
        var contact: Contact = .planted
        var reason: Reason = .none
        var from: Float = 0, to: Float = 0, height: Float = 0
        var start = 0.0, duration = 0.0
        var pending: Double?
    }

    struct Input: Sendable {
        /// Pelvis (container) X from tracking, shown value.
        var pelvisX: Float
        /// Root height above the deck (jump), shown value.
        var rootLift: Float
        /// Each tracked ankle's offset from the player's own standing stance, board metres; `nil` = no evidence this frame.
        var footDelta: [Side: Float] = [:]
        /// Each foot's tracked lift above the floor, board metres.
        var trackedLift: [Side: Float] = [:]
        /// Whether the player is tracked now (no new evidence steps while lost).
        var available = true
        var time: Double
    }

    struct Output: Sendable, Equatable {
        var footX: [Side: Float] = [:]
        /// Step arc height above the deck, board metres.
        var footHeight: [Side: Float] = [:]
        /// Weight transfer toward the support foot while the other steps (board metres, added to the pelvis).
        var pelvisShift: Float = 0
        /// Small pelvis lowering during a step (board metres).
        var pelvisDip: Float = 0
    }

    // Tuning (board metres and seconds). A robot is 1.6 m tall.
    static let stepThreshold: Float = 0.035
    static let confirmTime = 0.033
    static let liftThreshold: Float = 0.015
    static let comfort: Float = 0.09
    static let comfortTime = 0.1
    static let maximumSpread: Float = 0.22
    static let minimumStep: Float = 0.015
    static let takeoffLift: Float = 0.03
    static let landingLift: Float = 0.012
    static let weightShift: Float = 0.02
    static let stepDip: Float = 0.012
    static let airborneFollow = 0.06

    /// Each foot's X relative to the pelvis at rest (bind ankle X × robot scale).
    let rest: [Side: Float]
    private(set) var feet: [Side: Foot] = [:]
    private(set) var airborne = false
    private var lastTime: Double?
    /// Shown step arc per foot: lightly smoothed so a step re-aimed mid-air never snaps vertically.
    private var arc: [Side: Float] = [:]
    private var balancePending: Double?

    init(rest: [Side: Float]) { self.rest = rest }

    static func duration(_ distance: Float) -> Double { Double(min(0.25, max(0.12, 0.12 + 0.4 * distance))) }
    static func height(_ distance: Float) -> Float { min(0.06, max(0.025, 0.025 + 0.2 * distance)) }
    /// Front-loaded but not abrupt: half ease-in-out, half ease-out. The foot leaves at a
    /// moderate speed while it lifts, covers most of the distance early and settles softly.
    static func ease(_ u: Double) -> Float {
        let u = Float(min(1, max(0, u)))
        let inOut = u * u * (3 - 2 * u), out = 1 - (1 - u) * (1 - u) * (1 - u)
        return (inOut + out) / 2
    }

    func home(_ side: Side, _ pelvisX: Float) -> Float { pelvisX + (rest[side] ?? 0) }

    mutating func update(_ input: Input) -> Output {
        let now = input.time
        let dt = lastTime.map { max(0, now - $0) } ?? 0
        lastTime = now
        for side in Side.allCases where feet[side] == nil { feet[side] = Foot(x: home(side, input.pelvisX)) }

        // JUMP: release both feet at takeoff; they hang under the body and plant where they land.
        if airborne, input.rootLift < Self.landingLift {
            airborne = false
            for side in Side.allCases { feet[side]!.contact = .planted; feet[side]!.reason = .landing; feet[side]!.pending = nil }
        } else if !airborne, input.rootLift > Self.takeoffLift {
            airborne = true
        }
        if airborne {
            let k = Float(1 - exp(-dt / Self.airborneFollow))
            for side in Side.allCases {
                let target = clampToReach(side, home(side, input.pelvisX) + (input.available ? input.footDelta[side] ?? 0 : 0), input.pelvisX)
                feet[side]!.x += (target - feet[side]!.x) * k
                feet[side]!.contact = .airborne
            }
            return output(now, dt: dt)
        }

        // A step in flight follows a moving tracked target (re-based, never a jump in X).
        for side in Side.allCases where feet[side]!.contact == .stepping {
            var f = feet[side]!
            // Tracked: follow the ankle. Balance or reach steps: follow the stance under the moving pelvis.
            let delta: Float? = input.available ? input.footDelta[side] : nil
            let follows = delta != nil || f.reason == .balance || f.reason == .reach
            if follows {
                let target = clampToReach(side, home(side, input.pelvisX) + (delta ?? 0), input.pelvisX)
                if abs(target - f.to) > 0.03 {
                    let u = (now - f.start) / f.duration
                    f.from = position(f, now)
                    f.to = target
                    f.start = now
                    f.duration = max(0.1, f.duration * (1 - min(1, u)))
                    f.height = max(f.height, Self.height(abs(f.to - f.from)))
                }
            }
            if now - f.start >= f.duration { f.x = f.to; f.contact = .planted; f.pending = nil } else { f.x = position(f, now) }
            feet[side] = f
        }

        // New steps: one foot at a time, the support foot stays planted.
        if !Side.allCases.contains(where: { feet[$0]!.contact == .stepping }) {
            var best: (side: Side, to: Float, reason: Reason)?
            func consider(_ side: Side, _ to: Float, _ reason: Reason) {
                let to = clampToReach(side, to, input.pelvisX)
                guard abs(to - feet[side]!.x) >= Self.minimumStep else { return }
                if best == nil || abs(to - feet[side]!.x) > abs(best!.to - feet[best!.side]!.x) { best = (side, to, reason) }
            }
            for side in Side.allCases {
                let f = feet[side]!
                let homeX = home(side, input.pelvisX)
                if abs(f.x - homeX) > Self.maximumSpread { consider(side, homeX + (input.available ? input.footDelta[side] ?? 0 : 0), .reach); continue }
                guard input.available, let delta = input.footDelta[side] else { feet[side]!.pending = nil; continue }
                let target = homeX + delta
                let error = target - f.x
                let lifted = (input.trackedLift[side] ?? 0) > Self.liftThreshold
                if abs(error) > Self.stepThreshold || (lifted && abs(error) > 0.02) {
                    let since = f.pending ?? now
                    feet[side]!.pending = since
                    if now - since >= Self.confirmTime { consider(side, target, lifted ? .trackedLift : .trackedAnkle) }
                } else {
                    feet[side]!.pending = nil
                }
            }
            // Balance fallback, only for feet without ankle evidence: a foot this far from
            // where it stands under the pelvis steps back under it, the foot on the side the
            // body moved toward first (the other follows on the next step).
            let blind = Side.allCases.filter { input.footDelta[$0] == nil }
            if best == nil, input.available, !blind.isEmpty {
                let errors = blind.map { ($0, home($0, input.pelvisX) - feet[$0]!.x) }
                if let worst = errors.max(by: { abs($0.1) < abs($1.1) }), abs(worst.1) > Self.comfort {
                    let since = balancePending ?? now
                    balancePending = since
                    if now - since >= Self.comfortTime {
                        let lead: Side = worst.1 > 0 ? .right : .left
                        let ranked = errors.filter { abs($0.1) > Self.comfort }
                            .sorted { abs($0.1) + ($0.0 == lead ? 0.01 : 0) > abs($1.1) + ($1.0 == lead ? 0.01 : 0) }
                        if let side = ranked.first?.0 { consider(side, home(side, input.pelvisX), .balance) }
                    }
                } else { balancePending = nil }
            } else if best != nil || blind.isEmpty { balancePending = nil }
            if let best {
                var f = feet[best.side]!
                let distance = abs(best.to - f.x)
                f.contact = .stepping
                f.reason = best.reason
                f.from = f.x
                f.to = best.to
                f.start = now
                f.duration = Self.duration(distance)
                f.height = Self.height(distance)
                f.pending = nil
                feet[best.side] = f
                balancePending = nil
            }
        }
        return output(now, dt: dt)
    }

    /// Keeps a requested foot within comfortable reach of the pelvis.
    private func clampToReach(_ side: Side, _ x: Float, _ pelvisX: Float) -> Float {
        let homeX = home(side, pelvisX)
        return min(homeX + Self.maximumSpread * 0.9, max(homeX - Self.maximumSpread * 0.9, x))
    }

    private func position(_ f: Foot, _ now: Double) -> Float {
        f.from + (f.to - f.from) * Self.ease((now - f.start) / max(f.duration, 1e-3))
    }

    private mutating func output(_ now: Double, dt: Double) -> Output {
        var out = Output()
        let k = dt > 0 ? Float(1 - exp(-dt / 0.025)) : 1
        for side in Side.allCases {
            let f = feet[side]!
            out.footX[side] = f.x
            let u = min(1, max(0, (now - f.start) / max(f.duration, 1e-3)))
            let raw = f.contact == .stepping ? f.height * Float(sin(.pi * u)) : 0
            arc[side, default: 0] += (raw - arc[side, default: 0]) * k
            if arc[side]! < 1e-4 && raw == 0 { arc[side] = 0 }
            out.footHeight[side] = arc[side]!
            guard f.contact == .stepping else { continue }
            let arc = Float(sin(.pi * u))
            // Weight onto the support foot first, then settle: toward the other foot's side.
            let support = feet[side == .left ? .right : .left]!.x
            out.pelvisShift = (support > f.x ? 1 : -1) * Self.weightShift * arc
            out.pelvisDip = Self.stepDip * arc
        }
        return out
    }
}
