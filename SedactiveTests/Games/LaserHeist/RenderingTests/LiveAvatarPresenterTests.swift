import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// K05: the Release-compiled attachment between an authoritative pose mailbox
/// and the mascots. SYNTHETIC packets only: no camera, tracker or CP1 reader,
/// so nothing here says anything about real tracking quality.
@MainActor
struct LiveAvatarPresenterTests {
    private func attached() async throws -> (LaserScene, AvatarPoseMailbox, SyntheticAvatarSource) {
        let input = try LaserReplayScript.load().input
        let source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        let scene = LaserScene()
        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        scene.attachLiveAvatars(mailbox: mailbox, templates: try await RobotAvatarLayer.sharedTemplates())
        return (scene, mailbox, source)
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
