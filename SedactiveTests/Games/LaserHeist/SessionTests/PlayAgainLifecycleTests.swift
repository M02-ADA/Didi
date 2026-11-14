import Foundation
import Testing
@testable import Sedactive

/// iPad, 12 November 2026 (P0): after Results › Play Again the second round calibrated and
/// started, but the mascots no longer moved. Starting a session's camera input retires the
/// current pose-presentation lease (`CameraTrackingGate.reserveBodySession`); with the scene
/// assets cached, the new round's view attached its mascot feed BEFORE the input started, so
/// the feed was retired at once and ended. Live rounds now attach the feed with the round plan,
/// after the input has started. Three consecutive sessions in one process, through the real
/// camera pipeline, tracking gate, pose bridge and K03 mascot pump.
@MainActor struct PlayAgainLifecycleTests {
    @Test func threeConsecutiveRoundsEachReceiveFreshBodyInputAndMascotPoses() async throws {
        let driver = ControlledCameraDriver()
        let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
        let provider = BodyInputService(camera: camera)
        let bridge = VisionNumericPoseBridge(gate: camera.frames.tracking)
        let f = try TrackingIntegrationFixture()
        var generations: Set<UUID> = []
        for round in 1...3 {
            // The old order: a feed attached before this round's input starts is retired by it.
            let early = try VisionK03MailboxPump(bridge: bridge, mailbox: AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge))
            try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
            let source = try #require(camera.state.context)
            generations.insert(source.generation)
            #expect(try early.tick() == false, "round \(round): a feed attached before the input start is retired")
            // The fix: the feed attaches once the input has started (with the round plan).
            let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
            let pump = try VisionK03MailboxPump(bridge: bridge, mailbox: mailbox)
            let request = try provider.makeBindingRequest(); try provider.armBinding(request)
            var engine = try MotionEngine(policy: B2bExperimentalPolicyV1.value)
            let base = CameraHostClock.now() - 0.25
            for i in 1...3 {
                let pose = try f.result(UInt64(i), base + Double(i - 1) * 0.1, LiveVisionFixtures.standingPair, context: source)
                let admission = try #require(camera.frames.tracking.admit(pose.source))
                let staged = try engine.staged(pose, admission: admission)
                try #require(camera.frames.tracking.finish(staged, admission: admission, source: pose.source,
                                                           mutualCoreCount: 4) { engine = staged })
                let receipt = try #require(camera.frames.tracking.snapshot.latest)
                camera.frames.tracking.publishBody(pose, admission: admission, receipt: receipt)
                camera.frames.tracking.publishPresentation(pose, admission: admission, receipt: receipt)
                #expect(try pump.tick(), "round \(round): the feed stays attached")
            }
            #expect(mailbox.diagnostics.accepted > 0, "round \(round): the mascots receive live poses")
            let snapshot = try #require(provider.latestSnapshot, "round \(round): gameplay receives body input")
            #expect(snapshot.sessionGeneration == provider.currentContext?.sessionGeneration)
            #expect(snapshot.players.values.allSatisfy { $0.trackingStatus == .reliable }, "round \(round): both players tracked")
            pump.stop()
            await provider.stop()
        }
        #expect(generations.count == 3, "every round is a fresh session")
    }
}
