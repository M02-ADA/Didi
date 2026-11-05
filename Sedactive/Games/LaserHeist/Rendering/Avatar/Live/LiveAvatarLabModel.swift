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
    @ObservationIgnored private let logsStats = ProcessInfo.processInfo.arguments.contains("-liveAvatarLabLog")

    // MARK: - Scene

    func install(on content: RealityViewCameraContent) async {
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        scene.isLaserVisible = false
        content.add(scene.root)
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
        for player in PlayerID.allCases {
            scene.players[player]?.isEnabled = mode.players.contains(player)
        }
    }

    // MARK: - Camera lifecycle

    func start() async {
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

        layer?.apply(out.snapshot, joints: out.joints)
        let applied = CameraHostClock.now()
        appliedAt = applied
        captureToAvatar.add(applied - frame.capturedAt)
        updateStatus(out.snapshot)
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
        guard let appliedAt else { return }
        avatarToRender.add(CameraHostClock.now() - appliedAt)
        self.appliedAt = nil
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
        ]
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("live-avatar-lab-stats.json"),
              let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }
}
#endif
