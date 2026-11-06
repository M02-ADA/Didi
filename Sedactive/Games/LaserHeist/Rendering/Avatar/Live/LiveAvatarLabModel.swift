//
//  LiveAvatarLabModel.swift
//  Sedactive
//

#if DEBUG
import Foundation
import Observation
import RealityKit
import SwiftUI

/// Debug-only Live Avatar Lab: the iPad's front camera drives the rear-view
/// 3D robots in the corridor, with no LaserHeist round, no lasers and no
/// gameplay. Presentation only.
///
/// Pipeline: Edo's `CameraPipeline` (owned here, started and stopped with the
/// lab) → `LivePoseSink` (Vision, off the main actor, newest result only) →
/// `LiveAvatarTracker` (stale/out-of-order drop, identity, calibration,
/// presentation estimates) → `RobotAvatarLayer` (3D human-to-robot
/// retargeting on the robot's skeleton).
/// Every avatar movement comes from a camera frame; there are no timers.
@MainActor @Observable
final class LiveAvatarLabModel {
    struct PlayerStatus: Equatable {
        var tracked = false
        var calibrated = false
        var move = "—"
        var crouchCM = 0
        var liftCM = 0
        var leftArm = 0
        var rightArm = 0
        var lean = 0
        /// Jump detector readout: feet validity, lift vs threshold, noise, phase.
        var jump = ""
        /// Foot planting readout (`RobotAvatarLayer.FootDiagnostics.line`).
        var feet = ""
    }

    /// Rolling latency samples in seconds.
    struct Window {
        private(set) var values: [Double] = []
        mutating func add(_ v: Double) {
            guard v.isFinite, v >= 0 else { return }
            values.append(v)
            if values.count > 120 { values.removeFirst(values.count - 120) }
        }
        func percentile(_ p: Double) -> Int? {
            guard !values.isEmpty else { return nil }
            let s = values.sorted()
            return Int((s[min(s.count - 1, Int(Double(s.count - 1) * p))] * 1000).rounded())
        }
    }

    private(set) var mode: LiveAvatarMode = .single
    private(set) var cameraStatus = "Stopped"
    private(set) var calibrationText = "Not calibrated"
    private(set) var calibrationProgress = 0.0
    private(set) var players: [PlayerID: PlayerStatus] = [.player1: .init(), .player2: .init()]
    private(set) var people: [(player: PlayerID?, person: LivePerson)] = []
    private(set) var visionFPS = 0.0
    private(set) var framesProcessed = 0
    private(set) var captureToVision = Window()
    private(set) var captureToAvatar = Window()
    private(set) var avatarToRender = Window()
    private(set) var staleDrops = 0
    private(set) var orderDrops = 0
    private(set) var cameraDrops: UInt64 = 0
    private(set) var cameraSuperseded: UInt64 = 0
    private(set) var lastCalibrationIssue = "none"
    /// Feet diagnostics for the most prominent person: ankle confidences and
    /// the lowest detected joint's height in the image (0 = bottom edge).
    private(set) var feet = "—"
    @ObservationIgnored private var feetStats = (frames: 0, anklesSeen: 0, lowestSum: 0.0)

    // MARK: Live round state (observable summaries only)
    private(set) var roundActive = false
    private(set) var roundText = ""
    private(set) var nextTargetText = ""
    private(set) var reportLines: [String] = []
    @ObservationIgnored private var round: LiveGameSession?
    @ObservationIgnored private var presenter: GameplayScenePresenter?
    @ObservationIgnored private var lastGeometryRevision: UInt64 = 1
    /// The robot's pose per player and frame, to compare with what the checker judged.
    /// `-liveGame [solo|coop]`: start a round as soon as the needed players are calibrated.
    @ObservationIgnored private var autoStartRound: Bool = ProcessInfo.processInfo.arguments.contains("-liveGame")
    /// `-liveGameSynthetic`: a SYNTHETIC scripted player instead of the camera (Simulator checks only).
    @ObservationIgnored let usesSyntheticPlayer = ProcessInfo.processInfo.arguments.contains("-liveGameSynthetic")
    @ObservationIgnored private var synthetic: [PlayerID: LiveSyntheticPlayer] = [:]
    @ObservationIgnored private var syntheticFrame: UInt64 = 0
    @ObservationIgnored private var lastSyntheticEmit = 0.0

    @ObservationIgnored let scene = LaserScene()
    @ObservationIgnored private var template: Entity?
    @ObservationIgnored private var layer: RobotAvatarLayer?
    @ObservationIgnored private var pipeline: CameraPipeline?
    @ObservationIgnored private var sink: LivePoseSink?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var tracker = LiveAvatarTracker(sessionGeneration: UUID(), mode: .single)
    @ObservationIgnored private var calibrator: LiveCalibrator?
    @ObservationIgnored private var appliedAt: Double?
    @ObservationIgnored private var fpsWindow: [Double] = []
    @ObservationIgnored private var renderSubscription: EventSubscription?
    @ObservationIgnored private var lastLog = 0.0
    /// Counts, timings and verdict lines only (no images or joints); on by default
    /// in the lab so a device session leaves data to tune from (`-noLabLog` turns it off).
    @ObservationIgnored private let logsStats = !ProcessInfo.processInfo.arguments.contains("-noLabLog")
    /// Jump detection rule in use: "tuned" (default) or "original" (`-jumpTuning original`).
    private(set) var jumpTuning: LiveJumpTuning = {
        let arguments = ProcessInfo.processInfo.arguments
        return LiveJumpTuning.named(arguments.firstIndex(of: "-jumpTuning").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil })
    }()
    /// Per player and frame: what the evidence and the robot showed, to classify verdicts.
    @ObservationIgnored private var frameLog: [PlayerID: [FrameNote]] = [:]
    @ObservationIgnored private var roundStart = 0.0
    @ObservationIgnored private var jumpsDetected: [PlayerID: Int] = [:]
    @ObservationIgnored private var wasAirborne: [PlayerID: Bool] = [:]

    struct FrameNote {
        let frameID: UInt64
        /// Capture time in round game time.
        let time: Double
        let top: Double?
        let sole: Double?
        let airborne: Bool
        let robotLiftCM: Int
        let robotCrouchCM: Int
    }

    // MARK: - Scene

    func install(on content: RealityViewCameraContent) async {
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        scene.installLaserArtwork(await LaserScene.loadLaserGateArtwork())
        scene.isLaserVisible = false
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-liveGame"),
           index + 1 < ProcessInfo.processInfo.arguments.count, ProcessInfo.processInfo.arguments[index + 1] == "coop" {
            setMode(.two)
        }
        content.add(scene.root)
        tracker.setJumpTuning(jumpTuning)
        template = await RobotAvatarLayer.loadTemplate()
        if template == nil { cameraStatus = "Robot asset failed to load" }
        renderSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.rendered()
        }
        rebuildRigs()
    }

    /// Robots for calibrated players; until then, P1 (and P2 in two-player mode)
    /// stand in the bind pose, dimmed, from a placeholder calibration that nothing drives.
    private func rebuildRigs() {
        layer?.remove()
        guard let template else { return }
        var calibrations = tracker.calibrations
        var layout = tracker.layout
        if calibrations.isEmpty, let input = try? LaserReplayScript.load().input {
            calibrations = input.configuration.calibrations.filter { mode.players.contains($0.key) }
            layout = input.configuration.playerPlaneLayout
        }
        layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: layout, template: template)
        // 30 Hz camera poses shown smoothly at render rate; 30 ms keeps the lag to about one camera frame.
        layer?.smoothing = 0.03
        layer?.footPlanting = footPlanting
        layer?.diagnosticsEnabled = true
        for player in PlayerID.allCases {
            scene.players[player]?.isEnabled = mode.players.contains(player)
        }
    }

    // MARK: - Camera lifecycle

    func start() async {
        if usesSyntheticPlayer {
            startSyntheticPlayer()
            return
        }
        guard pipeline == nil else { return }
        let sink = LivePoseSink()
        let pipeline = CameraPipeline(sink: sink)
        self.sink = sink
        self.pipeline = pipeline
        observerToken = try? pipeline.observe { [weak self] state in self?.cameraChanged(state.status) }
        consumer = Task { [weak self] in
            for await frame in sink.results {
                guard let self, !Task.isCancelled else { break }
                self.handle(frame)
            }
        }
        // Frame IDs restart at 1 with every camera session.
        tracker.beginCameraSession()
        layer?.resetFrameOrder()
        if tracker.calibrations.isEmpty { beginCalibration() }
        do {
            try await pipeline.start(generation: UUID())
        } catch {
            // Release the failed pipeline so the next start (e.g. after granting permission) can retry.
            let message = Self.describe(error)
            if self.pipeline === pipeline { await stop() }
            cameraStatus = message
            if logsStats { writeStats() }
        }
    }

    /// Camera failures in words that say what to do next.
    static func describe(_ error: Error) -> String {
        switch error as? CameraFailure {
        case .permissionDenied?: "Camera permission denied: allow it in Settings › Privacy › Camera, then reopen the lab"
        case .permissionRestricted?: "Camera restricted on this device (Screen Time or device management)"
        case let failure?: "Camera failed to start: \(failure)"
        case nil: "Camera failed to start: \(error)"
        }
    }

    func stop() async {
        // A camera restart restarts frame IDs: the round cannot continue across it.
        if roundActive && !usesSyntheticPlayer { stopRound(reason: "camera stopped") }
        consumer?.cancel()
        consumer = nil
        sink?.finish()
        if let token = observerToken { pipeline?.removeObserver(token) }
        observerToken = nil
        await pipeline?.stop()
        pipeline = nil
        sink = nil
        cameraStatus = "Stopped"
    }

    func close() async {
        stopRound(reason: "lab closed")
        await stop()
        renderSubscription?.cancel()
        renderSubscription = nil
        layer?.remove()
        layer = nil
    }

    private func cameraChanged(_ status: CameraPipelineStatus) {
        cameraStatus = switch status {
        case .stopped: "Stopped"
        case .requestingPermission: "Waiting for camera permission"
        case .configuring: "Starting camera"
        case .running: "Running"
        case .interrupted(let reason): "Interrupted (\(reason.map(String.init) ?? "unknown"))"
        case .failed(let failure): Self.describe(failure)
        }
        if logsStats { writeStats() }
    }

    // MARK: - Mode and calibration

    func setMode(_ mode: LiveAvatarMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        tracker.setMode(mode)
        rebuildRigs()
        beginCalibration()
    }

    func beginCalibration() {
        calibrator = LiveCalibrator(players: mode.players, at: CameraHostClock.now())
        calibrationProgress = 0
        calibrationText = mode == .single
            ? "Calibrating P1: stand facing the iPad, whole body in view, hold still"
            : "Calibrating P1 (screen left) and P2 (screen right): both stand still, whole body in view"
    }

    // MARK: - Frames

    private func handle(_ frame: LiveBodyFrame) {
        let now = CameraHostClock.now()
        fpsWindow.append(now)
        fpsWindow.removeAll { now - $0 > 2 }
        visionFPS = fpsWindow.count > 1 ? Double(fpsWindow.count - 1) / (fpsWindow.last! - fpsWindow.first!) : 0
        captureToVision.add(frame.visionCompletedAt - frame.capturedAt)
        if let pipeline {
            let d = pipeline.frames.diagnostics
            cameraDrops = d.avDrops + d.capacityDrops + d.constructionDrops + d.budgetDrops + d.staleDrops
            cameraSuperseded = d.superseded
        }
        lastGeometryRevision = frame.cameraGeometryRevision
        guard let out = tracker.process(frame, now: now) else {
            staleDrops = tracker.staleDrops
            orderDrops = tracker.orderDrops
            return
        }
        framesProcessed += 1
        people = frame.people.map { person in (out.assigned.first { $0.value == person }?.key, person) }
        if let person = frame.people.max(by: { $0.extent < $1.extent }) {
            let l = person.joints[.leftAnkle]?.confidence ?? 0, r = person.joints[.rightAnkle]?.confidence ?? 0
            let lowest = person.joints.values.filter { $0.confidence >= 0.1 }.map(\.y).min() ?? 0
            let knees = max(person.joints[.leftKnee]?.confidence ?? 0, person.joints[.rightKnee]?.confidence ?? 0)
            feet = String(format: "ankles L %.2f R %.2f · knees %.2f · lowest joint y %.2f%@", l, r, knees, lowest,
                          lowest < 0.03 ? " (at bottom edge: feet cut off)" : "")
            feetStats.frames += 1
            if min(l, r) >= LiveSampleBuilder.minimumConfidence { feetStats.anklesSeen += 1 }
            feetStats.lowestSum += lowest
        }

        if var calibrator {
            if let stances = calibrator.add(out.assigned, frame: frame) {
                do {
                    try tracker.calibrate(stances, frame: frame)
                    self.calibrator = nil
                    calibrationText = "Calibrated \(mode.players.map { $0 == .player1 ? "P1" : "P2" }.joined(separator: " + "))"
                    rebuildRigs()
                } catch {
                    calibrationText = "Calibration failed: \((error as? LiveCalibrationIssue)?.rawValue ?? "\(error)")"
                    self.calibrator = LiveCalibrator(players: mode.players, at: now)
                }
            } else if calibrator.timedOut {
                // Keep trying until it succeeds; say why the last window failed.
                let reason = mode.players.compactMap { calibrator.issue[$0]?.rawValue }.first ?? LiveCalibrationIssue.timedOut.rawValue
                lastCalibrationIssue = reason
                calibrationText = "Still calibrating: \(reason)"
                self.calibrator = LiveCalibrator(players: mode.players, at: now)
            } else {
                self.calibrator = calibrator
                calibrationProgress = calibrator.progress
                let issues = mode.players.compactMap { p in calibrator.issue[p].map { "\(p == .player1 ? "P1" : "P2"): \($0.rawValue)" } }
                if !issues.isEmpty {
                    calibrationText = issues.joined(separator: " · ")
                    lastCalibrationIssue = issues.joined(separator: " · ")
                }
            }
        }

        // One frame, two consumers: the robot (presentation) and the authoritative checker.
        layer?.apply(out.snapshot, joints: out.joints)
        let applied = CameraHostClock.now()
        appliedAt = applied
        captureToAvatar.add(applied - frame.capturedAt)
        updateStatus(out.snapshot)
        for player in PlayerID.allCases where tracker.airborne(player) != (wasAirborne[player] ?? false) {
            wasAirborne[player] = tracker.airborne(player)
            if tracker.airborne(player) { jumpsDetected[player, default: 0] += 1 }
        }
        if roundActive {
            round?.receive(out.snapshot, now: applied)
            for (player, status) in players where status.calibrated {
                let g = out.snapshot.players[player]?.geometry
                let top = [g?.crownY.value, g?.leftWristY.value, g?.rightWristY.value].compactMap { $0 }.max()
                let sole = g?.leftSoleY.value.flatMap { l in g?.rightSoleY.value.map { min(l, $0) } }
                var log = frameLog[player, default: []]
                log.append(FrameNote(frameID: out.snapshot.frameID, time: out.snapshot.capturedAt - roundStart, top: top, sole: sole,
                                     airborne: out.snapshot.players[player]?.jumpState.phase == .airborne,
                                     robotLiftCM: status.liftCM, robotCrouchCM: status.crouchCM))
                if log.count > 300 { log.removeFirst(log.count - 300) }
                frameLog[player] = log
            }
        }
        if autoStartRound, !roundActive, mode.players.allSatisfy({ tracker.calibrations[$0] != nil }) {
            autoStartRound = false
            startRound()
        }
        if logsStats, applied - lastLog > 2 { writeStats(); lastLog = applied }
    }

    private func updateStatus(_ snapshot: BodySnapshot) {
        let degree = Float.pi / 180
        for player in PlayerID.allCases {
            var s = PlayerStatus()
            s.calibrated = tracker.calibrations[player] != nil
            let sample = snapshot.players[player]
            s.tracked = sample?.trackingStatus == .reliable && s.calibrated
            if let robot = layer?.robots[player], s.calibrated {
                let r = robot.retargeter, scale = robot.container.scale.y
                /// Arm elevation from hanging: 0° down, 90° out to the side, 180° overhead.
                func raise(_ d: SIMD3<Float>?, outward: Float) -> Int {
                    guard let d else { return 0 }
                    return Int((atan2(outward * d.x, -d.y) / degree).rounded())
                }
                s.liftCM = Int((r.lift * 100).rounded())
                s.crouchCM = Int((r.targets.pelvisDrop * scale * 100).rounded())
                s.leftArm = raise(r.targets.upperArm[.left], outward: -1)
                s.rightArm = raise(r.targets.upperArm[.right], outward: 1)
                s.lean = Int((r.targets.lean / degree).rounded())
                s.feet = layer?.footDiagnostics[player]?.line ?? ""
                if let jump = tracker.jumpDetector(player), let calibration = tracker.calibrations[player] {
                    let standing = calibration.standingBodyImageHeight * tracker.layout.gameUnitsPerImageHeight
                    let g = sample?.geometry
                    func ok(_ v: EstimatedScalar?) -> String { v?.validity == .valid ? "✓" : "✗" }
                    s.jump = String(format: "feet L%@ R%@ · lift %@ / need %.1f cm · noise %.1f · %@ · jumps %d (%@)",
                                    ok(g?.leftSoleY), ok(g?.rightSoleY),
                                    jump.lift.map { String(format: "%.1f", $0 * 100) } ?? "—",
                                    jump.enterThreshold(standing: standing) * 100, jump.noise * 100,
                                    jump.airborne ? "AIRBORNE" : "grounded", jumpsDetected[player, default: 0], jumpTuning.name)
                }
                s.move = !r.isAvailable ? "unavailable: \(Self.unavailableReason(sample))"
                    : tracker.airborne(player) ? "JUMP (airborne)" : s.crouchCM >= 4 ? "DUCK" : "standing"
            }
            players[player] = s
        }
    }

    /// Why a calibrated player's robot is not following them (from the frame's own sample).
    static func unavailableReason(_ sample: PlayerBodySample?) -> String {
        guard let sample else { return "no sample" }
        switch sample.trackingStatus {
        case .lost: return "not detected"
        case .uncertain: return "body not clear (neck or hips missing)"
        case .reliable: break
        }
        if sample.calibrationRevision == nil { return "not calibrated" }
        if sample.jumpState.validity != .valid { return "feet not visible" }
        return "waiting for data"
    }

    private func rendered() {
        if usesSyntheticPlayer { emitSyntheticFrame() }
        layer?.render(now: CameraHostClock.now())
        tickRound()
        guard let appliedAt else { return }
        avatarToRender.add(CameraHostClock.now() - appliedAt)
        self.appliedAt = nil
    }

    // MARK: - Live round (real LaserHeist rules)

    var canStartRound: Bool { mode.players.allSatisfy { tracker.calibrations[$0] != nil } && !roundActive }

    /// Starts a real round on the existing corridor: Jevon's director schedules the
    /// lasers from the live calibrations, `LaserGame` judges the live evidence, and the
    /// existing presenter renders travel, gates, cues and CLEAR/HIT feedback.
    func startRound() {
        guard canStartRound else { return }
        do {
            let session = try LiveGameSession(
                mode: mode == .single ? .solo : .cooperative, calibrations: tracker.calibrations, layout: tracker.layout,
                sessionGeneration: tracker.sessionGeneration, cameraGeometryRevision: lastGeometryRevision,
                startTime: CameraHostClock.now())
            // `roundStart` (below) matches the session's clock anchor to within a millisecond.
            presenter?.stop()
            presenter = GameplayScenePresenter(scene: scene, configuration: session.configuration,
                                               encounters: session.encounters, showsDebugMarkers: false)
            round = session
            roundStart = CameraHostClock.now()
            roundActive = true
            reportLines = []
            frameLog = [:]
            tickRound()
        } catch {
            roundText = "Round could not start: \(error)"
        }
    }

    func stopRound(reason: String = "stopped") {
        guard roundActive, var round else { return }
        round.stop()
        presenter?.apply(state: round.state, events: round.events, snapshot: round.latestSnapshot)
        presenter?.stop()
        presenter = nil
        self.round = nil
        roundActive = false
        roundText = "Round \(reason). Tap Start round to play again."
        nextTargetText = ""
    }

    /// Advances the round to now on the render loop and presents its state.
    private func tickRound() {
        guard roundActive, var round else { return }
        round.advance(to: CameraHostClock.now())
        presenter?.apply(state: round.state, events: round.events, snapshot: round.latestSnapshot)
        let newReports = round.reports.dropFirst(reportLines.count)
        for report in newReports { reportLines.append(describe(report)) }
        self.round = round
        let state = round.state
        let label = round.mode == .solo ? "SOLO SMOKE TEST (P2 absent: UNAVAILABLE, no team effects)" : "CO-OP ROUND"
        let judged = state.encounters.filter(\.effectsCommitted).count
        roundText = String(format: "%@ · t %.1f s · %d/%d lasers · health %d · score %d%@", label, state.gameTime, judged,
                           state.encounters.count, state.teamHealth, state.teamScore,
                           round.rejectedFrames > 0 ? " · rejected frames \(round.rejectedFrames)" : "")
        let upcoming = state.encounters.flatMap(\.encounter.targets).filter { $0.playerID == .player1 && $0.crossingTime >= state.gameTime }
            .min { $0.crossingTime < $1.crossingTime }
        nextTargetText = upcoming.map { t in
            String(format: "next P1: %@ in %.1f s · must be %@ %.2f", t.requiredMove == .duck ? "DUCK" : "JUMP",
                   t.crossingTime - state.gameTime, t.requiredMove == .duck ? "below" : "above",
                   t.requiredMove == .duck ? t.beam.lowerY - round.configuration.clearanceMargin
                                           : t.beam.upperY + round.configuration.clearanceMargin)
        } ?? (round.isFinished ? "All lasers judged. Tap Start round to play again." : "")
        if round.isFinished {
            roundActive = false
            presenter?.stop()
            presenter = nil
            self.round = nil
            nextTargetText = "All lasers judged. Tap Start round to play again."
        }
    }

    /// One line per judged target: verdict, the checker's measurement against its
    /// threshold, which frame it used and how far from the crossing, and what the
    /// robot showed for that same frame.
    private func describe(_ r: LiveCrossingReport) -> String {
        let who = r.playerID == .player1 ? "P1" : "P2"
        let move = r.move == .duck ? "DUCK" : "JUMP"
        let verdict: String = switch r.judgement {
        case .clear: "CLEAR"
        case .hit(let reason): "HIT (\(reason))"
        case .unavailable(let reason): "UNAVAILABLE (\(reason))"
        case .pending: "pending"
        }
        var line = String(format: "%@ %@ @%.1fs: %@", who, move, r.crossingTime, verdict)
        let cause = Self.classify(r, frames: frameLog[r.playerID] ?? [])
        if !cause.isEmpty { line += " → " + cause }
        if let measured = r.measured {
            line += String(format: " · body %.2f %@ %.2f", measured, r.move == .duck ? "vs <" : "vs >", r.threshold)
            if r.move == .jump { line += r.airborne == true ? " airborne" : " NOT airborne" }
        }
        if let frame = r.frameID, let offset = r.captureOffset, let delay = r.arrivalDelay {
            line += String(format: " · frame %llu %+.2fs, age %.2fs", frame, offset, delay)
            if let note = frameLog[r.playerID]?.first(where: { $0.frameID == frame }) {
                line += " · robot lift \(note.robotLiftCM) cm, crouch \(note.robotCrouchCM) cm"
            }
        }
        return line
    }

    /// Why a target was not CLEAR (or why a CLEAR looked wrong), from this
    /// player's own frames around the crossing:
    /// TRACKING (no usable evidence), TIMING (the move happened, not at the
    /// crossing), DETECTION (feet were up but no jump was recognized),
    /// CLEARANCE (recognized but not high/low enough), NO MOVE, and
    /// PRESENTATION (judged CLEAR but the robot barely showed it).
    static func classify(_ r: LiveCrossingReport, frames: [FrameNote]) -> String {
        let near = frames.filter { abs($0.time - r.crossingTime) <= 0.6 }
        switch r.judgement {
        case .pending: return ""
        case .unavailable: return "TRACKING"
        case .clear:
            if let note = frames.first(where: { $0.frameID == r.frameID }) {
                if r.move == .jump, note.robotLiftCM < 2 { return "PRESENTATION: robot lift \(note.robotLiftCM) cm" }
                if r.move == .duck, note.robotCrouchCM < 3 { return "PRESENTATION: robot crouch \(note.robotCrouchCM) cm" }
            }
            return ""
        case .hit:
            switch r.move {
            case .duck:
                if let low = near.first(where: { ($0.top ?? .infinity) < r.threshold }) {
                    return String(format: "TIMING: low enough at %+.2fs from crossing", low.time - r.crossingTime)
                }
                return (r.measured ?? 0) < r.threshold + 0.1 ? "CLEARANCE: not quite low enough" : "NO MOVE: no duck seen"
            case .jump:
                if let up = near.first(where: { $0.airborne && ($0.sole ?? 0) > r.threshold }) {
                    return String(format: "TIMING: airborne at %+.2fs from crossing", up.time - r.crossingTime)
                }
                if near.contains(where: \.airborne) { return "CLEARANCE: jump recognized but feet not above the beam" }
                if near.contains(where: { ($0.sole ?? 0) > r.threshold }) { return "DETECTION: feet were up but no jump recognized" }
                return "NO MOVE: no jump seen"
            }
        }
    }

    /// Planted feet and stepping (default) or the earlier root-only motion, to
    /// compare on the device (`-legacyFeet` starts with the earlier one).
    private(set) var footPlanting = !ProcessInfo.processInfo.arguments.contains("-legacyFeet")

    func setFootPlanting(_ on: Bool) {
        footPlanting = on
        layer?.footPlanting = on
    }

    /// Compares jump rules on the same device without rebuilding.
    func setJumpTuning(_ tuning: LiveJumpTuning) {
        guard tuning != jumpTuning else { return }
        jumpTuning = tuning
        tracker.setJumpTuning(tuning)
        jumpsDetected = [:]
    }

    // MARK: - Synthetic player (Simulator checks only)

    private func startSyntheticPlayer() {
        guard synthetic.isEmpty else { return }
        cameraStatus = "SYNTHETIC scripted player (no camera; Simulator check)"
        synthetic[.player1] = LiveSyntheticPlayer(body: LiveSyntheticBody(cx: mode == .single ? 0.5 : 0.68), missEvery: 4)
        if mode == .two { synthetic[.player2] = LiveSyntheticPlayer(body: LiveSyntheticBody(cx: 0.32, h: 0.7), missEvery: 3) }
        autoStartRound = true
        if tracker.calibrations.isEmpty { beginCalibration() }
    }

    /// One synthetic frame per 1/30 s of host time, captured 30 ms before it is processed.
    private func emitSyntheticFrame() {
        let now = CameraHostClock.now()
        guard !synthetic.isEmpty, now - lastSyntheticEmit >= 1.0 / 30 else { return }
        lastSyntheticEmit = now
        let time = round?.gameTime ?? -1
        let people = PlayerID.allCases.compactMap { player -> LivePerson? in
            guard let script = synthetic[player] else { return nil }
            let targets = round?.encounters.flatMap(\.targets).filter { $0.playerID == player } ?? []
            return script.body(at: time, targets: targets).person(aspect: 16.0 / 9)
        }
        syntheticFrame += 1
        handle(LiveBodyFrame(frameID: syntheticFrame, capturedAt: now - 0.03, visionCompletedAt: now - 0.005,
                             imageAspect: 16.0 / 9, cameraGeometryRevision: 1, people: people))
    }


    /// Debug `-liveAvatarLabLog`: counts and timings only (no images, no joints), for checking a device run.
    private func writeStats() {
        let stats: [String: Any] = [
            "camera": cameraStatus, "mode": mode.rawValue, "calibration": calibrationText,
            "lastCalibrationIssue": lastCalibrationIssue,
            "feetLastFrame": feet,
            "framesWithBothAnklesConfident": feetStats.anklesSeen, "framesWithAPerson": feetStats.frames,
            "meanLowestJointY": feetStats.frames > 0 ? feetStats.lowestSum / Double(feetStats.frames) : -1,
            "framesProcessed": framesProcessed, "visionFPS": visionFPS, "peopleInLastFrame": people.count,
            "trackedPlayers": players.filter { $0.value.tracked }.map { $0.key.rawValue },
            "captureToVisionMS_p50": captureToVision.percentile(0.5) ?? -1,
            "captureToAvatarMS_p50": captureToAvatar.percentile(0.5) ?? -1,
            "captureToAvatarMS_p95": captureToAvatar.percentile(0.95) ?? -1,
            "avatarToRenderMS_p50": avatarToRender.percentile(0.5) ?? -1,
            "staleDrops": staleDrops, "orderDrops": orderDrops, "cameraDrops": cameraDrops,
            "round": roundText, "crossingReports": reportLines,
            "jumpTuning": jumpTuning.name, "jumpReadout": players.mapValues(\.jump).reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value },
            "footPlanting": footPlanting, "feetReadout": players.mapValues(\.feet).reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value },
        ]
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("live-avatar-lab-stats.json"),
              let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }
}
#endif
