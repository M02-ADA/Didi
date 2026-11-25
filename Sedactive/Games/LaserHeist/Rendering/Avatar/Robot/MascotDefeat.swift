//
//  MascotDefeat.swift
//  Sedactive
//

import Foundation
import simd

/// The cartoon team defeat after the round's fatal laser HIT (Kevin, 23 November 2026; DEBUG
/// preview for review, not yet in the Game Over flow). Health is SHARED, so the team falls
/// together: one timeline per mascot whose curves drive its body, its hoverboard and the VFX.
///
///     0       0.25        0.36–0.46        0.56          0.70           ~1.15–1.2        2.0–2.25
///     HIT     │ OVERLOAD   │ SPREAD          │ WIND-UP      │ BOOM           │ LANDING         │ results
///     the struck  its board   an energy arc   both boards   both boards pop  both mascots sit
///     mascot's    wobbles,    jumps to the    shudder,      AT ONCE and      on the floor:
///     existing    flickers    teammate's      swell,        vanish inside    squash, hop,
///     zap                     board           energy        the burst;       dizzy, soot,
///                                             gathers       mascots thrown   smoke wisps
///
/// - Struck (the player whose HIT emptied the shared health): the existing HIT plays as it is
///   (never replayed), then its board overloads first: a growing wobble, the HIT's own flicker
///   and discharge looping, arms windmilling, trunk and head counter-balancing.
/// - Teammate: startles at the HIT and turns to look; the failure spreads to its board through an
///   energy arc (0.36–0.46 s), and from then both boards flicker IN SYNC (one shared light
///   sequence on absolute time) and it rides the wobble too, a little less violently.
/// - Wind-up (0.56–0.70 s): both boards shudder, swell and sink, energy gathers into them, both
///   mascots crouch.
/// - Boom (0.70 s, one beat for the whole team): every board explodes at the same instant and is
///   gone inside the burst within 60 ms (`MascotDefeatFX`). Both mascots are thrown up (the struck
///   one a little higher and more tilted) and land seated ON THE FLOOR (~1.15–1.2 s): squash, hop,
///   settle; then slumped, dizzy, lightly sooted, with thin smoke.
/// - Results may show from `resultsTime` (2.25 s).
///
/// Simultaneous fatal HITs: both mascots are struck (both react, no spread). No single struck
/// player (ambiguous): every mascot is a teammate without a source, so all boards fail together
/// from the overload; nobody is shown as hit by a beam they did not receive.
///
/// Presentation only: every value is a pose target, a root offset or a VFX level on RealityKit
/// render time. Nothing here is read by gameplay, verdicts, `GameClock`, scoring or health.
/// Tuning values are temporary (Kevin, 23 November 2026), from Simulator frames.
nonisolated struct MascotDefeat: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// Received the fatal HIT: reacts first, its board fails first.
        case struck
        /// Shares the defeat: its board fails with the struck one's.
        case teammate
    }

    static let overloadStart = 0.25
    /// The energy arc leaves the struck board, and reaches the teammate's.
    static let spreadStart = 0.36
    static let spreadArrive = 0.46
    static let windUp = 0.56
    /// The one explosion beat for every board.
    static let popTime = 0.70
    /// Every board is gone by now (it vanishes inside the burst).
    static let vanishTime = popTime + 0.06
    /// When Results may appear, and the fade into it before that.
    static let resultsAt = 2.25
    static let resultsFade = 0.25
    /// The corridor floor below the deck when no board reports it (metres).
    static let defaultFloorDrop: Float = 0.45
    /// Soot at its strongest: the authored body colour times this (Lemon stays yellow).
    static let sootTint: SIMD3<Float> = [0.86, 0.82, 0.80]

    let role: Role
    /// The mascot's outward screen side: −1 left (P1), +1 right (P2).
    let side: Float
    let reduceMotion: Bool
    /// Teammate only: the failure arrives from a struck teammate (an arc). False: no single
    /// struck player, so every board fails together from the overload.
    let spreads: Bool
    /// How far below the deck the corridor floor is (metres, > 0): where the mascot lands.
    let floorDrop: Float

    init(role: Role, side: Float, reduceMotion: Bool, spreads: Bool = true, floorDrop: Float = defaultFloorDrop) {
        self.role = role
        self.side = side < 0 ? -1 : 1
        self.reduceMotion = reduceMotion
        self.spreads = spreads
        self.floorDrop = max(0.05, floorDrop)
    }

    /// When this mascot's board starts to overload.
    var onset: Double { role == .struck || !spreads ? Self.overloadStart : Self.spreadArrive }
    /// How violently it overloads and flies (the struck one most).
    var vigor: Float { role == .struck ? 1 : 0.8 }
    var apexHeight: Float { role == .struck ? 0.3 : 0.22 }
    var apexTime: Double { Self.popTime + (role == .struck ? 0.19 : 0.16) }
    var gravity: Float { apexHeight / Float((apexTime - Self.popTime) * (apexTime - Self.popTime)) }
    /// When the mascot lands on the floor.
    var landTime: Double { apexTime + Double(((apexHeight + floorDrop) / gravity).squareRoot()) }
    /// When the landing's squash and hops have settled into the defeated pose.
    var settledTime: Double { landTime + 0.43 }
    /// When Results may appear (seconds after the fatal HIT).
    var resultsTime: Double { Self.resultsAt }

    /// One arm, in model space (+X the mascot's right, +Y up, −Z forward, away from the camera).
    struct Arm: Equatable, Sendable {
        var upper: SIMD3<Float>
        var fore: SIMD3<Float>
    }

    /// The defeat at one moment.
    struct Frame: Equatable, Sendable {
        // Body: the scripted pose and how much of it replaces the live one.
        /// Trunk, head and arms (0 live … 1 scripted).
        var upperWeight: Float = 0
        /// Pelvis and legs (0 live … 1 scripted).
        var lowerWeight: Float = 0
        /// The root's X held where the defeat began (0 live steering … 1 held).
        var anchor: Float = 0
        /// Added to the root (lane metres), on top of the board's lift the mascot rides.
        var rootOffset: SIMD3<Float> = .zero
        /// Whole-body tilt about the feet (radians): roll counter-clockwise on screen, pitch top
        /// toward the camera. Height over width (1: none).
        var roll: Float = 0
        var pitch: Float = 0
        var squash: Float = 1
        /// Scripted pose targets (radians).
        var lean: Float = 0
        var headRoll: Float = 0
        var headYaw: Float = 0
        var shoulderShrug: Float = 0
        /// Added to the live pose before the scripted blend (a teammate's look and startle).
        var addLean: Float = 0
        var addHeadRoll: Float = 0
        var addHeadYaw: Float = 0
        var addShrug: Float = 0
        var arms: [RobotPoseTargets.Side: Arm] = [:]
        var armWeight: Float = 0
        /// Knees bent for balance and the wind-up (0…1 of a crouch), seated (0 standing … 1
        /// seated, legs forward), feet tucked up in the air (lane metres).
        var crouch: Float = 0
        var seat: Float = 0
        var footTuck: Float = 0
        /// How far the body's opacity is lifted toward solid (0…1).
        var solidity: Float = 0
        /// Soot on the body (0…1 of `sootTint`).
        var soot: Float = 0

        // Board.
        /// Whether the defeat drives this mascot's board now.
        var drivesBoard = false
        /// The moment of the board's own HIT light to show (`HoverboardReaction.hit`).
        var boardTau: Double = 0
        var boardLightsReduced = false
        /// The board's cosmetic motion (radians, metres; lift + up). Replaces the HIT's.
        var boardRoll: Float = 0
        var boardPitch: Float = 0
        var boardYaw: Float = 0
        var boardLift: Float = 0
        /// The board's size (1 as authored; it swells before the boom, 0 once gone) and opacity
        /// (Reduce Motion fades it instead).
        var boardScale: Float = 1
        var boardOpacity: Float = 1

        // VFX.
        /// Seconds since the energy arc left the struck board (struck only, while it travels).
        var spreadAge: Double?
        /// Energy gathering into the board before the boom (0…1).
        var gather: Float = 0
        /// Seconds since the boom (nil before it).
        var popAge: Double?
        /// The mascot's own soft shadow on the floor once its board is gone (0…1).
        var floorShadow: Float = 0
        /// Smoke wisps from the head (0…1).
        var smoke: Float = 0

        /// The board is gone.
        var boardGone: Bool { boardScale <= 0.001 || boardOpacity <= 0.001 }
    }

    // MARK: - Curves

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    static func smoothF(_ e0: Double, _ e1: Double, _ x: Double) -> Float { Float(smooth(e0, e1, x)) }

    /// Rises over `a…b`, falls over `b…c` (0 outside).
    static func bump(_ a: Double, _ b: Double, _ c: Double, _ x: Double) -> Float {
        guard x > a, x < c else { return 0 }
        return x < b ? smoothF(a, b, x) : 1 - smoothF(b, c, x)
    }

    /// The overload wobble (radians, metres) on absolute time, growing through the overload; the
    /// wind-up adds a hard shudder while the hover sinks.
    static func wobble(_ t: Double) -> (roll: Float, pitch: Float, yaw: Float, lift: Float) {
        let u = max(0, t - overloadStart)
        let amplitude = 0.03 + 0.11 * smooth(overloadStart, 0.62, t)
        let roll = amplitude * (sin(2 * .pi * 4.2 * u) + 0.35 * sin(2 * .pi * 7.3 * u + 0.8)) / 1.35
        let pitch = 0.5 * amplitude * sin(2 * .pi * 3.1 * u + 1.1)
        let yaw = 0.35 * amplitude * sin(2 * .pi * 2.4 * u + 0.4)
        let shudder = smooth(windUp, windUp + 0.07, t)
        let lift = -0.012 + 0.01 * sin(2 * .pi * 5.5 * u) * amplitude / 0.14 - 0.03 * smooth(windUp, popTime - 0.01, t)
        return (Float(roll + 0.05 * shudder * sin(2 * .pi * 16 * u)), Float(pitch + 0.02 * shudder * sin(2 * .pi * 13 * u)),
                Float(yaw), Float(lift))
    }

    /// The board's light: the HIT itself; then its unstable flicker and discharge looping on
    /// ABSOLUTE time (so every failing board flickers in sync); a teammate's board arrives with
    /// one coral surge; the wind-up loops the discharge's coral jolt.
    func boardTau(_ t: Double) -> Double {
        if role == .struck, t < Self.overloadStart { return t }
        if role == .teammate, t < onset + 0.05 { return 0.25 }
        if t < Self.windUp { return 0.07 + ((t - Self.overloadStart) / 0.13).truncatingRemainder(dividingBy: 1) * 0.25 }
        return 0.25 + ((t - Self.windUp) / 0.07).truncatingRemainder(dividingBy: 1) * 0.07
    }

    /// The board's size: a shiver and a swell through the wind-up, a last bulge at the boom, then
    /// gone within `vanishTime` (inside the burst).
    static func boardScale(_ t: Double) -> Float {
        if t < popTime {
            let swell = smooth(windUp + 0.04, popTime, t)
            return Float(1 + 0.08 * swell + 0.015 * sin(2 * .pi * 22 * t) * smooth(windUp, windUp + 0.05, t))
        }
        return Float((1.08 + 0.12 * smooth(popTime, popTime + 0.02, t)) * (1 - smooth(popTime + 0.015, vanishTime, t)))
    }

    func frame(at time: Double) -> Frame {
        guard time >= 0 else { return Frame() }
        return reduceMotion ? calm(time) : animated(time)
    }

    // MARK: - Poses

    private func arm(_ side: RobotPoseTargets.Side, _ upper: SIMD3<Float>, _ fore: SIMD3<Float>) -> Arm {
        let x: Float = side == .right ? 1 : -1
        return Arm(upper: simd_normalize(upper * [x, 1, 1]), fore: simd_normalize(fore * [x, 1, 1]))
    }

    private func blend(_ a: Arm, _ b: Arm, _ k: Float) -> Arm {
        func mix(_ u: SIMD3<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
            let w = u * (1 - k) + v * k
            return simd_length(w) > 1e-4 ? simd_normalize(w) : v
        }
        return Arm(upper: mix(a.upper, b.upper), fore: mix(a.fore, b.fore))
    }

    /// Hands down beside the hips, resting on the floor: the defeated pose.
    private func slumped(_ side: RobotPoseTargets.Side) -> Arm { arm(side, [0.45, -0.88, 0.12], [0.2, -0.95, 0.22]) }

    /// A teammate's reaction to the HIT before its own board fails: a startle, then a look at
    /// the struck mascot (added to its live pose). None without a struck teammate.
    private func noticing(_ t: Double, into f: inout Frame) {
        guard role == .teammate, spreads else { return }
        let s = side
        let look = Self.smoothF(0.28, 0.5, t)
        f.addHeadYaw = -s * 0.55 * look
        f.addHeadRoll = s * 0.14 * look
        f.addLean = -s * 0.12 * Self.smoothF(0.3, 0.52, t)
        guard !reduceMotion else { return }
        let startle = Float(t < 0.5 ? exp(-t / 0.12) * sin(2 * .pi * 3 * t) : 0)
        f.roll = -s * 0.07 * startle
        f.rootOffset.y = 0.03 * Self.bump(0.02, 0.1, 0.24, t)
        f.addShrug = s * 0.18 * Self.bump(0.02, 0.08, 0.4, t)
        f.squash = 1 + 0.04 * Self.bump(0.02, 0.08, 0.2, t)
    }

    /// This mascot's board motion (radians, metres) before the boom.
    private func boardMotion(_ t: Double) -> (roll: Float, pitch: Float, yaw: Float, lift: Float) {
        let s = side
        if role == .struck {
            // The HIT's own motion, handing over to the overload wobble.
            let hit = HoverboardReaction.hitMotion(min(t, 0.3))
            let w = Self.wobble(t)
            let k = Self.smoothF(0.22, 0.32, t)
            return (hit.roll + (w.roll * s - hit.roll) * k, hit.pitch + (w.pitch - hit.pitch) * k,
                    hit.yaw + (w.yaw * s - hit.yaw) * k, hit.lift + (w.lift - hit.lift) * k)
        }
        // A teammate's board joins a little out of step (its own wobble), a little gentler.
        let w = Self.wobble(t + 0.11), k = Self.smoothF(onset, onset + 0.12, t) * vigor
        return (w.roll * s * k, w.pitch * k, w.yaw * s * k, w.lift * Self.smoothF(onset, onset + 0.12, t))
    }

    private func animated(_ t: Double) -> Frame {
        var f = Frame()
        let s = side
        noticing(t, into: &f)
        let struck = role == .struck
        f.upperWeight = struck ? Self.smoothF(0.22, 0.40, t) : Self.smoothF(onset - 0.02, onset + 0.14, t)
        f.lowerWeight = struck ? Self.smoothF(0.48, 0.62, t) : Self.smoothF(onset + 0.04, onset + 0.16, t)
        f.anchor = struck ? Self.smoothF(0, 0.25, t) : Self.smoothF(onset - 0.12, onset + 0.08, t)
        f.solidity = 0.6 * Self.smoothF(onset, onset + 0.25, t)
        // The look fades as the scripted pose takes over.
        f.addHeadYaw *= 1 - f.upperWeight; f.addHeadRoll *= 1 - f.upperWeight; f.addLean *= 1 - f.upperWeight

        // The board.
        f.drivesBoard = t >= onset || struck
        f.boardTau = boardTau(t)
        let board = boardMotion(min(t, Self.popTime))
        f.boardRoll = board.roll; f.boardPitch = board.pitch; f.boardYaw = board.yaw; f.boardLift = board.lift
        f.boardScale = Self.boardScale(t)
        if struck, spreads, t >= Self.spreadStart, t < Self.spreadStart + 0.16 { f.spreadAge = t - Self.spreadStart }
        f.gather = Self.smoothF(Self.windUp, Self.popTime, t)

        // Balance on the wobbling deck: the body tilts with it, trunk and head counter it.
        // (The struck board's HIT motion is not part of it: only the overload wobble, mirrored per side.)
        let lagged = { (lag: Double) -> Float in
            let u = min(t - lag, Self.popTime)
            return struck ? Self.wobble(u).roll * s * Self.smoothF(0.22, 0.32, u) : self.boardMotion(u).roll
        }
        let windUp = Self.smoothF(Self.windUp, Self.popTime - 0.04, t)
        let overload = Self.smoothF(onset, onset + 0.07, t)
        f.roll += 0.55 * lagged(0.04) * f.upperWeight
        f.lean = max(-0.3, min(0.3, -1.4 * lagged(0.06)))
        f.headRoll = 0.8 * lagged(0.1)
        f.shoulderShrug = s * 0.2 * Self.bump(onset, onset + 0.07, onset + 0.2, t)
        f.crouch = 0.3 * overload + 0.7 * windUp
        f.squash *= 1 - 0.09 * windUp
        // The arms windmill out to the sides, then brace low for the wind-up.
        let phase = 2 * Float.pi * 2.6 * Float(max(0, t - onset)) + (struck ? 0 : 1.7)
        let reach: Float = struck ? 0.35 : 0.25
        func windmill(_ side: RobotPoseTargets.Side) -> Arm {
            let offset: Float = side == .left ? 0 : .pi
            return arm(side, [0.95, reach * sin(phase + offset), 0.05], [0.75, 0.55 * sin(phase + offset + 0.9), 0])
        }
        func brace(_ side: RobotPoseTargets.Side) -> Arm { arm(side, [0.55, -0.75, 0.2], [0.45, -0.6, 0.35]) }
        func flung(_ side: RobotPoseTargets.Side) -> Arm {
            struck ? arm(side, [0.55, 0.82, 0.12], [0.3, 0.95, 0]) : arm(side, [0.75, 0.6, 0.1], [0.5, 0.85, 0])
        }
        f.armWeight = struck ? Self.smoothF(0.22, 0.36, t) : Self.smoothF(onset, onset + 0.12, t)

        guard t >= Self.popTime else {
            for side in RobotPoseTargets.Side.allCases { f.arms[side] = blend(windmill(side), brace(side), windUp) }
            return f
        }

        // The boom: thrown up, a ballistic arc, landing seated on the floor. The board stays where
        // it was while it vanishes inside the burst.
        let p = t - Self.popTime
        let land = landTime
        let balance = (roll: f.roll, lean: f.lean, head: f.headRoll)
        let release = 1 - Self.smoothF(Self.popTime, Self.popTime + 0.08, t)
        let liftAtPop = board.lift
        f.popAge = p
        f.soot = Self.smoothF(Self.popTime, Self.popTime + 0.1, t)
        f.floorShadow = Self.smoothF(Self.popTime, Self.vanishTime + 0.04, t)
        f.crouch = 1 - Self.smoothF(Self.popTime, Self.popTime + 0.05, t)
        f.footTuck = 0.1 * Self.bump(Self.popTime + 0.02, Self.popTime + 0.15, land - 0.05, t)
        f.seat = Self.smoothF(land - 0.16, land, t)
        let air = min(1, max(0, (t - Self.popTime) / (land - Self.popTime)))
        var height: Float
        if t < land {
            let since = Float(t - apexTime)
            height = apexHeight - gravity * since * since + liftAtPop * (1 - Self.smoothF(Self.popTime, Self.popTime + 0.05, t))
        } else {
            // A hop on the seat, then (the struck one) a smaller one.
            height = -floorDrop + (struck ? 0.07 : 0.045) * Self.bump(land + 0.04, land + 0.11, land + 0.2, t)
                + (struck ? 0.015 : 0) * Self.bump(land + 0.22, land + 0.26, land + 0.31, t)
        }
        f.rootOffset = [s * (struck ? 0.1 : 0.06) * Self.smoothF(Self.popTime, land, t), height - f.boardLift, 0]
        let flight = Float(sin(Double.pi * air))
        f.roll = balance.roll * release - s * (struck ? 0.32 : 0.2) * flight - s * (struck ? 0.1 : 0.06) * Self.smoothF(land, land + 0.25, t)
        f.pitch = (struck ? 0.18 : 0.12) * flight + 0.06 * Self.smoothF(land, land + 0.3, t)
        // Out of the wind-up's crouch into a stretch at launch, a squash on landing that springs back.
        var squash = 1 - 0.09 * (1 - Self.smoothF(Self.popTime, Self.popTime + 0.03, t))
            + 0.14 * Self.bump(Self.popTime, Self.popTime + 0.04, Self.popTime + 0.15, t)
            + 0.05 * Self.bump(land - 0.12, land - 0.03, land, t)
        if t >= land {
            // The impact squash lands within ~25 ms of contact (never a one-frame snap).
            let v = t - land
            squash -= Float((struck ? 0.24 : 0.2) * exp(-v / 0.07) * cos(2 * .pi * 3.2 * v) * Self.smooth(0, 0.025, v))
        }
        f.squash = squash
        f.headRoll = balance.head * release - s * (struck ? 0.35 : 0.25) * Self.bump(Self.popTime, Self.popTime + 0.06, Self.popTime + 0.3, t)
        f.lean = balance.lean * release - s * 0.06 * Self.smoothF(land, land + 0.3, t)
        f.shoulderShrug = 0
        // Arms flung up at the boom, flailing down through the fall, flopped on the floor.
        let up = Self.smoothF(Self.popTime, Self.popTime + 0.1, t)
        let down = Self.smoothF(apexTime, land, t)
        for side in RobotPoseTargets.Side.allCases {
            let flop = Float(0.25 * exp(-max(0, t - land) / 0.1) * sin(2 * .pi * 4 * max(0, t - land)))
            var rest = slumped(side)
            rest.fore = simd_normalize(rest.fore + [0, flop, 0])
            f.arms[side] = blend(blend(brace(side), flung(side), up), rest, down)
        }
        // Dazed: the head circles (each mascot at its own pace), the trunk sways a little.
        let dizzy = Self.smoothF(land + 0.15, land + 0.45, t)
        let turn = 2 * Float.pi * (struck ? 1.25 : 1.05) * Float(max(0, t - land)) + (struck ? 0 : 1.3)
        f.headRoll += 0.16 * dizzy * sin(turn)
        f.headYaw = 0.22 * dizzy * cos(turn)
        f.lean += 0.03 * dizzy * sin(turn * 0.5)
        f.squash += 0.012 * dizzy * sin(2 * .pi * 0.8 * Float(max(0, t - land)))
        f.smoke = Self.smoothF(land, land + 0.4, t)
        return f
    }

    /// Reduce Motion: no wobble, flicker, arc, launch, bounce or dizzy circling. The lights dim,
    /// every board fades away at the same moment, the mascots sink onto the floor and sit, a
    /// soft puff, the same soot and pose.
    private func calm(_ t: Double) -> Frame {
        var f = Frame()
        let s = side
        noticing(t, into: &f)
        // The board is (nearly) gone before the mascot sinks through where it was.
        let sink = Self.smoothF(Self.popTime + 0.08, Self.popTime + 0.65, t)
        f.upperWeight = Self.smoothF(onset - 0.05, onset + 0.25, t)
        f.lowerWeight = Self.smoothF(Self.popTime - 0.1, Self.popTime + 0.2, t)
        f.addHeadYaw *= 1 - f.upperWeight; f.addHeadRoll *= 1 - f.upperWeight; f.addLean *= 1 - f.upperWeight
        f.anchor = Self.smoothF(0, 0.25, t)
        f.solidity = 0.6 * Self.smoothF(onset, onset + 0.25, t)
        f.drivesBoard = t >= onset || role == .struck
        f.boardLightsReduced = true
        f.boardTau = min(max(0, t - onset + 0.05), 0.3)
        f.boardOpacity = 1 - Self.smoothF(Self.popTime - 0.05, Self.popTime + 0.12, t)
        f.popAge = t >= Self.popTime ? t - Self.popTime : nil
        f.floorShadow = 1 - f.boardOpacity
        f.rootOffset.y = -floorDrop * sink
        f.seat = Self.smoothF(Self.popTime + 0.15, Self.popTime + 0.65, t)
        f.roll = -s * 0.08 * Self.smoothF(1.1, 1.6, t)
        f.pitch = 0.06 * Self.smoothF(1.1, 1.6, t)
        f.lean = -s * 0.06 * Self.smoothF(1.1, 1.6, t)
        f.headRoll = -s * 0.12 * Self.smoothF(1.3, 1.7, t)
        f.armWeight = Self.smoothF(Self.popTime - 0.1, Self.popTime + 0.5, t)
        for side in RobotPoseTargets.Side.allCases { f.arms[side] = slumped(side) }
        f.soot = Self.smoothF(Self.popTime, Self.popTime + 0.35, t)
        f.smoke = Self.smoothF(1.3, 1.7, t)
        return f
    }
}

/// Who the team defeat shows as struck, read from the round's own events (never decided here):
/// the players hit in the encounter whose damage emptied the shared health. Nil unless that round
/// ended with `.healthDepleted`. An empty `struck` means no single struck player could be named
/// (the safe shared presentation: every board fails together, nobody shown as hit).
nonisolated struct TeamDefeatCast: Equatable, Sendable {
    let struck: Set<PlayerID>

    init(struck: Set<PlayerID>) { self.struck = struck }

    init?(events: [GameEvent], generation: UUID) {
        var ended = false
        var fatal: UUID?
        var hits: [UUID: Set<PlayerID>] = [:]
        for event in events where event.sessionGeneration == generation {
            switch event.kind {
            case .playerHit(let encounterID, let player): hits[encounterID, default: []].insert(player)
            case .teamEffectsCommitted(let encounterID, let healthDelta, _): if healthDelta < 0 { fatal = encounterID }
            case .roundEnded(let outcome): ended = outcome == .healthDepleted
            default: break
            }
        }
        guard ended else { return nil }
        struck = fatal.flatMap { hits[$0] } ?? []
    }
}
