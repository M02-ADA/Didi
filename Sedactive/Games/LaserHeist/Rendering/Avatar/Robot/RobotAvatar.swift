//
//  RobotAvatar.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit
import simd

/// Human-to-robot retargeting for one player, from one `Observation` per
/// frame: an `AvatarPoseFrame` slot converted by `AvatarPoseAdapter` (the
/// production path), or in DEBUG the synthetic demo/replay bridge. Uses that
/// player's `AvatarReference` when calibrated; direction only without one.
/// Presentation only; nothing here is a hit shape, and nothing here is fed
/// back to judgement.
///
/// Coordinates: player-plane joints are unmirrored (the person faces the
/// camera, so their right is the image's left). Model space for the robot is
/// +X = its anatomical right = screen right from behind. A player-plane
/// difference (dx, dy) becomes (−dx, dy) in model space: the one presentation
/// mirror, the same reflection the lane mapping applies to the live cutout.
/// Anatomical labels are never swapped: the player's right wrist aims the
/// robot's right forearm.
///
/// Sizes: every robot is shown at the same `RobotAvatarLayer.standingHeight`,
/// whoever drives it. Each player's own calibration still normalises their
/// motion: jump lift and sideways steps are scaled by
/// `standingHeight / player's standing height`, crouch depth is a share of
/// the player's own leg length, and arm and trunk directions are scale-free.
/// So a short and a tall player both make their robot jump, duck and reach
/// the same way for the same relative movement.
struct RobotRetargeter {
    /// One observation for this player, as the retargeter consumes it.
    /// Calibrated: player-plane game units. Direction only: aspect-corrected
    /// canonical image units (directions only; never a floor, scale or lift).
    struct Observation: Equatable {
        var joints: [PresentationJoint: PresentationPoint] = [:]
        var calibrated = false
        /// The lower of both soles, only when both are valid (calibrated only).
        var lowerSoleY: Double?
        /// Hip centre X, only when valid (calibrated only).
        var centerX: Double?
        /// Crown height, only when valid (calibrated only).
        var crownY: Double?
        /// K04: valid airborne jump evidence. `true` only for a valid
        /// `.airborne` jump phase; `false` for a valid other phase or invalid
        /// jump evidence; `nil` when the source carries no jump evidence at all
        /// (the D06 avatar packet today). The root lifts off only when `true`.
        var airborne: Bool?
    }

    /// The robot's hip-to-ankle height at rest (metres, model space).
    let robotLegRest: Float
    let robotHeight: Float
    /// The player's compatible standing reference (game units), or `nil`:
    /// direction-only presentation.
    private(set) var reference: AvatarReference?
    /// Robot metres per metre of this player's motion (shared robot height / player's standing height).
    private(set) var motionScale: Float
    var maximumSway: Float = 0.3
    var maximumLean: Float = 0.35
    var maximumHeadRoll: Float = 0.4
    /// Largest head turn shown (about 35°), and the soft zone that keeps a
    /// face looking straight at the camera from twitching.
    var maximumHeadYaw: Float = 0.6
    var headYawDeadband: Float = 0.06
    /// How far the nose sits in front of the ear axis, in half ear spans (an
    /// average human head): turns the nose's sideways offset into an angle.
    static let noseDepthPerHalfEarSpan = 1.3
    /// The ears must span at least this share of the shoulders to trust a turn
    /// (an ear-to-ear line that collapses means the head evidence is unreliable).
    /// About 0.4 facing the camera; 0.12 is a turn of roughly 70°, where one ear is all but hidden.
    static let minimumEarToShoulderSpan = 0.12
    /// Largest shrug shown (about 14°) and its noise soft zone.
    var maximumShoulderShrug: Float = 0.25
    var shoulderShrugDeadband: Float = 0.03
    /// The shoulders must span at least this share of the torso to trust their
    /// line: a body turned side-on to the camera stacks them.
    static let minimumShoulderToTorsoSpan = 0.25
    /// Crouch below this share of standing leg length is camera noise; a soft
    /// zone, so leaving it never steps the pelvis.
    var crouchDeadband: Float = 0.03
    /// Foot lift below this share of standing height is ankle noise (soft zone).
    var liftDeadband: Float = 0.02
    /// Visual joint confidence threshold: experimental presentation policy, not a tracker value.
    var minimumJointConfidence = 0.3
    /// Presence fades in fast and out slower: losing one frame never snaps
    /// the robot to rest, and recovery never jumps to the new pose.
    static let fadeIn = 0.08
    static let fadeOut = 0.3
    /// A gap this short (about 4 camera frames) is held as is: still shown as
    /// tracked, nothing fades, nothing dims.
    static let lossHold = 0.15
    /// How long one arm may lack evidence before it fades toward rest, and how
    /// fast it fades out and back in.
    static let armFade = 0.25
    static let armFadeIn = 0.1
    /// Missing feet: hold the last lift this long, then let it settle.
    static let liftHold = 0.15
    static let relaxTime = 0.25

    /// What the robot shows: the measured pose scaled by presence and arm weights.
    private(set) var targets = RobotPoseTargets.rest
    private(set) var lift: Float = 0
    private(set) var sway: Float = 0
    /// Each tracked ankle's sideways offset from the player's own standing
    /// stance (relative to the hip centre, mirrored once, robot metres); absent
    /// when that ankle gave no evidence this frame. The foot planner steps a
    /// foot only on this evidence, so a lean (hips move, ankles stay) never steps.
    private(set) var footDelta: [RobotPoseTargets.Side: Float] = [:]
    /// Confidence of each ankle used this frame (diagnostics).
    private(set) var ankleConfidence: [RobotPoseTargets.Side: Float] = [:]
    /// Frames used to learn each ankle's standing offset from the hip centre.
    static let stanceFrames = 10
    static let maximumFootDelta: Float = 0.35
    private(set) var isAvailable = false
    /// Whether the last observation was calibrated (lift, sway, crouch, feet allowed).
    private(set) var isCalibrated = false
    /// 0…1: how much of the measured pose is shown (fades on loss and recovery).
    private(set) var presence: Float = 0
    /// The latest measured pose, held through brief gaps.
    private var measured = RobotPoseTargets.rest
    private var measuredLift: Float = 0
    private var measuredSway: Float = 0
    private var measuredFootDelta: [RobotPoseTargets.Side: Float] = [:]
    private var stanceRest: [RobotPoseTargets.Side: Float] = [:]
    private var stanceSamples: [RobotPoseTargets.Side: Int] = [:]
    private var armWeights: [RobotPoseTargets.Side: Float] = [:]
    /// When the head turn last had evidence; without it the turn eases back to straight.
    private var headTurnSeen: Double?
    /// When the shoulder line last had evidence; without it the shrug eases out.
    private var shrugSeen: Double?
    private var liftSeen: Double?
    private var lastPresent: Double?
    /// Fast derivative tracking so takeoff is followed within about a frame,
    /// while standing jitter (slow) is still smoothed at 3 Hz.
    private var liftFilter = Self.makeLiftFilter()
    private var lastTime: Double?
    private var filters: [PresentationJoint: (x: OneEuroFilter, y: OneEuroFilter)] = [:]
    /// When each joint was last seen; a joint back after a gap restarts its filter.
    private var seen: [PresentationJoint: Double] = [:]
    /// When each arm last had evidence; an arm without it for `armHold` returns to the bind pose.
    private var armSeen: [RobotPoseTargets.Side: Double] = [:]
    static let jointGap = 0.3
    static let armHold = 0.5
    /// Longest projected length seen per segment, for foreshortening depth.
    private var longest: [String: Double] = [:]

    private static func makeLiftFilter() -> OneEuroFilter {
        var f = OneEuroFilter(minimumCutoff: 3, beta: 6)
        f.derivativeCutoff = 4
        return f
    }

    private static func scale(for reference: AvatarReference?, robotHeight: Float) -> Float {
        guard let standing = reference.map({ Float($0.standingHeight) }), standing > 0 else { return 1 }
        return robotHeight / standing
    }

    init(reference: AvatarReference?, robotLegRest: Float, robotHeight: Float = RobotAvatarLayer.standingHeight) {
        self.reference = reference
        self.robotLegRest = robotLegRest
        self.robotHeight = robotHeight
        motionScale = Self.scale(for: reference, robotHeight: robotHeight)
    }

    /// Through the temporary CP1-calibration adapter (`AvatarReference(calibration:layout:)`).
    init(calibration: PlayerCalibration, layout: PlayerPlaneLayout, robotLegRest: Float,
         robotHeight: Float = RobotAvatarLayer.standingHeight) {
        self.init(reference: AvatarReference(calibration: calibration, layout: layout),
                  robotLegRest: robotLegRest, robotHeight: robotHeight)
    }

    /// Deepest pelvis drop the legs can show, as a share of the rest leg.
    static let maximumCrouchShare: Float = 0.55

    /// Switches to another compatible reference, or to none (direction only).
    /// Any change drops every calibrated value first: no root lift, floor
    /// offset, stance, crouch or lift filter survives a calibration change.
    mutating func setReference(_ reference: AvatarReference?) {
        guard reference != self.reference else { return }
        resetCalibratedState()
        self.reference = reference
        motionScale = Self.scale(for: reference, robotHeight: robotHeight)
    }

    /// Forgets everything that depends on calibration, keeping direction-only
    /// state (arm and lean directions, presence).
    mutating func resetCalibratedState() {
        measuredLift = 0
        measuredSway = 0
        measured.pelvisDrop = 0
        measured.footLift = [:]
        measured.footShift = [:]
        measuredFootDelta = [:]
        ankleConfidence = [:]
        stanceRest = [:]
        stanceSamples = [:]
        liftSeen = nil
        liftFilter = Self.makeLiftFilter()
        isCalibrated = false
        lift = 0
        sway = 0
        footDelta = [:]
        targets.pelvisDrop = 0
        targets.footLift = [:]
        targets.footShift = [:]
    }

    /// One observation at `time` (source capture time, or render host time
    /// when nothing fresh exists); `nil` means unavailable: hold briefly, then
    /// fade to neutral. A calibrated observation needs `reference`.
    mutating func update(_ observation: Observation?, time: Double) {
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        guard let observation else { return relax(dt, time: time) }
        isAvailable = true
        lastPresent = time
        defer { compose(dt: dt, present: true) }
        let reference = observation.calibrated ? reference : nil
        if reference == nil, isCalibrated { resetCalibratedState() }
        isCalibrated = reference != nil

        if let reference {
            let standing = Float(reference.standingHeight)
            // JUMP (K04): the lower sole, through a soft noise zone and a fast adaptive
            // filter, but only while the evidence says the player is validly airborne,
            // as the judge requires for a jump to clear. Soles that rise without it
            // (or with no jump evidence carried) keep the root on the floor: the legs
            // still show a knee raise, never a jump that the evidence cannot back.
            if let sole = observation.lowerSoleY {
                let raw = observation.airborne == true ? Float(max(0, sole)) : 0
                measuredLift = liftFilter.filter(Self.softZone(raw, liftDeadband * standing), dt: dt) * motionScale
                liftSeen = time
            } else if time - (liftSeen ?? time) > Self.liftHold {
                measuredLift *= Float(exp(-dt / Self.relaxTime))
            }
            // LATERAL: hip centre, mirrored once about the lane (as `GameWorldMapping.cutoutPoint`).
            if let x = observation.centerX {
                let step = Float(reference.laneCenterX - x) * motionScale
                measuredSway = min(maximumSway, max(-maximumSway, step))
            }
        }

        // Filtered joints (1€: smooth when still, fast when moving).
        var p: [PresentationJoint: SIMD2<Double>] = [:]
        for (joint, point) in observation.joints where point.confidence >= minimumJointConfidence {
            if let last = seen[joint], time - last > Self.jointGap { filters[joint] = nil }
            seen[joint] = time
            var f = filters[joint] ?? (x: OneEuroFilter(minimumCutoff: 2, beta: 4), y: OneEuroFilter(minimumCutoff: 2, beta: 4))
            p[joint] = SIMD2(Double(f.x.filter(Float(point.x), dt: dt)), Double(f.y.filter(Float(point.y), dt: dt)))
            filters[joint] = f
        }
        func model(_ a: SIMD2<Double>, _ b: SIMD2<Double>, segment: String) -> SIMD3<Float> {
            let d = b - a
            let length = simd_length(d)
            longest[segment] = max(length, (longest[segment] ?? length) * 0.999)
            // Shorter than its longest seen: the limb points toward the camera, i.e. forward (−Z).
            let depth = sqrt(max(0, (longest[segment] ?? length) * (longest[segment] ?? length) - length * length))
            return SIMD3(Float(-d.x), Float(d.y), Float(-depth))
        }

        // ARMS: shoulder→elbow and elbow→wrist directions per anatomical side
        // (B1 has no elbows: the straight shoulder→wrist path, elbow bend procedural).
        for (side, s, e, w) in [(RobotPoseTargets.Side.left, PresentationJoint.leftShoulder, PresentationJoint.leftElbow, PresentationJoint.leftWrist),
                                (.right, .rightShoulder, .rightElbow, .rightWrist)] {
            guard let shoulder = p[s], p[e] != nil || p[w] != nil else {
                // Low-confidence arm: hold briefly, then fade toward rest (never invent a pose).
                if time - (armSeen[side] ?? time) > Self.armHold {
                    let k = Float(1 - exp(-dt / Self.armFade))
                    armWeights[side, default: 0] += (0 - armWeights[side, default: 0]) * k
                }
                continue
            }
            armSeen[side] = time
            let k = Float(1 - exp(-dt / Self.armFadeIn))
            armWeights[side, default: 0] += (1 - armWeights[side, default: 0]) * k
            if let elbow = p[e] {
                measured.upperArm[side] = model(shoulder, elbow, segment: "upper\(side)")
                if let wrist = p[w] { measured.forearm[side] = model(elbow, wrist, segment: "fore\(side)") }
            } else if let wrist = p[w] {
                let d = model(shoulder, wrist, segment: "arm\(side)")
                measured.upperArm[side] = d
                measured.forearm[side] = d
            }
        }

        // LEAN: shoulders over hips. HEAD: the ear line. Scale-free: both modes.
        if let ls = p[.leftShoulder], let rs = p[.rightShoulder], let lh = p[.leftHip], let rh = p[.rightHip] {
            let d = (ls + rs) / 2 - (lh + rh) / 2
            measured.lean = min(maximumLean, max(-maximumLean, Float(atan2(-d.x, d.y))))
        }
        if let le = p[.leftEar], let re = p[.rightEar] {
            let roll = Float(atan2(re.y - le.y, -(re.x - le.x)))
            measured.headRoll = min(maximumHeadRoll, max(-maximumHeadRoll, roll + measured.lean))
        }
        // SHRUG: the shoulder line's tilt beyond the trunk lean. A level shoulder
        // line is level for every body and stays level when the body turns, so it
        // needs no reference. A rigid lean tilts the line by −lean; only the rest
        // shows, on the raised side's collarbone (`RobotPoseSolver`).
        if let shrug = shoulderShrug(p) {
            measured.shoulderShrug = shrug
            shrugSeen = time
        } else if time - (shrugSeen ?? time) > Self.lossHold || shrugSeen == nil {
            measured.shoulderShrug *= Float(exp(-dt / Self.armFade))
        }
        // HEAD TURN: the nose between the ears. Facing the camera it sits midway
        // for every face, whatever the camera height or distance, so the offset
        // needs no standing reference: scale-free, both modes. Mirrored once,
        // like every model-space X. Without trustworthy evidence the turn eases
        // back to straight rather than holding an old look.
        if let turn = headTurn(p) {
            measured.headYaw = turn
            headTurnSeen = time
        } else if time - (headTurnSeen ?? time) > Self.lossHold || headTurnSeen == nil {
            measured.headYaw *= Float(exp(-dt / Self.armFade))
        }

        guard let reference else { return }
        let standing = Float(reference.standingHeight)
        // DUCK and knee raise: each leg's hip-to-ankle height as a share of standing, onto the robot's leg.
        var legsMeasured = false
        if let lh = p[.leftHip], let rh = p[.rightHip] {
            let hipY = (lh.y + rh.y) / 2
            let hip0 = reference.standingHipY
            var reach: [RobotPoseTargets.Side: Float] = [:]
            for (side, ankle) in [(RobotPoseTargets.Side.left, PresentationJoint.leftAnkle), (.right, .rightAnkle)] {
                guard let a = p[ankle] else { continue }
                let legStanding = hip0 - reference.standingAnkleY(side)
                guard legStanding > 0 else { continue }
                let share = Float((hipY - a.y) / legStanding)
                let bend = Self.softZone(max(0, 1 - share), crouchDeadband)
                reach[side] = robotLegRest * min(1, max(1 - Self.maximumCrouchShare, 1 - bend))
            }
            if let longest = reach.values.max() {
                legsMeasured = true
                measured.pelvisDrop = robotLegRest - longest
                for side in RobotPoseTargets.Side.allCases { measured.footLift[side] = longest - (reach[side] ?? longest) }
            }
        }
        if let crown = observation.crownY, standing > 0 {
            // K04: the head goes down by the same share of the avatar's height as the
            // crown went down of the player's (up to the legs' reach). The mascot's
            // legs are a far smaller share of its height than a person's, so a
            // leg-share crouch alone drew a clearing duck into the beam. Hip/ankle
            // evidence still shapes the legs; the deeper of the two is shown. A
            // presentation estimate: a head-only duck also lowers the avatar.
            let share = Self.softZone(max(0, 1 - Float(crown) / standing), crouchDeadband)
            let drop = min(robotLegRest * Self.maximumCrouchShare, share * RobotSkeleton.modelHeight)
            if !legsMeasured {
                measured.pelvisDrop = drop
                for side in RobotPoseTargets.Side.allCases { measured.footLift[side] = 0 }
            } else if drop > measured.pelvisDrop {
                measured.pelvisDrop = drop
            }
        }

        // FEET: each ankle's sideways position relative to the hip centre, against the
        // player's own standing stance (learned from the first grounded frames). A lean
        // moves the hips, not the ankles; a step moves the ankles.
        measuredFootDelta = [:]
        ankleConfidence = [:]
        if let lh = p[.leftHip], let rh = p[.rightHip] {
            let hipX = (lh.x + rh.x) / 2
            for (side, joint) in [(RobotPoseTargets.Side.left, PresentationJoint.leftAnkle), (.right, .rightAnkle)] {
                guard let a = p[joint] else { continue }
                let relative = Float(hipX - a.x) * motionScale  // mirrored once: player-plane −X is robot +X
                if stanceSamples[side, default: 0] < Self.stanceFrames {
                    guard measuredLift < 0.01, (measured.footLift[side] ?? 0) < 0.01 else { continue }
                    let n = Float(stanceSamples[side, default: 0])
                    stanceRest[side] = ((stanceRest[side] ?? 0) * n + relative) / (n + 1)
                    stanceSamples[side, default: 0] += 1
                    continue
                }
                measuredFootDelta[side] = min(Self.maximumFootDelta, max(-Self.maximumFootDelta, relative - (stanceRest[side] ?? relative)))
                ankleConfidence[side] = Float(observation.joints[joint]?.confidence ?? 0)
            }
        }
    }

    /// The shrug from one frame's filtered joints, or `nil` without both
    /// shoulders and hips, or when the shoulders are too close together to trust.
    private func shoulderShrug(_ p: [PresentationJoint: SIMD2<Double>]) -> Float? {
        guard let ls = p[.leftShoulder], let rs = p[.rightShoulder], let lh = p[.leftHip], let rh = p[.rightHip] else { return nil }
        let torso = simd_distance((ls + rs) / 2, (lh + rh) / 2)
        guard torso > 1e-4, simd_distance(ls, rs) >= Self.minimumShoulderToTorsoSpan * torso else { return nil }
        // Model space (x mirrored once): from the robot's left shoulder to its right.
        let roll = Float(atan2(rs.y - ls.y, ls.x - rs.x))
        let excess = roll + measured.lean
        let shown = Self.softZone(abs(excess), shoulderShrugDeadband)
        return min(maximumShoulderShrug, shown) * (excess < 0 ? -1 : 1)
    }

    /// The head turn from one frame's filtered joints, or `nil` when the nose
    /// or either ear is missing or the ear span is implausibly small.
    private func headTurn(_ p: [PresentationJoint: SIMD2<Double>]) -> Float? {
        guard let nose = p[.nose], let le = p[.leftEar], let re = p[.rightEar] else { return nil }
        let halfSpan = simd_distance(le, re) / 2
        guard halfSpan > 1e-4 else { return nil }
        if let ls = p[.leftShoulder], let rs = p[.rightShoulder],
           halfSpan * 2 < Self.minimumEarToShoulderSpan * simd_distance(ls, rs) { return nil }
        // Model space is mirrored once (−x): a nose toward the image's left is a turn to the robot's right.
        let offset = -(nose.x - (le.x + re.x) / 2) / halfSpan
        let angle = Float(atan(offset / Self.noseDepthPerHalfEarSpan))
        let shown = Self.softZone(abs(angle), headYawDeadband)
        return min(maximumHeadYaw, shown) * (angle < 0 ? -1 : 1)
    }

    #if DEBUG
    /// DEBUG-only synthetic bridge: the demo's and the historical replay
    /// fixture's CP1-shaped samples, converted to one observation. Production
    /// avatars never read CP1; they take `AvatarPoseFrame`s.
    mutating func update(sample: PlayerBodySample?, joints: PresentationPoseSample?, time: Double) {
        guard let sample, let reference, sample.playerID == reference.playerID, sample.trackingStatus == .reliable,
              sample.calibrationRevision == reference.calibrationRevision
        else { return update(nil, time: time) }
        let g = sample.geometry
        var observation = Observation(joints: joints?.joints ?? [:], calibrated: true)
        if let left = g.leftSoleY.value, let right = g.rightSoleY.value { observation.lowerSoleY = min(left, right) }
        observation.airborne = sample.jumpState.validity == .valid && sample.jumpState.phase == .airborne
        if g.centerX.validity == .valid { observation.centerX = g.centerX.value }
        if joints == nil { observation.crownY = g.crownY.value }
        update(observation, time: time)
    }
    #endif

    /// No usable player: never invent movement. Fade the held pose out (no
    /// snap) and forget joint filters, so recovery starts from fresh data and
    /// fades back in.
    private mutating func relax(_ dt: Double, time: Double) {
        // A brief gap (one or two missed detections): hold the pose as it is.
        if isAvailable, let last = lastPresent, time - last <= Self.lossHold { return }
        isAvailable = false
        measuredFootDelta = [:]
        ankleConfidence = [:]
        if !seen.isEmpty, seen.values.allSatisfy({ time - $0 > Self.jointGap }) { filters = [:] }
        compose(dt: dt, present: false)
    }

    /// What is shown: the measured pose scaled by presence and arm weights.
    private mutating func compose(dt: Double, present: Bool) {
        let tau = present ? Self.fadeIn : Self.fadeOut
        presence += ((present ? 1 : 0) - presence) * Float(1 - exp(-dt / tau))
        if presence < 0.001 { presence = 0 } else if presence > 0.999 { presence = 1 }
        let w = presence
        lift = measuredLift * w
        sway = measuredSway * w
        footDelta = measuredFootDelta.mapValues { $0 * w }
        var t = measured
        t.pelvisDrop *= w
        t.lean *= w
        t.headRoll *= w
        t.headYaw *= w
        t.shoulderShrug *= w
        for side in RobotPoseTargets.Side.allCases {
            t.footLift[side] = (measured.footLift[side] ?? 0) * w
            t.armWeight[side] = (measured.upperArm[side] == nil ? 0 : armWeights[side, default: 0]) * w
        }
        targets = t
    }

    /// Continuous soft dead zone: small values (noise) are damped, and from
    /// `zone` up the value passes unchanged (K04: the earlier −zone/2 offset drew
    /// every jump 1–2 cm low, so a borderline CLEAR looked like a HIT). Smooth:
    /// f(0) = 0, f′(0) = 0, f(zone) = zone, f′(zone) = 1; monotonic between.
    static func softZone(_ x: Float, _ zone: Float) -> Float {
        guard zone > 0, x < zone else { return x }
        guard x > 0 else { return 0 }
        return 2 * x * x / zone - x * x * x / (zone * zone)
    }
}

/// Both players' robots, standing on their `PlayerCutoutEntity`s in place of
/// the pictograms. Each instance is a clone of one loaded template with its
/// own `jointTransforms`, written once per player per new body frame.
@MainActor
final class RobotAvatarLayer {
    struct Robot {
        let container: Entity
        let model: ModelEntity
        let solver: RobotPoseSolver
        var retargeter: RobotRetargeter
        /// Feet in hoverboard space (the player entity's frame).
        var planner: RobotFootPlanner
        /// Bind-pose ankle X per side (model space) and ankle height.
        let bindAnkleX: [RobotPoseTargets.Side: Float]
        let bindAnkleY: Float
    }

    /// Debug readout of one robot's feet (hoverboard metres), to tell why a foot
    /// moved or slid: no tracked step, root-only motion, no plant, IK reach, timing.
    struct FootDiagnostics: Equatable {
        var pelvisX: Float = 0
        var trackedDelta: [RobotPoseTargets.Side: Float] = [:]
        var ankleConfidence: [RobotPoseTargets.Side: Float] = [:]
        var contact: [RobotPoseTargets.Side: RobotFootPlanner.Contact] = [:]
        var reason: [RobotPoseTargets.Side: RobotFootPlanner.Reason] = [:]
        /// Where the planner wants each foot, and where the solved foot actually is.
        var targetX: [RobotPoseTargets.Side: Float] = [:]
        var actualX: [RobotPoseTargets.Side: Float] = [:]
        /// Solved foot height above its resting height on the deck.
        var height: [RobotPoseTargets.Side: Float] = [:]
        /// Largest sideways movement of a foot since it was last planted (skating).
        var plantedDrift: [RobotPoseTargets.Side: Float] = [:]
        var reachShortfall: [RobotPoseTargets.Side: Float] = [:]
        var steps: [RobotPoseTargets.Side: Int] = [:]

        /// One debug line: per foot contact, step reason, tracked ankle offset, drift, height; pelvis X.
        var line: String {
            func cm(_ v: Float?) -> String { v.map { String(format: "%+.1f", $0 * 100) } ?? "—" }
            let feet = [(RobotPoseTargets.Side.left, "L"), (.right, "R")].map { side, name in
                let reach = (reachShortfall[side] ?? 0) > 0.002 ? " REACH \(cm(reachShortfall[side]))" : ""
                return "\(name) \(contact[side]?.rawValue ?? "—")(\(reason[side]?.rawValue ?? "—")) ankle \(cm(trackedDelta[side])) "
                    + "drift \(String(format: "%.1f", (plantedDrift[side] ?? 0) * 100)) h \(String(format: "%.1f", max(0, height[side] ?? 0) * 100))"
                    + " steps \(steps[side] ?? 0)\(reach)"
            }
            return feet.joined(separator: " · ") + " · pelvis \(cm(pelvisX)) cm"
        }
    }

    /// Each player's bundled avatar: the two approved colour variants of the
    /// same mascot (Codex's `LaserHeist-Mascot-Color-Variants`; identical mesh,
    /// skin weights, 20-joint skeleton and bind pose, only the body colour
    /// differs). P1 Lemon `#F6CA58`, P2 Tangerine `#F78146` (byte-identical
    /// to the earlier orange `mascot.usdz`). Keyed only by the established
    /// `PlayerID`: never by screen position, lane or body size. Rollback: see
    /// the robot README.
    nonisolated static func resourceName(for player: PlayerID) -> String {
        switch player {
        case .player1: "mascot-p1-lemon"
        case .player2: "mascot-p2-tangerine"
        }
    }
    /// Turn rising arm targets outward so they clear the mascot's large head
    /// (`MascotPoseEnvelope`). Tied to the asset: every player's resource is a
    /// variant of that mascot; another avatar never gets it.
    static let headClearance = PlayerID.allCases.allSatisfy { resourceName(for: $0).hasPrefix("mascot") }
    /// Every robot's standing height on screen, in metres: one shared size for
    /// P1 and P2 (the size P1's robot had before sizes were equalised). Player
    /// height never changes it; see `RobotRetargeter.motionScale`.
    nonisolated static let standingHeight: Float = 1.6
    /// The uniform scale that gives the model that height.
    nonisolated static var modelScale: Float { standingHeight / RobotSkeleton.modelHeight }
    static let unavailableOpacity: Float = 0.5

    private(set) var robots: [PlayerID: Robot] = [:]
    /// Procedural planted feet and side steps (`RobotFootPlanner`, the K07
    /// proof of concept; adoption is a separate, pending team decision). On:
    /// planted feet and stepping. Off: the earlier behaviour, where the whole
    /// avatar, feet included, translates with the hip centre. This one switch
    /// is its whole activation; `-legacyFeet` starts with it off.
    var footPlanting = RobotAvatarLayer.startsWithFootPlanting {
        didSet { if footPlanting != oldValue { resetFeet() } }
    }
    private static var startsWithFootPlanting: Bool {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("-legacyFeet")
        #else
        true
        #endif
    }
    /// D07 CANDIDATE, not approved (K04): draw each player's laser bands in that
    /// player's normalized avatar space instead of their own game units, so a
    /// beam meets the 1.6 m mascot where it meets the player relative to their
    /// standing height. Display only: the judged bands, the judge and every
    /// body value are unchanged. Off by default; only the DEBUG
    /// `-normalizedLasers` launch flag turns it on, for A/B comparison.
    var normalizesLaserBands = false

    /// The factor from a player's game-unit heights to their drawn laser
    /// heights, or `nil`: draw the authoritative band as is (candidate off, no
    /// avatar, or no compatible calibration, so no avatar scale to match).
    /// It is the avatar's own `motionScale` (shared height ÷ the player's
    /// standing height), divided by `metersPerGameUnit` because the beam
    /// mapping multiplies by it again: the floor stays at 0, no double scaling.
    func laserBandScale(for player: PlayerID, mapping: GameWorldMapping) -> Float? {
        guard normalizesLaserBands, mapping.metersPerGameUnit > 0, let retargeter = robots[player]?.retargeter,
              retargeter.reference != nil else { return nil }
        return retargeter.motionScale / mapping.metersPerGameUnit
    }

    /// Collect `footDiagnostics` (one extra forward pass per robot per frame).
    var diagnosticsEnabled = false
    private(set) var footDiagnostics: [PlayerID: FootDiagnostics] = [:]
    private var plantAnchor: [PlayerID: [RobotPoseTargets.Side: Float]] = [:]
    private weak var scene: LaserScene?
    private let lights = Entity()
    #if DEBUG
    /// K04 diagnostic (`-avatarFairness`): small markers on each avatar's head
    /// top (orange), hand centres (magenta) and soles (lime), beside the human
    /// evidence markers and band edges the presenter already draws. Built once
    /// per player; removed with the avatars.
    var showsFairnessMarkers = false
    private var fairnessMarkers: [PlayerID: [ModelEntity]] = [:]
    /// The DEBUG snapshot bridge's last frame (`apply(_:joints:)`).
    private(set) var lastFrame: (generation: UUID, frameID: UInt64)?
    #endif
    /// Render-rate smoothing time constant (seconds); `nil` shows each body
    /// frame as it arrives. The synthetic demo sets it and calls `render(now:)`
    /// every rendered frame, so 30 Hz poses move smoothly on a 60 Hz display.
    var smoothing: Double?
    private struct Shown {
        var targets: RobotPoseTargets
        var lift: Float
        var sway: Float
        var footDelta: [RobotPoseTargets.Side: Float]
    }
    private var shown: [PlayerID: Shown] = [:]
    private var lastRender: Double?

    /// Why an avatar asset cannot be used. Loading never falls back silently.
    enum LoadError: Error, Equatable, CustomStringConvertible {
        case missingResource(String)
        case unreadable(String, reason: String)
        case noSkinnedModel(String)
        case missingJoints(String, [String])

        var description: String {
            switch self {
            case .missingResource(let name): "avatar asset \(name).usdz is not in the app bundle"
            case .unreadable(let name, let reason): "avatar asset \(name).usdz could not be loaded: \(reason)"
            case .noSkinnedModel(let name): "avatar asset \(name).usdz has no skinned model"
            case .missingJoints(let name, let joints): "avatar asset \(name).usdz lacks joints \(joints.joined(separator: ", "))"
            }
        }
    }

    /// One player's avatar, loaded from the bundle and checked for a skinned
    /// model with every joint the solver drives.
    static func loadTemplate(for player: PlayerID, bundle: Bundle = .main) async throws -> Entity {
        let name = resourceName(for: player)
        guard let url = bundle.url(forResource: name, withExtension: "usdz") else { throw LoadError.missingResource(name) }
        let template: Entity
        do { template = try await Entity(contentsOf: url) } catch {
            throw LoadError.unreadable(name, reason: String(describing: error))
        }
        try validate(template, name: name)
        return template
    }

    /// Throws unless `template` has a skinned model with every required joint.
    static func validate(_ template: Entity, name: String) throws {
        guard let model = skinnedModel(in: template) else { throw LoadError.noSkinnedModel(name) }
        let missing = missingJoints(paths: model.jointNames, bind: model.jointTransforms)
        guard missing.isEmpty else { throw LoadError.missingJoints(name, missing) }
    }

    /// The solver's required joints absent from a rig's joint paths.
    static func missingJoints(paths: [String], bind: [Transform]) -> [String] {
        let skeleton = RobotSkeleton(paths: paths, bind: bind)
        return RobotSkeleton.requiredJoints.filter { skeleton($0) == nil }
    }

    /// Every player's avatar, each resource loaded once; each player then gets
    /// its own clone. Throws on the first asset that is missing or invalid.
    static func loadTemplates(bundle: Bundle = .main) async throws -> [PlayerID: Entity] {
        var byResource: [String: Entity] = [:]
        var templates: [PlayerID: Entity] = [:]
        for player in PlayerID.allCases {
            let name = resourceName(for: player)
            if byResource[name] == nil { byResource[name] = try await loadTemplate(for: player, bundle: bundle) }
            templates[player] = byResource[name]
        }
        return templates
    }

    private static var sharedLoad: Task<[PlayerID: Entity], any Error>?

    /// The app's templates, loaded from the bundle once and reused by every
    /// scene (Retry included); templates are only ever cloned, never shown.
    /// A failed load is not cached, so a later call tries again.
    static func sharedTemplates() async throws -> [PlayerID: Entity] {
        let load = sharedLoad ?? Task { try await loadTemplates() }
        sharedLoad = load
        do { return try await load.value } catch {
            sharedLoad = nil
            throw error
        }
    }

    /// The skinned model: the descendant with joints.
    static func skinnedModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty { return model }
        for child in entity.children { if let found = skinnedModel(in: child) { return found } }
        return nil
    }

    /// Through the temporary CP1 adapter: each calibrated player's `AvatarReference`.
    convenience init(scene: LaserScene, calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout,
                     templates: [PlayerID: Entity]) {
        self.init(scene: scene, references: calibrations.mapValues { AvatarReference(calibration: $0, layout: layout) },
                  templates: templates)
    }

    /// Avatars for exactly the players with a reference (the CP1-calibration
    /// adapter and the DEBUG bridge).
    convenience init(scene: LaserScene, references: [PlayerID: AvatarReference], templates: [PlayerID: Entity]) {
        self.init(scene: scene, players: Set(references.keys), references: references, templates: templates)
    }

    /// `templates` from `loadTemplates()`: each listed player gets a clone of
    /// its own colour variant, standing on that player's existing
    /// `PlayerCutoutEntity` (its lane); one solver setup, size and lighting
    /// for every player. A player without a reference starts direction-only;
    /// `AvatarPoseFrame`s supply references as calibration becomes compatible.
    init(scene: LaserScene, players: Set<PlayerID>, references: [PlayerID: AvatarReference] = [:],
         templates: [PlayerID: Entity]) {
        self.scene = scene
        for player in PlayerID.allCases where players.contains(player) {
            guard let entity = scene.players[player], let template = templates[player] else { continue }
            let reference = references[player]
            let robot = template.clone(recursive: true)
            guard let model = Self.skinnedModel(in: robot) else { continue }
            let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
            let solver = RobotPoseSolver(skeleton: skeleton)
            let container = Entity()
            container.name = "player.\(player.rawValue).robot"
            // One shared size for every player; uniform scale only.
            container.scale = SIMD3(repeating: Self.modelScale)
            container.addChild(robot)
            entity.addChild(container)
            entity.hasMascot = true
            let bindWorld = skeleton.world(skeleton.bind).position
            let legRest = skeleton("Thigh_L").flatMap { t in skeleton("Foot_L").map { bindWorld[t].y - bindWorld[$0].y } } ?? solver.legLength
            var ankleX: [RobotPoseTargets.Side: Float] = [:]
            for (side, name) in [(RobotPoseTargets.Side.left, "Foot_L"), (.right, "Foot_R")] {
                ankleX[side] = skeleton(name).map { bindWorld[$0].x } ?? (side == .left ? -0.1 : 0.1)
            }
            robots[player] = Robot(container: container, model: model, solver: solver,
                                   retargeter: RobotRetargeter(reference: reference, robotLegRest: legRest),
                                   planner: RobotFootPlanner(rest: ankleX.mapValues { $0 * Self.modelScale }),
                                   bindAnkleX: ankleX, bindAnkleY: skeleton("Foot_L").map { bindWorld[$0].y } ?? 0)
            apply(player, time: 0)
        }
        // The robot's materials are physically based: give it light.
        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: [0, 0.8, 0], from: [1.5, 3, 3], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.look(at: [0, 0.8, 0], from: [-2, 1.5, 2], relativeTo: nil)
        lights.name = "robot.lights"
        lights.addChild(key)
        lights.addChild(fill)
        scene.root.addChild(lights)
        // The avatars' own dim, neutral environment light in place of RealityView's
        // default one, which over-exposed the matte orange (red clipped on 81% of
        // its pixels, washing it to peach). With only key/fill plus this, the lit
        // bodies match the colours validated for the assets (P2 #F78146, P1
        // #F6CA58, measured #F5CA58), under the same lights. Only the
        // avatars receive it; the corridor and lasers are unlit and unaffected.
        if let environment = Self.neutralEnvironment() {
            lights.components.set(ImageBasedLightComponent(source: .single(environment)))
            for robot in robots.values { robot.container.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lights)) }
        }
    }

    /// A uniform dark-grey environment (sRGB 0.18): soft fill so shadowed sides
    /// keep their shape, too dim to wash out the material colours.
    static func neutralEnvironment(level: CGFloat = 0.18) -> EnvironmentResource? {
        guard let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        return context.makeImage().flatMap { try? EnvironmentResource(equirectangular: $0, withName: "avatar.environment") }
    }

    // MARK: - K03: AvatarPoseFrame input (the production path)

    /// Applies one render tick's mailbox drain: first the resets it reports,
    /// then the newest frame; with no fresh frame, every avatar relaxes toward
    /// neutral at `now` (host time). Never reads CP1.
    func apply(_ drain: AvatarPoseDrain, now: Double) {
        if drain.reset.all {
            for player in Array(robots.keys) { resetPresentation(player, now: now) }
        }
        for player in drain.reset.calibration where !drain.reset.all { resetCalibration(player) }
        if let frame = drain.frame {
            apply(frame)
        } else if !drain.hasCurrent {
            for player in Array(robots.keys) {
                robots[player]?.retargeter.update(nil, time: now)
                apply(player, time: now)
            }
        }
    }

    /// One validated frame: each slot independently. A slot's reference
    /// change (recalibration, downgrade to direction-only) resets that
    /// player's calibrated state before its observation is used.
    func apply(_ frame: AvatarPoseFrame) {
        let time = frame.source.capturedAt
        let aspect = Double(frame.source.context.imageWidth) / Double(frame.source.context.imageHeight)
        for player in Array(robots.keys) {
            var observation: RobotRetargeter.Observation?
            if case .available(let pose) = frame.slot(player) {
                let reference = pose.capability.reference.map { AvatarReference(standing: $0, playerID: player) }
                if reference != robots[player]?.retargeter.reference {
                    resetCalibration(player)
                    robots[player]?.retargeter.setReference(reference)
                }
                observation = AvatarPoseAdapter.observation(pose, playerID: player, imageAspect: aspect)
            }
            robots[player]?.retargeter.update(observation, time: time)
            apply(player, time: time)
        }
    }

    /// Drops one player's calibrated presentation: retargeter values, foot
    /// plan, planted anchors and the smoothed pose being shown.
    private func resetCalibration(_ player: PlayerID) {
        guard var robot = robots[player] else { return }
        robot.retargeter.resetCalibratedState()
        robot.planner = RobotFootPlanner(rest: robot.planner.rest)
        robots[player] = robot
        shown[player] = nil
        plantAnchor[player] = nil
        footDiagnostics[player] = nil
    }

    /// Back to a neutral avatar at once (stop, interruption, source or control
    /// change): a fresh retargeter with no reference, a fresh foot plan, no
    /// smoothed pose.
    private func resetPresentation(_ player: PlayerID, now: Double) {
        guard var robot = robots[player] else { return }
        robot.retargeter = RobotRetargeter(reference: nil, robotLegRest: robot.retargeter.robotLegRest,
                                           robotHeight: robot.retargeter.robotHeight)
        robot.planner = RobotFootPlanner(rest: robot.planner.rest)
        robots[player] = robot
        shown[player] = nil
        plantAnchor[player] = nil
        footDiagnostics[player] = nil
        present(player, k: 1, time: now)
    }

    #if DEBUG
    private func updateFairnessMarkers(_ player: PlayerID) {
        guard let scene, let points = extremityPoints(of: player) else { return }
        if fairnessMarkers[player] == nil {
            fairnessMarkers[player] = [UIColor.orange, .magenta, .magenta, .green, .green].map { color in
                let marker = ModelEntity(mesh: .generateBox(size: 0.05), materials: [UnlitMaterial(color: color)])
                marker.name = "avatar.fairness.\(player.rawValue)"
                scene.root.addChild(marker)
                return marker
            }
        }
        let positions = [points.headTop, points.leftHand, points.rightHand, points.leftSole, points.rightSole]
        for (marker, position) in zip(fairnessMarkers[player] ?? [], positions) {
            // Just in front of the avatar, so the marker is not hidden inside the mesh.
            marker.position = position + [0, 0, 0.25]
        }
    }

    // MARK: - DEBUG synthetic bridge (CP1-shaped demo and historical replay fixtures)

    /// A new camera session restarts frame IDs; forget the last one shown.
    func resetFrameOrder() { lastFrame = nil }

    /// DEBUG-only: shows one CP1-shaped synthetic body frame (the demo, or the
    /// bundled historical replay fixture); `joints` only when it belongs to the
    /// same frame. Labelled synthetic; production avatars take `AvatarPoseFrame`s
    /// and never read CP1.
    func apply(_ snapshot: BodySnapshot, joints: PresentationPoseFrame? = nil) {
        if let lastFrame, lastFrame.generation == snapshot.sessionGeneration, snapshot.frameID <= lastFrame.frameID { return }
        lastFrame = (snapshot.sessionGeneration, snapshot.frameID)
        let frameJoints = joints.flatMap { $0.matches(snapshot) ? $0 : nil }
        for player in Array(robots.keys) {
            guard var robot = robots[player] else { continue }
            let sample = frameJoints?.players[player].flatMap {
                $0.calibrationRevision == robot.retargeter.reference?.calibrationRevision ? $0 : nil
            }
            robot.retargeter.update(sample: snapshot.players[player], joints: sample, time: snapshot.capturedAt)
            robots[player] = robot
            apply(player, time: snapshot.capturedAt)
        }
    }
    #endif

    private func apply(_ player: PlayerID, time: Double) {
        if smoothing == nil { present(player, k: 1, time: time) }
    }

    /// Re-plants every foot under its robot (after switching modes).
    private func resetFeet() {
        for (player, robot) in robots {
            robots[player]?.planner = RobotFootPlanner(rest: robot.planner.rest)
        }
        plantAnchor = [:]
    }

    /// Moves what each robot shows toward its latest target (render loop).
    func render(now: Double) {
        guard let smoothing else { return }
        let dt = lastRender.map { max(0, now - $0) } ?? smoothing * 10
        lastRender = now
        let k = Float(1 - exp(-dt / max(smoothing, 1e-4)))
        for player in robots.keys { present(player, k: k, time: now) }
    }

    /// Shows one robot: the render-smoothed pose, with its feet from the
    /// planner. Pelvis and feet read the same smoothed values in the same
    /// frame, so they can never move at different times.
    private func present(_ player: PlayerID, k: Float, time: Double) {
        guard var robot = robots[player] else { return }
        let r = robot.retargeter
        var s = shown[player] ?? Shown(targets: r.targets, lift: r.lift, sway: r.sway, footDelta: r.footDelta)
        s.targets = s.targets.blended(toward: r.targets, k: k)
        s.lift += (r.lift - s.lift) * k
        s.sway += (r.sway - s.sway) * k
        var delta: [RobotPoseTargets.Side: Float] = [:]
        for (side, to) in r.footDelta { delta[side] = (s.footDelta[side] ?? to) + (to - (s.footDelta[side] ?? to)) * k }
        s.footDelta = delta
        shown[player] = s

        var t = s.targets
        let scale = Self.modelScale
        var rootX = s.sway
        var plan: RobotFootPlanner.Output?
        if footPlanting {
            var input = RobotFootPlanner.Input(pelvisX: s.sway, rootLift: s.lift, time: time)
            input.footDelta = s.footDelta
            input.trackedLift = t.footLift.mapValues { $0 * scale }
            input.available = r.isAvailable
            let out = robot.planner.update(input)
            robots[player] = robot
            rootX += out.pelvisShift
            for side in RobotPoseTargets.Side.allCases {
                // Board X → model space under the moved root: the IK keeps the foot there.
                t.footShift[side] = ((out.footX[side] ?? rootX) - rootX) / scale - (robot.bindAnkleX[side] ?? 0)
                // The tracked knee lift and the step arc are one movement: show the larger, never both.
                t.footLift[side] = max(t.footLift[side] ?? 0, (out.footHeight[side] ?? 0) / scale)
            }
            t.pelvisDrop += out.pelvisDip / scale
            plan = out
        }
        robot.container.position = [rootX, s.lift, 0]
        // After smoothing and foot planning, just before the solve: presentation targets only.
        if Self.headClearance { MascotPoseEnvelope.apply(to: &t) }
        let solved = robot.solver.solveDetailed(t)
        robot.model.jointTransforms = solved.local
        if diagnosticsEnabled { recordFeet(player, robot, solved, rootX: rootX, lift: s.lift, plan: plan, trackedLift: t.footLift) }
        #if DEBUG
        if showsFairnessMarkers { updateFairnessMarkers(player) }
        #endif
        // Dimmed exactly while the player is not tracked (the pose itself fades separately).
        let opacity = r.isAvailable ? 1 : Self.unavailableOpacity
        if robot.container.components[OpacityComponent.self]?.opacity != opacity {
            robot.container.components.set(OpacityComponent(opacity: opacity))
        }
    }

    private func recordFeet(_ player: PlayerID, _ robot: Robot, _ solved: (local: [Transform], reachShortfall: [RobotPoseTargets.Side: Float]),
                            rootX: Float, lift: Float, plan: RobotFootPlanner.Output?, trackedLift: [RobotPoseTargets.Side: Float]) {
        let scale = Self.modelScale
        let world = robot.solver.skeleton.world(solved.local).position
        var d = footDiagnostics[player] ?? FootDiagnostics()
        let previous = d.contact
        d.pelvisX = rootX
        d.trackedDelta = robot.retargeter.footDelta
        d.ankleConfidence = robot.retargeter.ankleConfidence
        d.reachShortfall = solved.reachShortfall.mapValues { $0 * scale }
        var anchors = plantAnchor[player] ?? [:]
        for (side, name) in [(RobotPoseTargets.Side.left, "Foot_L"), (.right, "Foot_R")] {
            guard let i = robot.solver.skeleton(name) else { continue }
            let x = rootX + world[i].x * scale
            d.actualX[side] = x
            d.height[side] = lift + (world[i].y - robot.bindAnkleY) * scale
            d.targetX[side] = plan?.footX[side] ?? x
            let foot = robot.planner.feet[side]
            // Planted: planner says so, or (earlier behaviour) the robot is on the deck and that foot is not raised.
            let planted = footPlanting ? foot?.contact == .planted
                : lift < RobotFootPlanner.landingLift && (trackedLift[side] ?? 0) * scale < RobotFootPlanner.liftThreshold
            d.contact[side] = footPlanting ? foot?.contact : (planted ? .planted : .airborne)
            d.reason[side] = footPlanting ? foot?.reason : RobotFootPlanner.Reason.none
            if planted {
                let anchor = anchors[side] ?? x
                anchors[side] = anchor
                d.plantedDrift[side] = max(d.plantedDrift[side] ?? 0, abs(x - anchor))
            } else {
                anchors[side] = nil
                d.plantedDrift[side] = 0
            }
            if footPlanting, foot?.contact == .stepping, previous[side] != .stepping { d.steps[side, default: 0] += 1 }
        }
        plantAnchor[player] = anchors
        footDiagnostics[player] = d
    }

    /// Removes every avatar entity and the avatars' lights, and shows the
    /// pictograms again. Safe to call more than once.
    func remove() {
        for (player, robot) in robots {
            robot.container.removeFromParent()
            scene?.players[player]?.hasMascot = false
        }
        #if DEBUG
        for marker in fairnessMarkers.values.flatMap({ $0 }) { marker.removeFromParent() }
        fairnessMarkers = [:]
        #endif
        robots = [:]
        shown = [:]
        footDiagnostics = [:]
        plantAnchor = [:]
        lights.removeFromParent()
    }
}
