//
//  RobotAvatar.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit
import simd

/// Human-to-robot retargeting for one player, from CP1's `PlayerBodySample`
/// plus, when supplied, PROPOSED player-plane joints (`PresentationPoseSample`),
/// against that player's `AvatarReference`. Presentation only; nothing here is
/// a hit shape, and nothing here is fed back to judgement.
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
    /// The robot's hip-to-ankle height at rest (metres, model space).
    let robotLegRest: Float
    /// The player's standing reference (game units), from `AvatarPoseAdapter`.
    let reference: AvatarReference
    /// Robot metres per metre of this player's motion (shared robot height / player's standing height).
    let motionScale: Float
    var maximumSway: Float = 0.3
    var maximumLean: Float = 0.35
    var maximumHeadRoll: Float = 0.4
    /// Crouch below this share of standing leg length is camera noise; a soft
    /// zone, so leaving it never steps the pelvis.
    var crouchDeadband: Float = 0.03
    /// Foot lift below this share of standing height is ankle noise (soft zone).
    var liftDeadband: Float = 0.02
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
    private var liftSeen: Double?
    private var lastPresent: Double?
    /// Fast derivative tracking so takeoff is followed within about a frame,
    /// while standing jitter (slow) is still smoothed at 3 Hz.
    private var liftFilter: OneEuroFilter = {
        var f = OneEuroFilter(minimumCutoff: 3, beta: 6)
        f.derivativeCutoff = 4
        return f
    }()
    private var lastTime: Double?
    private var filters: [PresentationJoint: (x: OneEuroFilter, y: OneEuroFilter)] = [:]
    /// When each joint was last seen; a joint back after a gap restarts its filter.
    private var seen: [PresentationJoint: Double] = [:]
    /// When each arm last had evidence; an arm without it for `armHold` returns to the bind pose.
    private var armSeen: [RobotPoseTargets.Side: Double] = [:]
    static let jointGap = 0.3
    static let armHold = 0.5
    /// Longest projected length seen per segment (player-plane units), for foreshortening depth.
    private var longest: [String: Double] = [:]

    init(reference: AvatarReference, robotLegRest: Float, robotHeight: Float = RobotAvatarLayer.standingHeight) {
        self.reference = reference
        self.robotLegRest = robotLegRest
        let standing = Float(reference.standingHeight)
        motionScale = standing > 0 ? robotHeight / standing : 1
    }

    /// Through the temporary CP1 adapter (`AvatarReference(calibration:layout:)`).
    init(calibration: PlayerCalibration, layout: PlayerPlaneLayout, robotLegRest: Float,
         robotHeight: Float = RobotAvatarLayer.standingHeight) {
        self.init(reference: AvatarReference(calibration: calibration, layout: layout),
                  robotLegRest: robotLegRest, robotHeight: robotHeight)
    }

    /// Hip-centre drop, as a share of standing height, that bends the legs fully
    /// in the CP1-only crouch estimate (about the leg's share of height).
    static let crownCrouchShare: Float = 0.45

    mutating func update(sample: PlayerBodySample?, joints: PresentationPoseSample?, time: Double) {
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        // Presentation needs a reliable, calibrated player; the feet may be briefly
        // missing (the legs and lift hold, then settle). The checker's stricter
        // evidence rules are separate and unchanged.
        guard let sample, sample.playerID == reference.playerID, sample.trackingStatus == .reliable,
              sample.calibrationRevision == reference.calibrationRevision
        else { return relax(dt, time: time) }
        isAvailable = true
        lastPresent = time
        let g = sample.geometry
        let standing = Float(reference.standingHeight)

        // JUMP: the lower sole, continuously (not only once the jump phase flips), through
        // a soft noise zone and a fast adaptive filter: takeoff starts with the feet.
        if let left = g.leftSoleY.value, let right = g.rightSoleY.value {
            let raw = Float(max(0, min(left, right)))
            measuredLift = liftFilter.filter(Self.softZone(raw, liftDeadband * standing), dt: dt) * motionScale
            liftSeen = time
        } else if time - (liftSeen ?? time) > Self.liftHold {
            measuredLift *= Float(exp(-dt / Self.relaxTime))
        }
        // LATERAL: hip centre, mirrored once about the lane (as `GameWorldMapping.cutoutPoint`).
        if g.centerX.validity == .valid, let x = g.centerX.value {
            let step = Float(reference.laneCenterX - x) * motionScale
            measuredSway = min(maximumSway, max(-maximumSway, step))
        }
        defer { compose(dt: dt, present: true) }

        // Filtered joints (1€: smooth when still, fast when moving).
        var p: [PresentationJoint: SIMD2<Double>] = [:]
        for (joint, point) in joints?.joints ?? [:] where point.confidence >= 0.3 {
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

        // ARMS: shoulder→elbow and elbow→wrist directions per anatomical side.
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

        // DUCK and knee raise: each leg's hip-to-ankle height as a share of standing, onto the robot's leg.
        if let lh = p[.leftHip], let rh = p[.rightHip] {
            let hipY = (lh.y + rh.y) / 2
            let hip0 = reference.standingHipY
            var reach: [RobotPoseTargets.Side: Float] = [:]
            for (side, ankle) in [(RobotPoseTargets.Side.left, PresentationJoint.leftAnkle), (.right, .rightAnkle)] {
                guard let a = p[ankle] else { continue }
                let standing = hip0 - reference.standingAnkleY(side)
                guard standing > 0 else { continue }
                let share = Float((hipY - a.y) / standing)
                let bend = Self.softZone(max(0, 1 - share), crouchDeadband)
                reach[side] = robotLegRest * min(1, max(0.45, 1 - bend))
            }
            if let longest = reach.values.max() {
                measured.pelvisDrop = robotLegRest - longest
                for side in RobotPoseTargets.Side.allCases { measured.footLift[side] = longest - (reach[side] ?? longest) }
            }
        } else if joints == nil, let crown = g.crownY.value, standing > 0 {
            // CP1 only (no joints, e.g. the replay): the crown's drop below standing,
            // as a share of the leg, bends both legs. A presentation estimate: a
            // head-only duck also lowers the avatar. Never used for judgement.
            let drop = Self.softZone(max(0, 1 - Float(crown) / standing), crouchDeadband) / Self.crownCrouchShare
            measured.pelvisDrop = robotLegRest - robotLegRest * min(1, max(0.45, 1 - drop))
            for side in RobotPoseTargets.Side.allCases { measured.footLift[side] = 0 }
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
                ankleConfidence[side] = Float(joints?.joints[joint]?.confidence ?? 0)
            }
        }

        // LEAN: shoulders over hips. HEAD: the ear line.
        if let ls = p[.leftShoulder], let rs = p[.rightShoulder], let lh = p[.leftHip], let rh = p[.rightHip] {
            let d = (ls + rs) / 2 - (lh + rh) / 2
            measured.lean = min(maximumLean, max(-maximumLean, Float(atan2(-d.x, d.y))))
        }
        if let le = p[.leftEar], let re = p[.rightEar] {
            let roll = Float(atan2(re.y - le.y, -(re.x - le.x)))
            measured.headRoll = min(maximumHeadRoll, max(-maximumHeadRoll, roll + measured.lean))
        }
    }

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
        for side in RobotPoseTargets.Side.allCases {
            t.footLift[side] = (measured.footLift[side] ?? 0) * w
            t.armWeight[side] = (measured.upperArm[side] == nil ? 0 : armWeights[side, default: 0]) * w
        }
        targets = t
    }

    /// Continuous soft dead zone: 0 below noise, a smooth ramp, then x − zone/2.
    static func softZone(_ x: Float, _ zone: Float) -> Float {
        guard zone > 0, x < zone else { return x - zone / 2 }
        return x > 0 ? x * x / (2 * zone) : 0
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
    var footPlanting = !ProcessInfo.processInfo.arguments.contains("-legacyFeet") {
        didSet { if footPlanting != oldValue { resetFeet() } }
    }
    /// Collect `footDiagnostics` (one extra forward pass per robot per frame).
    var diagnosticsEnabled = false
    private(set) var footDiagnostics: [PlayerID: FootDiagnostics] = [:]
    private var plantAnchor: [PlayerID: [RobotPoseTargets.Side: Float]] = [:]
    private weak var scene: LaserScene?
    private let lights = Entity()
    private(set) var lastFrame: (generation: UUID, frameID: UInt64)?
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

    /// `templates` from `loadTemplates()`: each player with a reference gets a
    /// clone of its own colour variant, standing on that player's existing
    /// `PlayerCutoutEntity` (its lane); one solver setup, size and lighting
    /// for every player. Players without a reference get no avatar.
    init(scene: LaserScene, references: [PlayerID: AvatarReference], templates: [PlayerID: Entity]) {
        self.scene = scene
        for player in PlayerID.allCases {
            guard let entity = scene.players[player], let reference = references[player],
                  let template = templates[player] else { continue }
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
            entity.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled = false
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

    /// A new camera session restarts frame IDs; forget the last one shown.
    func resetFrameOrder() { lastFrame = nil }

    /// Shows one body frame; `joints` only when it belongs to the same frame.
    func apply(_ snapshot: BodySnapshot, joints: PresentationPoseFrame? = nil) {
        if let lastFrame, lastFrame.generation == snapshot.sessionGeneration, snapshot.frameID <= lastFrame.frameID { return }
        lastFrame = (snapshot.sessionGeneration, snapshot.frameID)
        let frameJoints = joints.flatMap { $0.matches(snapshot) ? $0 : nil }
        for player in Array(robots.keys) {
            guard var robot = robots[player] else { continue }
            let sample = frameJoints?.players[player].flatMap {
                $0.calibrationRevision == robot.retargeter.reference.calibrationRevision ? $0 : nil
            }
            robot.retargeter.update(sample: snapshot.players[player], joints: sample, time: snapshot.capturedAt)
            robots[player] = robot
            apply(player, time: snapshot.capturedAt)
        }
    }

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
            scene?.players[player]?.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled = true
        }
        robots = [:]
        shown = [:]
        footDiagnostics = [:]
        plantAnchor = [:]
        lights.removeFromParent()
    }
}
