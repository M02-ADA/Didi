import Foundation
import Testing
@testable import Sedactive

@MainActor
struct LaserInputFlowTests {
    private func session(_ input: ControlledSessionInput) throws -> GameSessionCoordinator {
        let script = try LaserReplayScript.load()
        return GameSessionCoordinator(provider: input,
            inputConfiguration: script.input.configuration.replacingCalibrations([:]))
    }

    @Test func selectionAndReplayNeverConstructALiveSource() throws {
        var constructions = 0
        let flow = LaserInputFlow(makeLiveSession: { constructions += 1; return try session(ControlledSessionInput()) })
        #expect(flow.route == .selection && flow.canStartLive)
        flow.showReplay()
        #expect(flow.route == .replay && constructions == 0)
        flow.leaveReplay()
        #expect(flow.route == .selection && flow.canStartLive && constructions == 0)
    }

    @Test func liveSetupHasNoSyntheticGamePlanAndCannotBeRestartedByRouteRecreation() async throws {
        let input = ControlledSessionInput()
        var constructions = 0
        let flow = LaserInputFlow(makeLiveSession: { constructions += 1; return try session(input) })
        await flow.startLiveSetup()
        let active = try #require(flow.session)
        #expect(active.configuration == nil && active.encounters.isEmpty)
        #expect(active.state == nil && active.phase == .awaitingSetup)
        #expect(flow.route == .liveSetup && !flow.isStarting)
        await flow.startLiveSetup()
        flow.showReplay()
        #expect(flow.route == .liveSetup && constructions == 1 && input.startCount == 1)
        await flow.closeLiveSetup()
        #expect(flow.route == .selection && flow.session == nil && !flow.canStartLive)
        #expect(input.stopCount == 1 && input.releaseCount == 1)
        await flow.startLiveSetup()
        #expect(constructions == 1)
        flow.showReplay()
        #expect(flow.route == .replay)
    }

    @Test func exitDuringPermissionOrStartupJoinsOldWorkBeforeReturningToSelection() async throws {
        let input = ControlledSessionInput()
        input.suspendStart = true
        let flow = LaserInputFlow(makeLiveSession: { try session(input) })
        let start = Task { await flow.startLiveSetup() }
        await input.waitForSuspendedStart()
        let close = Task { await flow.closeLiveSetup() }
        await input.waitForStop()
        #expect(flow.isClosing && flow.route == .liveSetup)
        input.resumeStart()
        await close.value
        await start.value
        #expect(flow.route == .selection && flow.session == nil && !flow.isStarting && !flow.isClosing)
        #expect(input.currentContext?.isActive == false && !flow.canStartLive)
        #expect(flow.message?.contains("setup has ended") == true)
    }

    @Test func backgroundStopsLiveSetupWithoutAutomaticReentry() async throws {
        let input = ControlledSessionInput()
        let flow = LaserInputFlow(makeLiveSession: { try session(input) })
        await flow.startLiveSetup()
        await flow.handleBackground()
        #expect(flow.route == .selection && input.stopCount == 1)
        #expect(!flow.canStartLive && flow.session == nil)
        await flow.handleBackground()
        #expect(input.stopCount == 1)
    }

    @Test func permissionErrorHasUsefulCopyAndDoesNotOfferAnUnsafeRetry() async {
        let flow = LaserInputFlow(makeLiveSession: { throw CameraFailure.permissionDenied })
        await flow.startLiveSetup()
        #expect(flow.route == .liveSetup && flow.session == nil && !flow.isStarting)
        #expect(flow.message?.contains("Settings") == true)
        #expect(flow.message?.contains("permissionDenied") == false)
        await flow.closeLiveSetup()
        #expect(flow.route == .selection && !flow.canStartLive)
    }

    @Test func diagnosticsReserveTheSharedSourceAndAreJoinedBeforeLeaving() async throws {
        var diagnosticsStops = 0
        var constructions = 0
        let flow = LaserInputFlow(makeLiveSession: { constructions += 1; return try session(ControlledSessionInput()) },
                                 stopDiagnostics: { diagnosticsStops += 1 })
        flow.showDiagnostics()
        #expect(flow.route == .diagnostics && !flow.canStartLive)
        await flow.startLiveSetup()
        flow.showReplay()
        #expect(flow.route == .diagnostics && constructions == 0)
        await flow.closeDiagnostics()
        #expect(diagnosticsStops == 1 && flow.route == .selection && !flow.canStartLive)
        await flow.closeDiagnostics()
        #expect(diagnosticsStops == 1)
    }

    @Test func launchArgumentsKeepExplicitReplayAndPreviewRoutes() {
        #expect(LaserInputFlow.initialRoute(arguments: []) == .selection)
        #expect(LaserInputFlow.initialRoute(arguments: ["-replay"]) == .replay)
        #if DEBUG
        for argument in ["-robotDemo", "-environmentPreview", "-syntheticCutouts", "-laserPreviewSpeed",
                         "-diamondFixture", "-hudPauseMenu", "-avatarFairness", "-showWorldGuides"] {
            #expect(LaserInputFlow.initialRoute(arguments: [argument]) == .replay)
        }
        #expect(LaserInputFlow.initialRoute(arguments: ["--camera-diagnostics"]) == .diagnostics)
        #endif
    }

    @Test func calibrationCopyCannotOfferPlayOrExposeProducerErrorDetails() {
        let blocked = PlayerSetupState(phase: .blocked("epoch=123; unsupportedAnatomy"))
        #expect(blocked.action == nil && blocked.buttonTitle == nil)
        #expect(!blocked.instruction.contains("epoch") && blocked.instruction.contains("No round has started"))
        #expect(PlayerSetupState(phase: .awaitingGameplayReadiness).action == nil)
        #expect(PlayerSetupState(phase: .confirmPlayers).action == .confirmPlayers)
        #expect(PlayerSetupState(phase: .awaitingCalibration).action == .calibrate)
    }
}
