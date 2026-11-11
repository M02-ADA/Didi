import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// K05: the Release-compiled attachment between an authoritative pose mailbox
/// and the mascots. SYNTHETIC packets only: no camera, tracker or CP1 reader,
/// so nothing here says anything about real tracking quality.
@MainActor
struct LiveAvatarPresenterTests {
    /// Stands in for a producer's render-tick pump.
    private final class ScriptedPump: AvatarPosePump {
        private(set) var ticks = 0
        private(set) var stops = 0
        var step: () throws -> Bool = { true }
        func tick() throws -> Bool {
            ticks += 1
            return try step()
        }
        func stop() { stops += 1 }
    }

    private struct FeedFailed: Error {}

    private func attached(pump: ScriptedPump? = nil) async throws -> (LaserScene, AvatarPoseMailbox, SyntheticAvatarSource) {
        let input = try LaserReplayScript.load().input
        let source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        let scene = LaserScene()
        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        scene.attachLiveAvatars(mailbox: mailbox, templates: try await RobotAvatarLayer.sharedTemplates(), pump: pump)
        return (scene, mailbox, source)
    }

    private func sequence(_ scenario: RobotDemoScenario) throws -> RobotDemoSequence {
        let input = try LaserReplayScript.load().input
        return RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: scenario)
    }

    /// Feeds `count` frames of a demo scenario, ticking like the render loop. Returns the last frame's time.
    @discardableResult
    private func play(_ scenario: RobotDemoScenario, frames count: UInt64, into scene: LaserScene, mailbox: AvatarPoseMailbox,
                      source: SyntheticAvatarSource) throws -> Double {
        let input = try LaserReplayScript.load().input
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: scenario)
        var time = 0.0
        for index in UInt64(1)...count {
            let frame = try sequence.frame(index)
            time = frame.snapshot.capturedAt
            #expect(mailbox.offer(source.output(frame.snapshot, joints: frame.joints)) == nil)
            scene.refreshLiveAvatars(now: time + 0.005)
        }
        return time
    }

    private func oneMascotEach(_ scene: LaserScene) throws {
        for player in PlayerID.allCases {
            let entity = try #require(scene.players[player])
            #expect(entity.children.filter { $0.name == "player.\(player.rawValue).robot" }.count == 1)
        }
    }

    private func surface(_ scene: LaserScene, _ player: PlayerID) -> Entity? {
        scene.players[player]?.findEntity(named: "player.\(player.rawValue).surface")
    }

    @Test func bothMascotsFollowThePacketsIndependently() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        try play(.p2DuckStand, frames: 40, into: scene, mailbox: mailbox, source: source)
        try oneMascotEach(scene)
        let avatars = try #require(scene.robotAvatars)
        #expect(avatars.smoothing == LiveAvatarPresenter.renderSmoothing)
        #expect(avatars.robots.values.allSatisfy { $0.retargeter.isAvailable })
        #expect((avatars.robots[.player2]?.retargeter.targets.pelvisDrop ?? 0) > 0.03)
        #expect((avatars.robots[.player1]?.retargeter.targets.pelvisDrop ?? 1) < 0.01)
        #expect(PlayerID.allCases.allSatisfy { surface(scene, $0)?.isEnabled == false })
    }

    /// Attached but silent (producer not started): honest, dimmed and neutral.
    @Test func withoutPosesTheMascotsStayDimmedAndNeutral() async throws {
        let (scene, _, _) = try await attached()
        for n in 0..<30 { scene.refreshLiveAvatars(now: 100 + Double(n) / 60) }
        let avatars = try #require(scene.robotAvatars)
        for robot in avatars.robots.values {
            #expect(!robot.retargeter.isAvailable && robot.retargeter.presence == 0)
            #expect(robot.container.position.y == 0)
            #expect(robot.container.components[OpacityComponent.self]?.opacity == RobotAvatarLayer.unavailableOpacity)
        }
    }

    /// Frames stop arriving: both mascots relax to neutral and dim, with no new frame needed.
    @Test func stalePosesRelaxWithoutANewerFrame() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        let last = try play(.p2DuckStand, frames: 40, into: scene, mailbox: mailbox, source: source)
        for n in 1...120 { scene.refreshLiveAvatars(now: last + Double(n) / 60) }
        let avatars = try #require(scene.robotAvatars)
        #expect(avatars.robots.values.allSatisfy { !$0.retargeter.isAvailable && $0.retargeter.presence < 0.05 })
    }

    /// One player drops out while the other stays tracked: only that mascot
    /// dims and relaxes, and it stays that player's only body.
    @Test func onlyTheLostPlayerDimsAndRelaxes() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        // The scenario loses P2 from 1.0 s to 2.6 s; stop at about 2.4 s.
        try play(.trackingLoss, frames: 72, into: scene, mailbox: mailbox, source: source)
        let avatars = try #require(scene.robotAvatars)
        let p1 = try #require(avatars.robots[.player1]), p2 = try #require(avatars.robots[.player2])
        #expect(p1.retargeter.isAvailable && p1.retargeter.presence > 0.95)
        #expect(p1.container.components[OpacityComponent.self]?.opacity == 1)
        #expect(!p2.retargeter.isAvailable && p2.retargeter.presence < 0.05)
        #expect(p2.container.components[OpacityComponent.self]?.opacity == RobotAvatarLayer.unavailableOpacity)
        try oneMascotEach(scene)
        #expect(PlayerID.allCases.allSatisfy { surface(scene, $0)?.isEnabled == false })
    }

    @Test func detachRevokesAndRestoresThePictograms() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        try play(.idle, frames: 5, into: scene, mailbox: mailbox, source: source)
        let lightsBefore = scene.root.children.filter { $0.name == "robot.lights" }.count
        #expect(lightsBefore == 1)
        scene.detachLiveAvatars()
        #expect(scene.liveAvatars == nil && scene.robotAvatars == nil && mailbox.isRevoked)
        #expect(scene.root.children.filter { $0.name == "robot.lights" }.isEmpty)
        for player in PlayerID.allCases {
            #expect(scene.players[player]?.children.contains { $0.name == "player.\(player.rawValue).robot" } == false)
            #expect(surface(scene, player)?.isEnabled == true)
        }
        scene.refreshLiveAvatars(now: 500)   // Safe with nothing attached.
        scene.detachLiveAvatars()            // Idempotent.
    }

    /// A second attachment on the same scene replaces the first: no duplicate
    /// mascots or lights, the old mailbox is dead, and nothing carries over.
    @Test func reattachingStartsCleanWithoutDuplicates() async throws {
        let (scene, first, source) = try await attached()
        first.publish(source.status)
        try play(.p2DuckStand, frames: 20, into: scene, mailbox: first, source: source)
        let second = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        scene.attachLiveAvatars(mailbox: second, templates: try await RobotAvatarLayer.sharedTemplates())
        #expect(first.isRevoked && !second.isRevoked)
        try oneMascotEach(scene)
        #expect(scene.root.children.filter { $0.name == "robot.lights" }.count == 1)
        let avatars = try #require(scene.robotAvatars)
        #expect(avatars.robots.values.allSatisfy { !$0.retargeter.isAvailable && $0.retargeter.targets.pelvisDrop == 0 })
    }

    /// A live attachment is the only driver: the DEBUG replay bridge stays out of it.
    @Test func theReplayBridgeNeverDrivesLiveAvatars() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        try await session.advance(to: 5)
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let state = try #require(session.state), snapshot = try #require(session.latestSnapshot)
        presenter.apply(state: state, events: session.events, snapshot: snapshot)
        #expect(scene.robotAvatars?.lastFrame == nil)
        await session.stop()
    }

    /// The cutout fallback cannot bring a pictogram back beside a mascot.
    @Test func thePictogramCannotReturnBesideAMascot() async throws {
        let (scene, _, _) = try await attached()
        let p1 = try #require(scene.players[.player1])
        p1.showPlaceholder()
        #expect(surface(scene, .player1)?.isEnabled == false)
        scene.detachLiveAvatars()
        #expect(surface(scene, .player1)?.isEnabled == true)
        p1.showPlaceholder()
        #expect(surface(scene, .player1)?.isEnabled == true)
    }

    // MARK: - The render-tick pump

    /// The pump runs before the drain, so its packet is on the mascots in
    /// that same render tick, and it runs exactly once per tick.
    @Test func aPacketPumpedThisTickIsShownThisTick() async throws {
        let pump = ScriptedPump()
        let (scene, mailbox, source) = try await attached(pump: pump)
        let frame = try sequence(.idle).frame(1)
        pump.step = {
            mailbox.publish(source.status)
            mailbox.offer(source.output(frame.snapshot, joints: frame.joints))
            return true
        }
        scene.refreshLiveAvatars(now: frame.snapshot.capturedAt + 0.005)
        #expect(pump.ticks == 1)
        #expect(try #require(scene.robotAvatars).robots.values.allSatisfy { $0.retargeter.isAvailable })
    }

    /// Most render ticks have no new camera result: that is not the end of the feed.
    @Test func ticksWithNothingNewKeepTheFeedAlive() async throws {
        let pump = ScriptedPump()
        let (scene, mailbox, source) = try await attached(pump: pump)
        for n in 0..<60 { scene.refreshLiveAvatars(now: 100 + Double(n) / 60) }
        #expect(pump.ticks == 60 && pump.stops == 0 && !mailbox.isRevoked)
        #expect(scene.liveAvatars?.feedEnded == false)
        let frame = try sequence(.idle).frame(1)
        mailbox.publish(source.status)
        mailbox.offer(source.output(frame.snapshot, joints: frame.joints))
        scene.refreshLiveAvatars(now: frame.snapshot.capturedAt + 0.005)
        #expect(try #require(scene.robotAvatars).robots.values.allSatisfy { $0.retargeter.isAvailable })
    }

    /// A retired lease or a broken packet ends the feed. No pose is left held:
    /// the same mascots go neutral and dim at once, and the pump is not run again.
    @Test(arguments: [false, true])
    func aFeedThatEndsForgetsTheHeldPoseAtOnce(throwing: Bool) async throws {
        let pump = ScriptedPump()
        let (scene, mailbox, source) = try await attached(pump: pump)
        mailbox.publish(source.status)
        let last = try play(.p2DuckStand, frames: 40, into: scene, mailbox: mailbox, source: source)
        let avatars = try #require(scene.robotAvatars)
        #expect((avatars.robots[.player2]?.retargeter.targets.pelvisDrop ?? 0) > 0.03)

        let ticks = pump.ticks
        pump.step = {
            if throwing { throw FeedFailed() }
            return false
        }
        scene.refreshLiveAvatars(now: last + 0.01)
        for robot in avatars.robots.values {
            #expect(!robot.retargeter.isAvailable && robot.retargeter.targets.pelvisDrop == 0)
            #expect(robot.container.components[OpacityComponent.self]?.opacity == RobotAvatarLayer.unavailableOpacity)
        }
        #expect(scene.liveAvatars?.feedEnded == true && mailbox.isRevoked && pump.stops == 1)
        try oneMascotEach(scene)

        for n in 2...30 { scene.refreshLiveAvatars(now: last + Double(n) / 60) }
        #expect(pump.ticks == ticks + 1 && pump.stops == 1)
        #expect(avatars.robots.values.allSatisfy { !$0.retargeter.isAvailable })
        #expect(PlayerID.allCases.allSatisfy { surface(scene, $0)?.isEnabled == false })
    }

    /// Retry: detaching stops the old pump once and for all; the new scene's
    /// attachment runs only its own.
    @Test func detachStopsThePumpAndRetryRunsOnlyTheNewOne() async throws {
        let old = ScriptedPump()
        let (oldScene, oldMailbox, _) = try await attached(pump: old)
        oldScene.refreshLiveAvatars(now: 1)
        oldScene.detachLiveAvatars()
        oldScene.detachLiveAvatars()
        oldScene.refreshLiveAvatars(now: 2)
        #expect(old.ticks == 1 && old.stops == 1 && oldMailbox.isRevoked)

        let new = ScriptedPump()
        let (newScene, newMailbox, _) = try await attached(pump: new)
        newScene.refreshLiveAvatars(now: 3)
        #expect(new.ticks == 1 && new.stops == 0 && !newMailbox.isRevoked && old.ticks == 1)
        try oneMascotEach(newScene)
    }

    /// A second attachment on the same scene stops the first attachment's pump.
    @Test func reattachingStopsThePreviousPump() async throws {
        let first = ScriptedPump()
        let (scene, _, _) = try await attached(pump: first)
        let second = ScriptedPump()
        scene.attachLiveAvatars(mailbox: AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge),
                                templates: try await RobotAvatarLayer.sharedTemplates(), pump: second)
        scene.refreshLiveAvatars(now: 1)
        #expect(first.stops == 1 && first.ticks == 0 && second.ticks == 1)
        try oneMascotEach(scene)
    }

    /// The producer already merged an interruption, so the resumed status looks
    /// unchanged from here. The reset must still arrive, once.
    @Test func aCoalescedResetArrivesOnceWithItsNewStatus() throws {
        let input = try LaserReplayScript.load().input
        var source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        mailbox.publish(source.status)
        _ = mailbox.drain(now: 1)

        source.statusRevision = 2
        mailbox.publish(source.status)
        #expect(!mailbox.drain(now: 1).reset.all)

        source.statusRevision = 3
        mailbox.publish(source.status, forceResetAll: true)
        #expect(mailbox.drain(now: 1).reset.all)

        // The same status again, as an inactive source repeats on every tick.
        mailbox.publish(source.status, forceResetAll: true)
        #expect(!mailbox.drain(now: 1).reset.all)
        #expect(mailbox.diagnostics.statusesIgnored == 1)
    }

    /// Vision packets carry no visual values, so even a calibrated pose has
    /// no evidence of a jump: the mascot never leaves the floor.
    @Test func packetsWithoutVisualValuesNeverClaimAJump() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        let frames = try sequence(.bothJump)
        for index in UInt64(1)...120 {
            let frame = try frames.frame(index)
            let output = source.output(frame.snapshot, joints: frame.joints)
            mailbox.offer(AvatarSourceOutput(
                source: output.source, contextRevision: output.contextRevision, player1: output.player1, player2: output.player2,
                candidates: output.candidates, calibration: output.calibration.mapValues {
                    AvatarCalibrationInput(revision: $0.revision, mapping: $0.mapping, standingCrownImageY: $0.standingCrownImageY,
                                           standingHipImageY: $0.standingHipImageY, standingLeftAnkleImageY: $0.standingLeftAnkleImageY,
                                           standingRightAnkleImageY: $0.standingRightAnkleImageY, visual: nil)
                }))
            scene.refreshLiveAvatars(now: frame.snapshot.capturedAt + 0.005)
            for robot in try #require(scene.robotAvatars).robots.values {
                #expect(robot.retargeter.lift == 0 && robot.container.position.y == 0)
            }
        }
        #expect(try #require(scene.robotAvatars).robots.values.allSatisfy { $0.retargeter.reference != nil })
    }

    /// Live round (iPad, 11 November 2026): the same Vision packets plus the judge's own CP1
    /// evidence. The mascot lifts only while that evidence says airborne; raised soles alone
    /// (a tucked or misread foot) still never leave the floor.
    @Test(arguments: [true, false])
    func theJudgesAirborneEvidenceLiftsTheMascot(airborne: Bool) async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        var current: (sole: Double, time: Double)?
        try #require(scene.robotAvatars).liveEvidence = { _, capturedAt in
            guard let current, current.time == capturedAt else { return nil }
            return LiveAvatarEvidence(lowerSoleY: current.sole, airborne: airborne && current.sole > 0.05, centerX: nil)
        }
        let frames = try sequence(.bothJump)
        var highest: Float = 0
        for index in UInt64(1)...120 {
            let frame = try frames.frame(index)
            let output = source.output(frame.snapshot, joints: frame.joints)
            let sample = try #require(frame.snapshot.players[.player1])
            current = (min(sample.geometry.leftSoleY.value ?? 0, sample.geometry.rightSoleY.value ?? 0),
                       frame.snapshot.capturedAt)
            mailbox.offer(AvatarSourceOutput(
                source: output.source, contextRevision: output.contextRevision, player1: output.player1, player2: output.player2,
                candidates: output.candidates, calibration: output.calibration.mapValues {
                    AvatarCalibrationInput(revision: $0.revision, mapping: $0.mapping, standingCrownImageY: $0.standingCrownImageY,
                                           standingHipImageY: $0.standingHipImageY, standingLeftAnkleImageY: $0.standingLeftAnkleImageY,
                                           standingRightAnkleImageY: $0.standingRightAnkleImageY, visual: nil)
                }))
            scene.refreshLiveAvatars(now: frame.snapshot.capturedAt + 0.005)
            highest = max(highest, try #require(scene.robotAvatars).robots.values.map(\.retargeter.lift).max() ?? 0)
        }
        #expect(airborne ? highest > 0 : highest == 0)
    }

    /// Live round: the judge's hip centre moves the mascot sideways (mirrored about its lane, so
    /// P1 stepping toward its own wall moves toward screen left), and the other player not at all.
    @Test func theJudgesHipCentreMovesOnlyThatMascotSideways() async throws {
        let (scene, mailbox, source) = try await attached()
        mailbox.publish(source.status)
        let layout = try LaserReplayScript.load().input.configuration.playerPlaneLayout
        try #require(scene.robotAvatars).liveEvidence = { player, _ in
            player == .player1 ? LiveAvatarEvidence(lowerSoleY: nil, airborne: false,
                                                    centerX: layout.centerX(for: .player1) + 0.15) : nil
        }
        let frames = try sequence(.bothJump)
        for index in UInt64(1)...60 {
            let frame = try frames.frame(index)
            let output = source.output(frame.snapshot, joints: frame.joints)
            mailbox.offer(AvatarSourceOutput(
                source: output.source, contextRevision: output.contextRevision, player1: output.player1, player2: output.player2,
                candidates: output.candidates, calibration: output.calibration.mapValues {
                    AvatarCalibrationInput(revision: $0.revision, mapping: $0.mapping, standingCrownImageY: $0.standingCrownImageY,
                                           standingHipImageY: $0.standingHipImageY, standingLeftAnkleImageY: $0.standingLeftAnkleImageY,
                                           standingRightAnkleImageY: $0.standingRightAnkleImageY, visual: nil)
                }))
            scene.refreshLiveAvatars(now: frame.snapshot.capturedAt + 0.005)
        }
        let robots = try #require(scene.robotAvatars).robots
        let p1 = try #require(robots[.player1]).container.position.x, p2 = try #require(robots[.player2]).container.position.x
        #expect(p1 < -0.05 && p1 >= -RobotRetargeter.defaultMaximumSway - 1e-4, "P1 shifted toward its wall, bounded")
        #expect(abs(p2) < 0.01, "P2 unaffected")
    }

    /// Edo's tracker values map one to one onto the avatar seam.
    @Test(arguments: [(PlayerTrackingState.unbound, AvatarTrackedState.unbound), (.tracking, .tracking), (.uncertain, .uncertain), (.lost, .lost)])
    func trackerValuesMapOneToOne(state: PlayerTrackingState, expected: AvatarTrackedState) {
        let context = PlayerTrackingContext(generation: UUID(), epoch: UUID(), geometryRevision: 7, imageWidth: 1920, imageHeight: 1080,
                                            rotationAngle: 180, mirrored: false)
        let source = PlayerTrackingSource(context: context, frameID: 42, capturedAt: 12.5, controlRevision: 3)
        let frame = AvatarSourceFrame(source)
        #expect(frame.frameID == 42 && frame.capturedAt == 12.5 && frame.controlRevision == 3)
        #expect(frame.context == AvatarSourceContext(generation: context.generation, epoch: context.epoch, geometryRevision: 7,
                                                     imageWidth: 1920, imageHeight: 1080, rotationAngle: 180, mirrored: false))
        let result = PlayerTrackingSlotResult(state: state, reason: .matched, candidateID: 9, cost: nil, requiresRebind: true, lastConfirmedAt: nil)
        #expect(AvatarTrackedSlot(result) == AvatarTrackedSlot(state: expected, candidateID: 9, requiresRebind: true))
    }
}
