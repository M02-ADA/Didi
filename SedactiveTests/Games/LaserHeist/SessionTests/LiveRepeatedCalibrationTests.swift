import Foundation
import CoreVideo
import Synchronization
import Testing
@testable import Sedactive

/// Calibration → round end → Play Again, repeated in one app session, on the REAL retained
/// composition: one `CameraPipeline`, its tracking gate, one `BodyInputService`, the flow and a
/// fresh automatic coordinator per game. Camera frames are the controlled driver's; poses and
/// masks are the standing fixtures, committed through the same gate calls `CameraCopySink` makes,
/// with ONE motion engine retained across sessions exactly as the worker retains it.
///
/// The gate keeps real host time (as on the iPad), so calibration takes its real 1.5 s prompt plus
/// 10 samples 0.25 s apart. As in the app, frames arrive off the main actor (the feeder plays the
/// worker) while the setup ticks run on it, so a busy main actor delays ticks, never frames.
@MainActor
@Suite(.serialized)
struct LiveRepeatedCalibrationTests {
    /// The camera worker's role: one frame at a time through the gate, on its own task.
    nonisolated final class FrameFeeder: Sendable {
        enum Mode: Sendable { case pair, player1Only, player2Only, soloCentered, nobody, paused }
        /// Head-top offset (image heights) for a player's n-th calibration sample of the session:
        /// estimator jitter as the iPad showed it (18 November 2026), on an otherwise still body.
        typealias Jitter = @Sendable (_ sample: Int, _ player: PlayerID) -> Double
        private struct State {
            var context: CameraSourceContext?
            var mode = Mode.pair
            var fps = 30.0
            var maskService = 0.01
            var engine: MotionEngine
            var frameID: UInt64 = 0
            var stepped = 0
            /// Calibration samples taken (frames whose mask the gate admitted), per camera source.
            var samples = 0
            var samplesContext: CameraSourceContext?
            var jitter: Jitter?
            /// Whole-body offset (head-top and both soles) per sample: a real step.
            var step: Jitter?
            /// Someone else in view besides the players (a bystander), every frame.
            var bystander: PoseCandidate?
            var lastEvidence: (CameraPoseResult, CameraTrackingAdmission, PlayerTrackingSnapshot)?
        }
        private let state: Mutex<State>
        private let gate: CameraTrackingGate
        private let running = Mutex(false)

        init(gate: CameraTrackingGate) throws {
            self.gate = gate
            state = Mutex(State(engine: try MotionEngine(policy: B2bExperimentalPolicyV1.value)))
        }
        /// Its own thread, like the camera's callback queue: a busy test runner's task pool cannot
        /// hold frames back past the tracking freshness.
        func start() {
            running.withLock { $0 = true }
            let thread = Thread { [self] in
                while running.withLock({ $0 }) {
                    try? step()
                    Thread.sleep(forTimeInterval: 1 / state.withLock { $0.fps })
                }
            }
            thread.qualityOfService = .userInitiated // the camera callback queue's QoS
            thread.start()
        }
        func stop() { running.withLock { $0 = false } }
        func set(context: CameraSourceContext?) { state.withLock { $0.context = context } }
        func set(mode: Mode) { state.withLock { $0.mode = mode } }
        func set(fps: Double) { state.withLock { $0.fps = fps } }
        func set(maskService: Double) { state.withLock { $0.maskService = maskService } }
        func set(jitter: Jitter?) { state.withLock { $0.jitter = jitter } }
        func set(step: Jitter?) { state.withLock { $0.step = step } }
        func set(bystander: PoseCandidate?) { state.withLock { $0.bystander = bystander } }
        var lastEvidence: (CameraPoseResult, CameraTrackingAdmission, PlayerTrackingSnapshot)? {
            state.withLock { $0.lastEvidence }
        }
        /// Frames delivered so far (the camera rate the test runner actually allowed).
        var stepped: Int { state.withLock { $0.stepped } }

        /// A standing fixture body moved sideways by `dx` (normalized image X).
        static func shifted(_ c: PoseCandidate, by dx: Double, id: UInt64? = nil, keep: Set<BodyJoint>? = nil) -> PoseCandidate {
            var joints: [BodyJoint: PoseJoint] = [:]
            // Joints moved past the image edge are out of frame: Vision reports none for them.
            for (joint, p) in c.joints where keep?.contains(joint) ?? true && (0.005...0.995).contains(p.x + dx) {
                joints[joint] = .init(x: p.x + dx, y: p.y, confidence: p.confidence)
            }
            return .init(candidateID: id ?? c.candidateID, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        /// A bystander at torso X `x`: a whole standing body, or (partial) only shoulders and arms
        /// at the image edge, as a person half out of frame shows.
        static func bystander(atX x: Double, partial: Bool = false) -> PoseCandidate {
            let model = LiveVisionFixtures.standingPair.first { $0.candidateID == 10 }!
            let center = PlayerAcquisitionZones.torsoCenterX(model)!
            return shifted(model, by: x - center, id: 30,
                keep: partial ? [.leftShoulder, .rightShoulder, .leftWrist, .rightWrist, .nose] : nil)
        }

        private static func pose(_ id: UInt64, candidates: [PoseCandidate], context: CameraSourceContext) throws -> CameraPoseResult {
            let time = CameraHostClock.now() - 0.005
            let metadata = CameraFrameMetadata(context: context, frameID: id, capturedAt: time,
                descriptor: try CameraFrameDescriptor(width: 1280, height: 720, bytesPerRow: 5120,
                    pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 4 * 1024 * 1024),
                rotationAngle: 180, mirrored: false)
            let frame = PoseFrame(sessionGeneration: context.generation, frameID: id, capturedAt: time,
                cameraGeometryRevision: context.geometryRevision, imageWidth: 1280, imageHeight: 720,
                candidates: candidates)
            return .init(source: metadata, frame: frame, observationCount: candidates.count, invalidJointCount: 0)
        }

        /// `CameraCopySink.consume` for one frame: synchronize, pose, track, CP1, optional mask.
        private func step() throws {
            let (context, mode, service, bystander) = state.withLock { ($0.context, $0.mode, $0.maskService, $0.bystander) }
            guard let context, mode != .paused else { return }
            state.withLock { $0.stepped += 1 }
            var engine = state.withLock { $0.engine }
            var frameID = state.withLock { $0.frameID }
            defer { state.withLock { $0.engine = engine; $0.frameID = frameID } }
            gate.synchronize { control in
                var staged = engine
                let snapshot = try staged.synchronize(control)
                engine = staged
                return snapshot
            }
            frameID += 1
            // The mask fixture gives P1 candidate 10 and P2 candidate 20.
            var candidates: [PoseCandidate] = switch mode {
            case .pair: LiveVisionFixtures.standingPair
            case .player1Only: LiveVisionFixtures.standingPair.filter { $0.candidateID == 10 }
            case .player2Only: LiveVisionFixtures.standingPair.filter { $0.candidateID == 20 }
            case .soloCentered: [Self.shifted(LiveVisionFixtures.standingPair.first { $0.candidateID == 10 }!, by: -0.25)]
            case .nobody, .paused: []
            }
            if let bystander, mode != .paused { candidates.append(bystander) }
            let pose = try Self.pose(frameID, candidates: candidates, context: context)
            guard let admission = gate.admit(pose.source), admission.requestID != nil else { return }
            let staged = try engine.staged(pose, admission: admission)
            guard gate.finish(staged, admission: admission, source: pose.source, mutualCoreCount: 4,
                              commit: { engine = staged }),
                  let receipt = gate.snapshot.latest else { return }
            gate.publishBody(pose, admission: admission, receipt: receipt)
            state.withLock { $0.lastEvidence = (pose, admission, receipt) }
            guard gate.beginMask(pose: pose, admission: admission, receipt: receipt) else { return }
            let (sample, jitter, step) = state.withLock { s -> (Int, Jitter?, Jitter?) in
                if s.samplesContext != context { s.samplesContext = context; s.samples = 0 }
                s.samples += 1
                return (s.samples - 1, s.jitter, s.step)
            }
            var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose, service: service),
                                                      pose: pose, revision: admission.revision)
            for (id, a) in mask.anatomy {
                let head = jitter?(sample, id) ?? 0, body = step?(sample, id) ?? 0
                guard head != 0 || body != 0, let crown = a.crown.imageY, let left = a.leftSole.imageY,
                      let right = a.rightSole.imageY else { continue }
                mask.anatomy[id] = .init(source: a.source, controlRevision: a.controlRevision, candidateID: a.candidateID,
                    crown: .init(imageY: crown + head + body, status: .experimental),
                    leftSole: .init(imageY: left + body, status: .experimental),
                    rightSole: .init(imageY: right + body, status: .experimental))
            }
            gate.finishMask(mask, pose: pose, admission: admission, receipt: receipt)
        }
    }

    @MainActor final class Rig {
        let driver = ControlledCameraDriver()
        let camera: CameraPipeline
        let provider: BodyInputService
        let flow: LaserInputFlow
        let feeder: FrameFeeder
        /// What the camera shows by default: both players, or P1 alone in a Solo session.
        let defaultMode: FrameFeeder.Mode
        /// The longest gap between two setup ticks in the last `run` (main-actor starvation).
        private(set) var longestTickGap = 0.0

        init(solo: Bool = false) throws {
            defaultMode = solo ? .soloCentered : .pair
            camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
            let provider = BodyInputService(camera: camera)
            self.provider = provider
            feeder = try FrameFeeder(gate: camera.frames.tracking)
            flow = LaserInputFlow(makeLiveSession: {
                var configuration = LiveVisionFixtures.configuration(UUID())
                if solo { configuration.soloPlayer = .player1 } // the DEBUG Solo session's configuration
                let layout = configuration.playerPlaneLayout
                let roster = configuration.roster
                return GameSessionCoordinator(provider: provider, inputConfiguration: configuration,
                    setupControls: LaserLiveSetupControls(service: provider),
                    liveRoundPlanner: { context, calibrations in
                        try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
                            layout: layout, seed: 7, segmentLength: 60, roster: roster)
                    }, automaticSetup: true, automaticSetupTimer: false)
            })
            feeder.set(mode: defaultMode)
            feeder.start()
        }
        deinit { feeder.stop() }

        /// Setup ticks (about 30 a second, like the app's 100 ms timer, only faster) until `done`
        /// holds or `seconds` pass, with the camera showing `mode`; returns the seconds taken.
        @discardableResult
        func run(_ session: GameSessionCoordinator, seconds: Double, mode: FrameFeeder.Mode? = nil,
                 until done: () -> Bool = { false }) async throws -> Double {
            feeder.set(mode: mode ?? defaultMode)
            defer { feeder.set(mode: defaultMode) }
            let start = CameraHostClock.now()
            var lastTick = start
            longestTickGap = 0
            while CameraHostClock.now() - start < seconds {
                let tick = CameraHostClock.now()
                longestTickGap = max(longestTickGap, tick - lastTick); lastTick = tick
                feeder.set(context: camera.state.context)
                session.advanceSetupAutomatically()
                if done() { return CameraHostClock.now() - start }
                try await Task.sleep(for: .milliseconds(33))
            }
            return seconds
        }

        /// Until both standing references are accepted and the round is planned; nil when it
        /// did not finish. A runner too busy to deliver real-time frames and ticks (the gate keeps
        /// real host time) makes the result inconclusive, reported as an intermittent known issue.
        @discardableResult
        func calibrate(_ session: GameSessionCoordinator, fps: Double = 30, within seconds: Double = 12) async throws -> Double? {
            feeder.set(fps: fps)
            defer { feeder.set(fps: 30) }
            let frames = feeder.stepped
            let taken = try await run(session, seconds: seconds) {
                session.setup?.phase == .awaitingGameplayReadiness && session.hasLiveRoundPlan
            }
            guard taken >= seconds else { return taken }
            session.advanceSetupAutomatically() // report the current state, not the last tick's
            let rate = Double(feeder.stepped - frames) / taken
            let message = """
                calibration did not finish (session \(session.inputConfiguration.sessionGeneration.uuidString.prefix(8))): \
                setup \(String(describing: session.setup?.phase)), \
                session \(session.phase), attempts \(session.presence.attempts), progress \
                \(provider.calibrationProgress.phase) \(provider.calibrationProgress.sampleCount)/10 · \
                \(provider.calibrationProgress.reason) · camera \(String(format: "%.1f", rate)) fps of \(fps), \
                longest tick gap \(String(format: "%.2f", longestTickGap)) s
                """
            if rate < fps / 2 || longestTickGap > 1 {
                withKnownIssue("test runner starved the real-time frames or ticks", isIntermittent: true) {
                    Issue.record(Comment(rawValue: message))
                }
            } else {
                Issue.record(Comment(rawValue: message))
            }
            return nil
        }

        /// Gameplay then Results, driven as the scene drives them: the frame host attaches, the
        /// countdown starts by itself once readiness holds, the round runs, then ends with its
        /// summary (what Results shows). Returns whether the round really ran.
        func playToResults(_ session: GameSessionCoordinator, seconds: Double = 1) async throws -> Bool {
            let host = try session.attachLiveFrameHost()
            func tick() async throws {
                feeder.set(context: camera.state.context)
                session.advanceSetupAutomatically()
                session.advanceLive(frameHost: host)
                try await Task.sleep(for: .milliseconds(33))
            }
            let start = CameraHostClock.now()
            while session.phase != .running, CameraHostClock.now() - start < 12 { try await tick() }
            let ran = session.phase == .running
            let playing = CameraHostClock.now()
            while ran, CameraHostClock.now() - playing < seconds { try await tick() }
            await session.stop(reason: .completed)
            return ran
        }

        func copy(_ session: GameSessionCoordinator) -> LaserAutomaticSetupCopy {
            LaserAutomaticSetupCopy(.init(sessionPhase: session.phase, setupPhase: session.setup?.phase,
                                          presence: session.presence))
        }
    }

    /// Fixed parts of an automatic calibration: the upright prompt, then 10 samples 0.25 s apart.
    static let minimumCalibration = LaserAutomaticSetupPolicy.uprightPrompt
        + Double(StandingCollectionPolicyV1.sampleCount - 1) * StandingCollectionPolicyV1.sampleInterval

    // MARK: Repeated gameplay

    @Test func threeConsecutiveGamesEachCalibrateWithoutRestartingTheApp() async throws {
        let rig = try Rig()
        var durations: [Double] = []
        await rig.flow.startLiveSetup()
        for game in 1...3 {
            let session = try #require(rig.flow.session)
            #expect(session.phase == .awaitingSetup, "game \(game) setup starts cleanly")
            #expect(rig.provider.calibrationProgress.request == nil, "game \(game): no calibration carried over")
            #expect(rig.provider.currentContext?.sessionGeneration == session.inputConfiguration.sessionGeneration)
            #expect(rig.provider.currentContext?.calibrationRevisions.isEmpty == true, "game \(game): no old reference")
            // Within its own automatic attempts (a starved test runner can cost one), never a restart.
            guard let seconds = try await rig.calibrate(session, within: 25) else { await rig.flow.closeLiveSetup(); return }
            durations.append(seconds)
            #expect(session.presence.attempts <= LaserAutomaticSetupPolicy.maximumAttempts, "game \(game) calibrated by itself")
            #expect(rig.flow.session === session, "game \(game) calibrated in its own session")
            #expect(rig.provider.currentContext?.calibrationRevisions.count == 2)
            // The round ends: the session releases its input while Results show (finishLiveInput),
            // then Results › Play Again retries through the flow, then the old scene's late cleanup.
            await session.stop(reason: .completed)
            #expect(rig.provider.status == .stopped)
            await rig.flow.retryLiveSetup()
            await session.stop()
            #expect(rig.flow.session !== session && rig.flow.session?.phase == .awaitingSetup)
        }
        #expect(await rig.driver.starts == 4)
        #expect(await rig.driver.stops == 3)
        await rig.flow.closeLiveSetup()
        #expect(await rig.driver.stops == 4 && rig.provider.status == .stopped)
        for (game, seconds) in durations.enumerated() {
            #expect(seconds >= Self.minimumCalibration, "game \(game + 1) never completes early")
        }
        print("[LiveRepeatedCalibrationTests] calibration seconds per game: \(durations)")
    }

    // MARK: Failed attempts never strand setup

    /// Every attempt ends without a candidate (a mask over the STOP/REVIEW budget). Each counts,
    /// pauses for the retry delay, and after the last one the players get Try again, which works.
    @Test func attemptsThatEndWithoutACandidateAlwaysLeaveTryAgain() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        rig.feeder.set(maskService: 0.2)
        var starts: [Double] = []
        var seen = 0
        let origin = CameraHostClock.now()
        let used = try await rig.run(session, seconds: 16) {
            if session.presence.attempts > seen { seen = session.presence.attempts; starts.append(CameraHostClock.now() - origin) }
            return LaserAutomaticSetupCopy.attemptsUsed(session.presence) && rig.copy(session).action == .tryAgain
        }
        #expect(used < 16, "after the last automatic attempt the players are offered Try again")
        #expect(starts.count == LaserAutomaticSetupPolicy.maximumAttempts)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            #expect(later - earlier >= LaserAutomaticSetupPolicy.retryDelay + LaserAutomaticSetupPolicy.uprightPrompt - 0.05,
                    "the same pause and prompt before every automatic retry")
        }
        let failed = rig.copy(session)
        #expect(failed.title == "Calibration didn't finish" && failed.headline == nil)
        #expect(failed.instruction == "The camera needed a moment. Tap Try again.", "a technical delay is not blamed on the players")
        #expect(rig.provider.currentContext?.calibrationRevisions.isEmpty == true, "nothing was accepted")
        // Waiting longer changes nothing by itself (no hidden timeout completes or restarts it).
        try await rig.run(session, seconds: 4)
        #expect(session.presence.attempts == LaserAutomaticSetupPolicy.maximumAttempts && rig.copy(session).action == .tryAgain)
        // Try again with healthy masks: a fresh prompt, a fresh request, accepted.
        rig.feeder.set(maskService: 0.01)
        session.retryCalibrationManually()
        try await rig.calibrate(session)
        #expect(session.presence.attempts == 1 && !session.presence.technicalRetry)
        await rig.flow.closeLiveSetup()
    }

    // MARK: Interrupted flows

    @Test func leavingRapidlyAndReturningAlwaysStartsOneCleanSession() async throws {
        let rig = try Rig()
        // Start, begin calibrating, leave mid-attempt, return.
        await rig.flow.startLiveSetup()
        let first = try #require(rig.flow.session)
        try await rig.run(first, seconds: 2.2) { first.setup?.phase == .calibrating }
        #expect(first.setup?.phase == .calibrating)
        await rig.flow.closeLiveSetup()
        // Rapid enter/exit, including a duplicate start request while one is starting.
        for _ in 0..<3 {
            let starting = Task { await rig.flow.startLiveSetup() }
            await rig.flow.startLiveSetup() // duplicate: ignored while the first is starting
            await starting.value
            await rig.flow.closeLiveSetup()
        }
        #expect(await rig.driver.starts == 4, "one camera start per accepted request")
        #expect(await rig.driver.stops == 4)
        #expect(rig.provider.status == .stopped && rig.camera.state.context == nil)
        // Return: a clean session that calibrates normally.
        await rig.flow.startLiveSetup()
        let current = try #require(rig.flow.session)
        #expect(current.presence.attempts == 0 && rig.provider.calibrationProgress.request == nil)
        await first.stop() // a late cleanup from the first visit changes nothing
        try await rig.calibrate(current)
        await rig.flow.closeLiveSetup()
    }

    @Test func callbacksFromThePreviousGameCannotMoveTheNewCalibration() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let old = try #require(rig.flow.session)
        try await rig.calibrate(old)
        let stale = try #require(rig.feeder.lastEvidence)
        await old.stop(reason: .completed)
        await rig.flow.retryLiveSetup()
        let current = try #require(rig.flow.session)
        try await rig.run(current, seconds: 3) { current.setup?.phase == .calibrating }
        let before = rig.provider.calibrationProgress
        // The old game's last pose, mask and CP1 evidence arrive late.
        let gate = rig.camera.frames.tracking
        gate.publishBody(stale.0, admission: stale.1, receipt: stale.2)
        gate.finishMask(LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(stale.0), pose: stale.0,
            revision: stale.1.revision), pose: stale.0, admission: stale.1, receipt: stale.2)
        let after = rig.provider.calibrationProgress
        #expect(after.request == before.request && after.sampleCount == before.sampleCount)
        try await rig.calibrate(current)
        await rig.flow.closeLiveSetup()
    }

    @Test func briefPoseLossNeverCompletesAndCalibrationContinuesWhenPosesReturn() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        try await rig.run(session, seconds: 2.2) { session.setup?.phase == .calibrating }
        try await rig.run(session, seconds: 0.6) // a few samples in
        // Both players drop out for less than the tracking freshness: nothing completes meanwhile.
        try await rig.run(session, seconds: 0.3, mode: .paused)
        #expect(rig.provider.currentContext?.calibrationRevisions.isEmpty == true, "no completion without poses")
        // Only P1 visible for a moment: P2 missing, still no completion.
        try await rig.run(session, seconds: 0.3, mode: .player1Only)
        #expect(rig.provider.currentContext?.calibrationRevisions.isEmpty == true, "no completion with one player")
        // Both return: calibration completes in this same session.
        try await rig.calibrate(session)
        #expect(rig.flow.session === session && session.presence.attempts <= LaserAutomaticSetupPolicy.maximumAttempts)
        await rig.flow.closeLiveSetup()
    }

    /// Both players gone longer than the tracking freshness: identity is lost, so this binding can
    /// never be trusted again. Setup restarts by itself (bounded) and the next session calibrates.
    @Test func longPoseLossRestartsSetupByItselfAndTheNextSessionCalibrates() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let lost = try #require(rig.flow.session)
        try await rig.run(lost, seconds: 2.2) { lost.setup?.phase == .calibrating }
        // The camera keeps running with nobody in front of it.
        try await rig.run(lost, seconds: 3, mode: .nobody) { lost.phase == .restartRequired }
        #expect(lost.phase == .restartRequired, "identity lost: this binding cannot calibrate")
        #expect(lost.inputContext?.calibrationRevisions.isEmpty ?? true, "nothing accepted")
        await rig.flow.restartAutomaticallyIfNeeded() // the setup screen's restart loop
        let next = try #require(rig.flow.session)
        #expect(next !== lost && rig.flow.automaticRestarts == 1)
        try await rig.calibrate(next)
        await rig.flow.closeLiveSetup()
    }

    // MARK: Co-op cycles

    /// A 11 px head-top jump (the iPad's 5–8 mask rows), far outside the 3 px tolerance.
    static let jump = 11.0 / 720

    /// Five games in a row on one retained camera, provider and gate, each with different player
    /// conditions: calibration → gameplay → Results → Play Again, never an app restart.
    @Test func fiveConsecutiveCoopGamesUnderDifferentPlayerConditions() async throws {
        let rig = try Rig()
        let jump = Self.jump
        let cycles: [(name: String, jitter: FrameFeeder.Jitter?, loss: Bool)] = [
            ("both stable", nil, false),
            ("P2 head-top jumps every third sample", { s, p in p == .player2 && s % 3 == 2 ? jump : 0 }, false),
            ("P1 head-top jumps every third sample", { s, p in p == .player1 && s % 3 == 2 ? jump : 0 }, false),
            ("both lost for 0.3 s mid-calibration", nil, true),
            ("alternating jumps (P1 then P2)", { s, p in (p == .player1 && s % 4 == 1) || (p == .player2 && s % 4 == 3) ? jump : 0 }, false),
        ]
        await rig.flow.startLiveSetup()
        var previous: UUID?
        var revisions: [UInt64] = []
        for (index, cycle) in cycles.enumerated() {
            let game = "game \(index + 1) (\(cycle.name))"
            let session = try #require(rig.flow.session)
            let generation = session.inputConfiguration.sessionGeneration
            #expect(generation != previous && session.phase == .awaitingSetup, "\(game): a fresh session")
            #expect(rig.provider.currentContext?.sessionGeneration == generation, "\(game): frames reach this session")
            #expect(throws: BodyInputOperationError.consumerAlreadyClaimed, "\(game): one CP1 consumer") {
                try rig.provider.snapshotStream(generation: generation)
            }
            rig.feeder.set(jitter: cycle.jitter)
            defer { rig.feeder.set(jitter: nil) }
            if cycle.loss {
                try await rig.run(session, seconds: 4) { session.setup?.phase == .calibrating }
                try await rig.run(session, seconds: 0.75)
                try await rig.run(session, seconds: 0.3, mode: .paused)
            }
            guard try await rig.calibrate(session, within: 25) != nil else { await rig.flow.closeLiveSetup(); return }
            #expect(rig.flow.session === session, "\(game): calibrated in its own session")
            // Binding resets and the acceptance each advance this revision; one acceptance per game
            // gives the same value every game (a duplicate would show as one game higher).
            revisions.append(rig.provider.acceptedContextRevision)
            let accepted = rig.provider.acceptedCalibrations
            #expect(accepted.count == 2 && accepted.values.allSatisfy { abs($0.standingCrownImageY - 0.9) < 1e-9 },
                    "\(game): jumps never enter either reference")
            if cycle.jitter != nil, cycle.name.hasPrefix("P2") {
                let progress = rig.provider.calibrationProgress
                #expect(progress.players[.player1]?.rejected[.moving] == nil, "\(game): P2's jumps never touch P1's window")
                #expect((progress.players[.player2]?.rejected[.moving] ?? 0) > 0)
            }
            #expect(try await rig.playToResults(session), "\(game): gameplay ran")
            #expect(session.summary != nil && rig.provider.status == .stopped, "\(game): Results, input released")
            previous = generation
            await rig.flow.retryLiveSetup() // Results › Play Again
            await session.stop()            // the old scene's late cleanup
        }
        #expect(Set(revisions).count == 1, "exactly one acceptance in every game: \(revisions)")
        #expect(await rig.driver.starts == cycles.count + 1)
        await rig.flow.closeLiveSetup()
        #expect(rig.provider.status == .stopped && rig.camera.state.context == nil)
    }

    /// One player missing: setup waits visibly (no request, no restart, no false progress) and
    /// links and calibrates in the same session once the second player steps in.
    @Test func aMissingPlayerIsWaitedForThenCalibratesInTheSameSession() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        try await rig.run(session, seconds: 3, mode: .player1Only)
        #expect([LaserSetupPhase.awaitingBinding, .binding, .waitingForReliablePair].contains(session.setup?.phase))
        #expect(session.presence.attempts == 0 && rig.provider.calibrationProgress.request == nil)
        #expect(rig.copy(session).headline != nil && rig.copy(session).action == nil, "a waiting screen, not an error")
        try await rig.calibrate(session)
        #expect(rig.flow.session === session && session.presence.attempts == 1)
        await rig.flow.closeLiveSetup()
    }

    /// Head-top jumps in pairs (the iPad pattern) on a still P2 (V1.2): they no longer restart
    /// P2's window, so the first attempt completes while they continue, and the reference comes
    /// only from the agreeing readings.
    @Test func clusteredHeadTopJumpsNoLongerStallCalibration() async throws {
        let rig = try Rig()
        let jump = Self.jump
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        rig.feeder.set(jitter: { s, p in p == .player2 && (s % 5 == 2 || s % 5 == 3) ? jump : 0 })
        defer { rig.feeder.set(jitter: nil) }
        var dropped = false
        try await rig.run(session, seconds: 12) {
            dropped = dropped || !session.presence.progressDropReason.isEmpty
            return session.setup?.phase == .awaitingGameplayReadiness && session.hasLiveRoundPlan
        }
        #expect(!dropped, "head-top jumps never make progress fall back")
        guard try await rig.calibrate(session) != nil else { await rig.flow.closeLiveSetup(); return }
        #expect(session.presence.attempts == 1, "the first attempt, while the jumps continue")
        #expect(rig.provider.acceptedCalibrations[.player2].map { abs($0.standingCrownImageY - 0.9) < 1e-9 } == true)
        #expect((rig.provider.calibrationProgress.players[.player2]?.rejected[.moving] ?? 0) > 0)
        await rig.flow.closeLiveSetup()
    }

    /// Automatic attempts used up, then the players leave and start again (Home › Start): the new
    /// session starts with all its attempts and calibrates.
    @Test func exhaustedAttemptsNeverCarryIntoTheNextSession() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let tired = try #require(rig.flow.session)
        rig.feeder.set(maskService: 0.2)
        try await rig.run(tired, seconds: 16) { rig.copy(tired).action == .tryAgain }
        #expect(rig.copy(tired).action == .tryAgain)
        rig.feeder.set(maskService: 0.01)
        await rig.flow.closeLiveSetup()
        await rig.flow.startLiveSetup()
        let next = try #require(rig.flow.session)
        #expect(next !== tired && next.presence.attempts == 0 && !next.presence.retryPending)
        try await rig.calibrate(next)
        #expect(next.presence.attempts == 1)
        await rig.flow.closeLiveSetup()
    }

    /// Both players leave mid-round: identity is lost, the round pauses, and the tracking warning's
    /// Recalibrate (the flow's retry) runs while the old round's own cleanup is still in flight.
    /// The new setup starts clean and the next game runs.
    @Test func recalibrateFromAPausedRoundStartsACleanSetup() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let first = try #require(rig.flow.session)
        guard try await rig.calibrate(first) != nil else { await rig.flow.closeLiveSetup(); return }
        let host = try first.attachLiveFrameHost()
        let start = CameraHostClock.now()
        while first.phase != .running, CameraHostClock.now() - start < 12 {
            rig.feeder.set(context: rig.camera.state.context)
            first.advanceSetupAutomatically(); first.advanceLive(frameHost: host)
            try await Task.sleep(for: .milliseconds(33))
        }
        try #require(first.phase == .running)
        rig.feeder.set(mode: .nobody)
        let lost = CameraHostClock.now()
        while first.phase == .running, CameraHostClock.now() - lost < 6 {
            first.advanceSetupAutomatically(); first.advanceLive(frameHost: host)
            try await Task.sleep(for: .milliseconds(33))
        }
        rig.feeder.set(mode: .pair)
        #expect(first.phase != .running, "the round stops judging without players (\(first.phase))")
        #expect(first.state != nil, "the round is kept, not silently finished")
        // Recalibrate, with the old scene's teardown racing it.
        async let recalibrate: Void = rig.flow.retryLiveSetup()
        async let teardown: Void = first.stop()
        _ = await (recalibrate, teardown)
        let next = try #require(rig.flow.session)
        #expect(next !== first && next.phase == .awaitingSetup && next.presence.attempts == 0)
        #expect(rig.provider.currentContext?.sessionGeneration == next.inputConfiguration.sessionGeneration)
        guard try await rig.calibrate(next) != nil else { await rig.flow.closeLiveSetup(); return }
        #expect(try await rig.playToResults(next), "the next game runs")
        await rig.flow.closeLiveSetup()
    }

    /// Play Again tapped twice while the first tap is still closing the old game: one new session,
    /// one camera start, and it calibrates.
    @Test func doubleTappedPlayAgainStartsExactlyOneSession() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let first = try #require(rig.flow.session)
        guard try await rig.calibrate(first) != nil else { await rig.flow.closeLiveSetup(); return }
        #expect(try await rig.playToResults(first))
        let starts = await rig.driver.starts
        async let tap1: Void = rig.flow.retryLiveSetup()
        async let tap2: Void = rig.flow.retryLiveSetup()
        _ = await (tap1, tap2)
        #expect(await rig.driver.starts == starts + 1, "one camera start for two taps")
        let next = try #require(rig.flow.session)
        #expect(next !== first && next.phase == .awaitingSetup)
        try await rig.calibrate(next)
        await rig.flow.closeLiveSetup()
    }

    /// P2 really steps to another spot mid-calibration (head-top and both soles move): their
    /// progress falls back with the reason on screen, and the reference comes only from the new
    /// spot, never mixed with samples from before the step.
    @Test func aRealStepResetsProgressWithItsReasonAndNeverMixesSpots() async throws {
        let rig = try Rig()
        let offset = -8.0 / 720
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        rig.feeder.set(step: { s, p in p == .player2 && s >= 7 ? offset : 0 })
        defer { rig.feeder.set(step: nil) }
        var reason: StandingSampleIssue?, detail: String?
        guard try await rig.calibrate(session, within: 16) != nil else { await rig.flow.closeLiveSetup(); return }
        _ = (reason, detail)
        let p2 = try #require(rig.provider.acceptedCalibrations[.player2])
        #expect(abs(p2.standingCrownImageY - (0.9 + offset)) < 1e-9 && abs(p2.standingLeftSoleImageY - (0.1 + offset)) < 1e-9,
                "the new spot only")
        let p1 = try #require(rig.provider.acceptedCalibrations[.player1])
        #expect(abs(p1.standingCrownImageY - 0.9) < 1e-9, "P1 never affected by P2's step")
        // The same step, watched: the drop is explained while it shows.
        await rig.flow.retryLiveSetup()
        let watched = try #require(rig.flow.session)
        try await rig.run(watched, seconds: 16) {
            if let r = watched.presence.progressDropReason[.player2], reason == nil {
                reason = r; detail = rig.copy(watched).headlineDetail
            }
            return watched.setup?.phase == .awaitingGameplayReadiness && watched.hasLiveRoundPlan
        }
        #expect(reason == .moving, "the reset names its reason")
        #expect(detail == "P2: Hold still.", "on screen, for the right player (\(detail ?? "-"))")
        #expect(watched.presence.progressDropReason.isEmpty || watched.setup?.phase == .awaitingGameplayReadiness)
        await rig.flow.closeLiveSetup()
    }

    /// Five Solo games in a row (one player, the DEBUG Solo configuration) on one retained camera.
    @Test func fiveConsecutiveSoloGamesUnderDifferentConditions() async throws {
        let rig = try Rig(solo: true)
        let jump = Self.jump
        let cycles: [(name: String, jitter: FrameFeeder.Jitter?, step: FrameFeeder.Jitter?, loss: Bool)] = [
            ("still", nil, nil, false),
            ("head-top jumps every third sample", { s, _ in s % 3 == 2 ? jump : 0 }, nil, false),
            ("paired head-top jumps", { s, _ in s % 5 == 2 || s % 5 == 3 ? jump : 0 }, nil, false),
            ("lost for 0.3 s mid-calibration", nil, nil, true),
            ("steps once, then stands still", nil, { s, _ in s >= 5 ? -8.0 / 720 : 0 }, false),
        ]
        await rig.flow.startLiveSetup()
        var previous: UUID?
        for (index, cycle) in cycles.enumerated() {
            let game = "solo game \(index + 1) (\(cycle.name))"
            let session = try #require(rig.flow.session)
            #expect(session.isSoloPractice && session.inputConfiguration.roster == [.player1])
            #expect(session.inputConfiguration.sessionGeneration != previous && session.phase == .awaitingSetup, "\(game): fresh")
            rig.feeder.set(jitter: cycle.jitter); rig.feeder.set(step: cycle.step)
            defer { rig.feeder.set(jitter: nil); rig.feeder.set(step: nil) }
            if cycle.loss {
                try await rig.run(session, seconds: 4) { session.setup?.phase == .calibrating }
                try await rig.run(session, seconds: 0.75)
                try await rig.run(session, seconds: 0.3, mode: .paused)
            }
            guard try await rig.calibrate(session, within: 25) != nil else { await rig.flow.closeLiveSetup(); return }
            let accepted = rig.provider.acceptedCalibrations
            #expect(Set(accepted.keys) == [.player1], "\(game): P1 only")
            let expected = cycle.step == nil ? 0.9 : 0.9 - 8.0 / 720
            #expect(accepted[.player1].map { abs($0.standingCrownImageY - expected) < 1e-9 } == true, "\(game): consistent samples only")
            #expect(session.presence.attempts == 1, "\(game): first attempt")
            #expect(try await rig.playToResults(session), "\(game): gameplay ran")
            #expect(session.summary != nil && rig.provider.status == .stopped)
            previous = session.inputConfiguration.sessionGeneration
            await rig.flow.retryLiveSetup()
            await session.stop()
        }
        #expect(await rig.driver.starts == cycles.count + 1)
        await rig.flow.closeLiveSetup()
    }

    // MARK: Bystanders outside the boxes

    /// The iPad scene in Solo: P1 in the box, someone at the camera's far edge (whole, then half
    /// out of frame) for the whole visit. P1 calibrates and plays, twice in a row, and the bystander
    /// is never linked.
    @Test func soloCalibratesAndReplaysWithSomeoneOutsideTheBox() async throws {
        let rig = try Rig(solo: true)
        await rig.flow.startLiveSetup()
        for (game, bystander) in [FrameFeeder.bystander(atX: 0.92), FrameFeeder.bystander(atX: 0.96, partial: true)].enumerated() {
            rig.feeder.set(bystander: bystander)
            let session = try #require(rig.flow.session)
            guard try await rig.calibrate(session, within: 16) != nil else { await rig.flow.closeLiveSetup(); return }
            let slots = rig.camera.frames.tracking.snapshot.latest
            #expect(slots?.player1.candidateID == 10, "game \(game + 1): P1 is the person in the box")
            #expect(Set(rig.provider.acceptedCalibrations.keys) == [.player1])
            #expect(rig.provider.acceptedCalibrations[.player1].map { abs($0.standingCrownImageY - 0.9) < 1e-9 } == true)
            #expect(session.presence.attempts == 1 && session.presence.progressDropReason.isEmpty)
            #expect(try await rig.playToResults(session), "game \(game + 1): gameplay ran")
            await rig.flow.retryLiveSetup()
            await session.stop()
        }
        rig.feeder.set(bystander: nil)
        await rig.flow.closeLiveSetup()
    }

    /// The reported co-op scene: P1 in the left box, a bystander at the far edge, P2's box empty.
    /// Setup waits (never linking the bystander as anyone), then P2 steps in and the pair
    /// calibrates while the bystander is still there.
    @Test func coopWaitsForP2AndNeverLinksTheBystander() async throws {
        let rig = try Rig()
        rig.feeder.set(bystander: FrameFeeder.bystander(atX: 0.92))
        defer { rig.feeder.set(bystander: nil) }
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        var linkedBystander = false
        try await rig.run(session, seconds: 3, mode: .player1Only) {
            let slots = rig.camera.frames.tracking.snapshot.latest
            linkedBystander = linkedBystander || slots?.player1.candidateID == 30 || slots?.player2.candidateID == 30
            return false
        }
        #expect(!linkedBystander, "the outside person is never P1 or P2")
        #expect([LaserSetupPhase.awaitingBinding, .binding, .waitingForReliablePair].contains(session.setup?.phase))
        #expect(session.presence.attempts == 0)
        guard try await rig.calibrate(session) != nil else { await rig.flow.closeLiveSetup(); return }
        let slots = rig.camera.frames.tracking.snapshot.latest
        #expect(slots?.player1.candidateID == 10 && slots?.player2.candidateID == 20)
        #expect(rig.flow.session === session && session.presence.attempts == 1)
        await rig.flow.closeLiveSetup()
    }

    /// Someone keeps stepping in and out of view at the camera's edge while both players calibrate:
    /// progress never falls back and the first attempt completes.
    @Test func someoneComingAndGoingAtTheEdgeNeverCostsProgress() async throws {
        let rig = try Rig()
        await rig.flow.startLiveSetup()
        let session = try #require(rig.flow.session)
        try await rig.run(session, seconds: 4) { session.setup?.phase == .calibrating }
        var dropped = false, toggles = 0
        let start = CameraHostClock.now()
        try await rig.run(session, seconds: 12) {
            let on = Int((CameraHostClock.now() - start) / 0.4) % 2 == 0
            rig.feeder.set(bystander: on ? FrameFeeder.bystander(atX: 0.93, partial: toggles % 2 == 1) : nil)
            if on { toggles += 1 }
            dropped = dropped || !session.presence.progressDropReason.isEmpty
            return session.setup?.phase == .awaitingGameplayReadiness && session.hasLiveRoundPlan
        }
        rig.feeder.set(bystander: nil)
        #expect(session.setup?.phase == .awaitingGameplayReadiness, "calibrated while someone came and went")
        #expect(!dropped && session.presence.attempts == 1)
        await rig.flow.closeLiveSetup()
    }

    // MARK: Timing

    /// The same valid standing at 30 and at 15 camera frames per second takes the same time:
    /// progress is measured in capture/host time, never in frames.
    @Test func calibrationTimeDoesNotDependOnTheFrameRate() async throws {
        let rig = try Rig()
        var taken: [Double] = []
        await rig.flow.startLiveSetup()
        for fps in [30.0, 15.0] {
            let session = try #require(rig.flow.session)
            guard let seconds = try await rig.calibrate(session, fps: fps) else { await rig.flow.closeLiveSetup(); return }
            taken.append(seconds)
            await session.stop(reason: .completed)
            await rig.flow.retryLiveSetup()
        }
        await rig.flow.closeLiveSetup()
        #expect(taken.allSatisfy { $0 >= Self.minimumCalibration })
        #expect(abs(taken[0] - taken[1]) < 0.5, "30 fps \(taken[0]) s vs 15 fps \(taken[1]) s")
        print("[LiveRepeatedCalibrationTests] 30 vs 15 fps calibration seconds: \(taken)")
    }
}
