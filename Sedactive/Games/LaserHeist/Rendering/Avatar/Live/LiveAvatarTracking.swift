//
//  LiveAvatarTracking.swift
//  Sedactive
//

#if DEBUG
import Foundation

// Live Avatar Lab logic (Debug only, presentation only). Turns Vision joints
// into the avatar's inputs: a presentation-only `BodySnapshot` estimate plus
// `PresentationPoseFrame` joints, which feed the robot's retargeting
// (`RobotRetargeter`). These estimates never reach Jevon's game or judgement,
// and they are not Edo's production body producer.
//
// Coordinates. Vision joints are in the upright, UNMIRRORED camera image
// (normalized, origin bottom-left, y up). The person faces the camera, so
// their own right side appears on the image's left. Conversion to the CP1
// player plane keeps that unmirrored X (`ImageToPlayerPlaneMapping.gameX`);
// the avatar presentation reflects X exactly once (lane-local `L − x`, the
// same transform as the live cutout). Net effect: the player's right is the
// screen's right, and their right arm drives the avatar's right arm, which
// in this rear view is also on screen right. Anatomical labels are never swapped.

nonisolated enum LiveAvatarMode: String, CaseIterable, Sendable {
    case single, two
    var players: [PlayerID] { self == .single ? [.player1] : PlayerID.allCases }
}

nonisolated extension LivePerson {
    /// Hip centre (Vision's root, else the hips' midpoint).
    var center: LivePoint? {
        if let root = point(.root) { return root }
        guard let l = point(.leftHip), let r = point(.rightHip) else { return nil }
        return LivePoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2, confidence: min(l.confidence, r.confidence))
    }

    /// Vertical extent of the detected joints (image heights): bigger is closer or more complete.
    var extent: Double {
        let ys = joints.values.filter { $0.confidence >= 0.3 }.map(\.y)
        guard let lo = ys.min(), let hi = ys.max() else { return 0 }
        return hi - lo
    }
}

// MARK: - Identity

/// Keeps P1 and P2 bound to the same people while they move. A player keeps
/// their slot by continuity (nearest previous position), never by re-sorting
/// on screen position each frame, so crossing or overlapping does not swap
/// them. Slots are first assigned left/right on screen: P1 is displayed-left,
/// which is image-right in the unmirrored camera image.
nonisolated struct LiveIdentity: Equatable, Sendable {
    /// Furthest a player can move between frames and keep their slot (aspect-corrected image heights).
    static let gate = 0.3
    /// A slot unseen this long is released for re-acquisition.
    static let expiry = 1.0

    var mode: LiveAvatarMode
    private(set) var tracks: [PlayerID: (x: Double, y: Double, seen: Double)] = [:]

    init(mode: LiveAvatarMode) { self.mode = mode }

    static func == (a: Self, b: Self) -> Bool { a.mode == b.mode && a.tracks.keys == b.tracks.keys }

    mutating func reset() { tracks = [:] }

    mutating func assign(_ people: [LivePerson], at time: Double, aspect: Double) -> [PlayerID: LivePerson] {
        tracks = tracks.filter { time - $0.value.seen <= Self.expiry && mode.players.contains($0.key) }
        var free = people.indices.filter { people[$0].center != nil }
        var result: [PlayerID: LivePerson] = [:]
        func distance(_ i: Int, _ t: (x: Double, y: Double, seen: Double)) -> Double {
            let c = people[i].center!
            return hypot((c.x - t.x) * aspect, c.y - t.y)
        }
        // Tracked players keep the nearest person within the gate, closest pairs first.
        let pairs = tracks.flatMap { player, track in free.map { (player, $0, distance($0, track)) } }
            .filter { $0.2 <= Self.gate }.sorted { $0.2 < $1.2 }
        for (player, index, _) in pairs where result[player] == nil && free.contains(index) {
            result[player] = people[index]
            free.removeAll { $0 == index }
        }
        // Untracked slots: in two-player mode left-to-right on screen; alone, the most complete person.
        let open = mode.players.filter { result[$0] == nil && tracks[$0] == nil }
        if mode == .two, open.count == 2 {
            let ordered = free.sorted { people[$0].center!.x > people[$1].center!.x }  // image-right = screen-left
            for (player, index) in zip(open, ordered) { result[player] = people[index] }
            free.removeAll { ordered.prefix(2).contains($0) }
        } else {
            for player in open {
                guard let best = free.max(by: { people[$0].extent < people[$1].extent }) else { break }
                result[player] = people[best]
                free.removeAll { $0 == best }
            }
        }
        for (player, person) in result {
            let c = person.center!
            tracks[player] = (c.x, c.y, time)
        }
        return result
    }
}

// MARK: - Calibration

/// Standing measurements of one person in one frame (image heights).
nonisolated struct LiveStance: Equatable, Sendable {
    let noseY: Double, neckY: Double, shoulderY: Double
    let leftAnkleY: Double, rightAnkleY: Double
    let centerX: Double, centerY: Double

    /// `nil` with the reason a standing calibration cannot use this person.
    static func measure(_ person: LivePerson) -> Result<LiveStance, LiveCalibrationIssue> {
        let c = 0.4
        guard let nose = person.point(.nose, minimumConfidence: c), let neck = person.point(.neck, minimumConfidence: c)
        else { return .failure(.headNotVisible) }
        // Ankles at the same confidence live tracking uses: Vision rates feet lower than the head.
        let feet = LiveSampleBuilder.minimumConfidence
        guard let la = person.point(.leftAnkle, minimumConfidence: feet), let ra = person.point(.rightAnkle, minimumConfidence: feet)
        else { return .failure(.feetNotVisible) }
        guard let center = person.center else { return .failure(.bodyNotVisible) }
        let shoulders = [person.point(.leftShoulder), person.point(.rightShoulder)].compactMap { $0 }
        let shoulderY = shoulders.count == 2 ? (shoulders[0].y + shoulders[1].y) / 2 : neck.y
        return .success(LiveStance(noseY: nose.y, neckY: neck.y, shoulderY: shoulderY, leftAnkleY: la.y, rightAnkleY: ra.y,
                                   centerX: center.x, centerY: center.y))
    }
}

nonisolated enum LiveCalibrationIssue: String, Error, Sendable {
    case notDetected = "No person detected"
    case headNotVisible = "Head not visible"
    case feetNotVisible = "Feet not visible: step back so your whole body is in view"
    case bodyNotVisible = "Hips not visible"
    case moving = "Hold still"
    case tooCloseToEdge = "Too close to the top or bottom edge: step back"
    case timedOut = "Could not get a steady full-body view"
}

/// Standing calibration: hold still with the whole body visible for
/// `window` seconds. Produces a fresh `PlayerCalibration` (new revision) per
/// player; nothing from an earlier player or session is reused.
nonisolated struct LiveCalibrator: Sendable {
    static let window = 1.2
    static let minimumFrames = 12
    /// Largest allowed spread of neck and ankle heights while holding still (image heights).
    static let steadiness = 0.03
    static let timeout = 10.0
    /// Distance from nose to crown and ankle to sole, as shares of nose-to-ankle height (anthropometric estimates).
    static let crownAboveNose = 0.10
    static let soleBelowAnkle = 0.04

    let players: [PlayerID]
    let startedAt: Double
    private(set) var samples: [PlayerID: [(time: Double, stance: LiveStance)]] = [:]
    private(set) var issue: [PlayerID: LiveCalibrationIssue] = [:]

    init(players: [PlayerID], at time: Double) {
        self.players = players
        startedAt = time
    }

    var progress: Double {
        players.map { min(1, Double(steadySpan($0)) / Self.window) }.min() ?? 0
    }

    var timedOut: Bool = false

    /// Adds one frame; returns the calibrations once every player has a steady window.
    mutating func add(_ assigned: [PlayerID: LivePerson], frame: LiveBodyFrame) -> [PlayerID: LiveStance]? {
        if frame.capturedAt - startedAt > Self.timeout { timedOut = true; return nil }
        for player in players {
            guard let person = assigned[player] else { issue[player] = .notDetected; samples[player] = []; continue }
            switch LiveStance.measure(person) {
            case .failure(let reason): issue[player] = reason; samples[player] = []
            case .success(let stance):
                var list = (samples[player] ?? []) + [(frame.capturedAt, stance)]
                list = list.filter { frame.capturedAt - $0.time <= Self.window + 0.2 }
                let necks = list.map(\.stance.neckY), ankles = list.map { ($0.stance.leftAnkleY + $0.stance.rightAnkleY) / 2 }
                if (necks.max()! - necks.min()!) > Self.steadiness || (ankles.max()! - ankles.min()!) > Self.steadiness {
                    issue[player] = .moving
                    list = [list.last!]
                } else {
                    issue[player] = nil
                }
                samples[player] = list
            }
        }
        guard players.allSatisfy({ steadySpan($0) >= Self.window && (samples[$0]?.count ?? 0) >= Self.minimumFrames }) else { return nil }
        return Dictionary(uniqueKeysWithValues: players.map { ($0, Self.median(samples[$0]!.map(\.stance))) })
    }

    private func steadySpan(_ player: PlayerID) -> Double {
        guard let list = samples[player], let first = list.first, let last = list.last else { return 0 }
        return last.time - first.time
    }

    static func median(_ stances: [LiveStance]) -> LiveStance {
        func m(_ k: KeyPath<LiveStance, Double>) -> Double {
            let v = stances.map { $0[keyPath: k] }.sorted()
            return v[v.count / 2]
        }
        return LiveStance(noseY: m(\.noseY), neckY: m(\.neckY), shoulderY: m(\.shoulderY), leftAnkleY: m(\.leftAnkleY),
                          rightAnkleY: m(\.rightAnkleY), centerX: m(\.centerX), centerY: m(\.centerY))
    }

    /// A CP1-shaped standing calibration from a steady stance (validated).
    static func calibration(_ player: PlayerID, _ s: LiveStance, generation: UUID, revision: UInt64,
                            cameraGeometryRevision: UInt64, frame: LiveBodyFrame) throws -> PlayerCalibration {
        let span = s.noseY - min(s.leftAnkleY, s.rightAnkleY)
        guard span > 0.1 else { throw LiveCalibrationIssue.tooCloseToEdge }
        let crown = s.noseY + crownAboveNose * span
        let foot = soleBelowAnkle * span
        let left = s.leftAnkleY - foot, right = s.rightAnkleY - foot
        guard crown < 0.995, min(left, right) > 0.005 else { throw LiveCalibrationIssue.tooCloseToEdge }
        let height = crown - min(left, right)
        let calibration = PlayerCalibration(
            playerID: player, sessionGeneration: generation, revision: revision,
            cameraGeometryRevision: cameraGeometryRevision, sourceFrameID: frame.frameID, capturedAt: frame.capturedAt,
            standingCrownImageY: crown, standingLeftSoleImageY: left, standingRightSoleImageY: right,
            standingHipImageY: s.centerY, standingBodyImageHeight: height,
            standingTorsoImageLength: max(0.01, s.shoulderY - s.centerY),
            headOffsetFromNoseShare: (crown - s.noseY) / height,
            leftFootOffsetShare: foot / height, rightFootOffsetShare: foot / height,
            mapping: ImageToPlayerPlaneMapping(imageAspectRatio: frame.imageAspect, floorImageY: min(left, right),
                                               originImageX: s.centerX))
        try calibration.validate()
        return calibration
    }
}

// MARK: - Per-frame samples

/// One player's live sample builder: Vision joints → CP1-shaped
/// presentation estimate plus player-plane joints. Keeps only the jump
/// hysteresis between frames.
nonisolated struct LiveSampleBuilder: Sendable {
    /// A jump starts when both soles are this share of standing height above
    /// the floor and ends below the lower share, so camera noise and rising
    /// onto the toes never read as a jump.
    static let jumpEnterShare = 0.06
    static let jumpExitShare = 0.03
    static let minimumConfidence = 0.3

    let calibration: PlayerCalibration
    let layout: PlayerPlaneLayout
    private(set) var airborne = false

    init(calibration: PlayerCalibration, layout: PlayerPlaneLayout) {
        self.calibration = calibration
        self.layout = layout
    }

    var standingHeight: Double { calibration.standingBodyImageHeight * layout.gameUnitsPerImageHeight }

    func gameY(_ imageY: Double) -> Double { calibration.mapping.gameY(imageY: imageY, layout: layout) }
    func gameX(_ imageX: Double) -> Double {
        calibration.mapping.gameX(imageX: imageX, playerID: calibration.playerID, layout: layout)
    }

    mutating func sample(_ person: LivePerson?) throws -> (PlayerBodySample, PresentationPoseSample?) {
        let id = calibration.playerID
        let none = try EstimatedScalar(value: nil, validity: .missingLandmarks)
        guard let person, let center = person.point(.root) ?? person.center,
              person.point(.neck, minimumConfidence: Self.minimumConfidence) != nil else {
            airborne = false
            let lost = try EstimatedScalar(value: nil, validity: .outOfFrame)
            return (PlayerBodySample(playerID: id, calibrationRevision: calibration.revision, trackingStatus: .lost,
                                     geometry: BodyGeometry(crownY: lost, leftWristY: lost, rightWristY: lost,
                                                            leftSoleY: lost, rightSoleY: lost, centerX: lost),
                                     jumpState: JumpState(phase: .unknown, validity: .outOfFrame)), nil)
        }
        let height = calibration.standingBodyImageHeight
        func value(_ v: Double?) throws -> EstimatedScalar {
            guard let v else { return none }
            return try EstimatedScalar(value: v, validity: .valid)
        }
        let c = Self.minimumConfidence
        let crown = person.point(.nose, minimumConfidence: c).map { gameY($0.y + calibration.headOffsetFromNoseShare * height) }
        let leftSole = person.point(.leftAnkle, minimumConfidence: c).map { gameY($0.y - calibration.leftFootOffsetShare * height) }
        let rightSole = person.point(.rightAnkle, minimumConfidence: c).map { gameY($0.y - calibration.rightFootOffsetShare * height) }
        let jump: JumpState
        if let leftSole, let rightSole {
            let lift = min(leftSole, rightSole)
            airborne = airborne ? lift > Self.jumpExitShare * standingHeight : lift > Self.jumpEnterShare * standingHeight
            jump = JumpState(phase: airborne ? .airborne : .grounded, validity: .valid)
        } else {
            airborne = false
            jump = JumpState(phase: .unknown, validity: .missingLandmarks)
        }
        let sample = PlayerBodySample(
            playerID: id, calibrationRevision: calibration.revision, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: try value(crown),
                                   leftWristY: try value(person.point(.leftWrist, minimumConfidence: c).map { gameY($0.y) }),
                                   rightWristY: try value(person.point(.rightWrist, minimumConfidence: c).map { gameY($0.y) }),
                                   leftSoleY: try value(leftSole), rightSoleY: try value(rightSole),
                                   centerX: try value(gameX(center.x))),
            jumpState: jump)
        var points: [PresentationJoint: PresentationPoint] = [:]
        for (live, joint) in Self.presentationJoints {
            guard let p = person.point(live, minimumConfidence: c) else { continue }
            points[joint] = PresentationPoint(x: gameX(p.x), y: gameY(p.y), confidence: p.confidence)
        }
        return (sample, PresentationPoseSample(playerID: id, calibrationRevision: calibration.revision, joints: points))
    }

    static let presentationJoints: [(LiveJoint, PresentationJoint)] = [
        (.nose, .nose), (.leftEar, .leftEar), (.rightEar, .rightEar), (.neck, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder), (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist), (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee), (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]
}

// MARK: - Frames

/// Live frame gate and assembly: newest frames only, identity, per-player samples.
nonisolated struct LiveAvatarTracker: Sendable {
    /// Frames older than this when they reach the avatar are dropped, never shown.
    static let maximumAge = 0.25
    /// Standing P1 height in game units (meters on screen); P2 shares the scale, so relative heights stay true.
    static let referenceHeight = 1.6

    let sessionGeneration: UUID
    private(set) var identity: LiveIdentity
    private(set) var calibrations: [PlayerID: PlayerCalibration] = [:]
    private(set) var layout = PlayerPlaneLayout(leftCenterX: -0.65, rightCenterX: 0.65, gameUnitsPerImageHeight: 2)
    private var builders: [PlayerID: LiveSampleBuilder] = [:]
    private var revision: UInt64 = 0
    private(set) var lastFrameID: UInt64?
    private(set) var staleDrops = 0
    private(set) var orderDrops = 0

    init(sessionGeneration: UUID, mode: LiveAvatarMode) {
        self.sessionGeneration = sessionGeneration
        identity = LiveIdentity(mode: mode)
    }

    var mode: LiveAvatarMode { identity.mode }

    /// A new camera session restarts frame IDs at 1 (Edo's `FrameStore.begin`),
    /// so the order gate and identity tracks start over; calibrations are kept.
    mutating func beginCameraSession() {
        lastFrameID = nil
        identity.reset()
    }

    mutating func setMode(_ mode: LiveAvatarMode) {
        identity = LiveIdentity(mode: mode)
        calibrations = calibrations.filter { mode.players.contains($0.key) }
        builders = builders.filter { mode.players.contains($0.key) }
    }

    /// Installs fresh calibrations from steady stances (new revisions). The
    /// shared scale is set so P1 (or the first player calibrated) stands
    /// `referenceHeight` tall.
    mutating func calibrate(_ stances: [PlayerID: LiveStance], frame: LiveBodyFrame) throws {
        var made: [PlayerID: PlayerCalibration] = [:]
        for player in PlayerID.allCases {
            guard let stance = stances[player] else { continue }
            revision += 1
            made[player] = try LiveCalibrator.calibration(player, stance, generation: sessionGeneration, revision: revision,
                                                          cameraGeometryRevision: frame.cameraGeometryRevision, frame: frame)
        }
        let reference = made[.player1] ?? made[.player2] ?? calibrations[.player1]
        if let reference {
            layout = PlayerPlaneLayout(leftCenterX: -0.65, rightCenterX: 0.65,
                                       gameUnitsPerImageHeight: Self.referenceHeight / reference.standingBodyImageHeight)
        }
        calibrations.merge(made) { $1 }
        builders = calibrations.mapValues { LiveSampleBuilder(calibration: $0, layout: layout) }
    }

    /// `nil` when the frame is a duplicate, out of order, or stale.
    mutating func process(_ frame: LiveBodyFrame, now: Double)
        -> (snapshot: BodySnapshot, joints: PresentationPoseFrame, assigned: [PlayerID: LivePerson])?
    {
        if let lastFrameID, frame.frameID <= lastFrameID { orderDrops += 1; return nil }
        lastFrameID = frame.frameID
        if now - frame.capturedAt > Self.maximumAge { staleDrops += 1; return nil }
        let assigned = identity.assign(frame.people, at: frame.capturedAt, aspect: frame.imageAspect)
        var samples: [PlayerID: PlayerBodySample] = [:]
        var joints: [PlayerID: PresentationPoseSample] = [:]
        for player in PlayerID.allCases {
            if var builder = builders[player], let made = try? builder.sample(assigned[player]) {
                builders[player] = builder
                samples[player] = made.0
                joints[player] = made.1
            } else if let missing = try? EstimatedScalar(value: nil, validity: .notCalibrated) {
                samples[player] = PlayerBodySample(
                    playerID: player, calibrationRevision: nil, trackingStatus: assigned[player] == nil ? .lost : .uncertain,
                    geometry: BodyGeometry(crownY: missing, leftWristY: missing, rightWristY: missing,
                                           leftSoleY: missing, rightSoleY: missing, centerX: missing),
                    jumpState: JumpState(phase: .unknown, validity: .notCalibrated))
            }
        }
        let snapshot = BodySnapshot(sessionGeneration: sessionGeneration, frameID: frame.frameID, capturedAt: frame.capturedAt,
                                    cameraGeometryRevision: frame.cameraGeometryRevision, players: samples)
        return (snapshot, PresentationPoseFrame(sessionGeneration: sessionGeneration, frameID: frame.frameID,
                                                capturedAt: frame.capturedAt, players: joints), assigned)
    }

    func airborne(_ player: PlayerID) -> Bool { builders[player]?.airborne ?? false }
}
#endif
