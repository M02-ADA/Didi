import Foundation
import Testing
@testable import Sedactive

@MainActor
struct LaserSessionSetupTests {
    private func session(_ controls: GateSetupControls) throws -> GameSessionCoordinator {
        let script = try LaserReplayScript.load()
        return GameSessionCoordinator(provider: controls.input,
            inputConfiguration: LiveVisionFixtures.configuration(controls.fixture.context.generation),
            configuration: script.configuration, encounters: script.encounters, setupControls: controls)
    }

    private func confirmed(_ session: GameSessionCoordinator, _ controls: GateSetupControls) throws -> LaserSessionSetup {
        let setup = try #require(session.setup)
        try setup.beginBinding()
        try controls.bindPair()
        setup.refresh()
        try setup.confirmPlayers()
        return setup
    }

    @Test func startingInputDoesNotArmOrCalibrateAndDuplicateArmReusesReceipt() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try #require(session.setup)
        #expect(setup.phase == .awaitingBinding)
        #expect(controls.bindingRequests == 0 && controls.calibrationRequests == 0)
        try setup.beginBinding()
        let request = controls.fixture.gate.snapshot.requestID
        try setup.beginBinding()
        #expect(controls.bindingRequests == 1 && controls.armCalls == 2)
        #expect(controls.fixture.gate.snapshot.requestID == request)
        #expect(setup.phase == .binding)
        #expect(throws: LiveVisionError.staleEvidence) { try setup.confirmPlayers() }
        await session.stop()
    }

    @Test func atomicAcknowledgmentStillRequiresExplicitPlayerConfirmation() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try #require(session.setup)
        try setup.beginBinding()
        try controls.bindPair()
        setup.refresh()
        #expect(setup.phase == .confirmPlayers)
        #expect(throws: LiveVisionError.invalidRequest) { try setup.requestCalibration(id: UUID()) }
        try setup.confirmPlayers()
        #expect(setup.phase == .awaitingCalibration)
        #expect(session.state == nil && session.phase == .awaitingSetup)
        await session.stop()
    }

    @Test func oldAcknowledgmentCannotConfirmAnExpiredPair() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try #require(session.setup)
        try setup.beginBinding()
        try controls.bindPair()
        #expect(controls.fixture.gate.snapshot.acknowledgment != nil)
        controls.fixture.clock.time = 1
        setup.refresh()
        #expect(setup.phase == .waitingForReliablePair)
        #expect(throws: LiveVisionError.staleEvidence) { try setup.confirmPlayers() }
        #expect(controls.calibrationRequests == 0)
        await session.stop()
    }

    @Test func cancellationUsesExactRequestAndLateCandidateCannotReturn() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        let id = UUID()
        try setup.requestCalibration(id: id)
        let request = try #require(controls.lastCalibration)
        try setup.requestCalibration(id: id)
        #expect(controls.calibrationRequests == 1)
        #expect(throws: LiveVisionError.invalidRequest) { try setup.requestCalibration(id: UUID()) }
        controls.showCandidate(validated: true)
        let candidate = try #require(controls.calibration.candidate)
        setup.cancelCalibration()
        #expect(controls.cancelledCalibration == request)
        controls.showCandidate(validated: true, id: candidate.id)
        setup.refresh()
        #expect(setup.phase == .awaitingCalibration)
        #expect(throws: LiveVisionError.staleEvidence) { try setup.confirmCandidate(id: candidate.id) }
        #expect(controls.confirmCalls == 0)
        await session.stop()
    }

    @Test func experimentalAnatomyNeverReachesAcceptanceOrGameplay() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: false)
        setup.refresh()
        let candidate = try #require(controls.calibration.candidate)
        if case .blocked = setup.phase {} else { Issue.record("Experimental anatomy must stay blocked") }
        #expect(throws: LiveVisionError.staleEvidence) { try setup.confirmCandidate(id: candidate.id) }
        #expect(controls.confirmCalls == 0)
        #expect(session.inputContext?.calibrationRevisions.isEmpty == true)
        #expect(session.state == nil && session.results.isEmpty && session.events.isEmpty)
        await session.stop()
    }

    @Test func producerAcceptanceOnlyAdvancesToGameplayReadinessReview() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true)
        setup.refresh()
        #expect(setup.phase == .reviewCandidate)
        try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        #expect(controls.confirmCalls == 1)
        #expect(setup.phase == .awaitingGameplayReadiness)
        #expect(session.inputContext?.calibrationRevisions.count == 2)
        #expect(session.phase == .awaitingSetup && session.state == nil && session.summary == nil)
        await session.stop()
    }

    @Test func candidateCannotBorrowANewerAcceptedContextRevision() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true)
        setup.refresh()
        let id = try #require(controls.calibration.candidate?.id)
        controls.acceptedRevision += 1
        #expect(throws: LiveVisionError.staleEvidence) { try setup.confirmCandidate(id: id) }
        #expect(controls.confirmCalls == 0)
        await session.stop()
    }

    @Test func candidateFromADifferentEpochIsRefused() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true, epoch: UUID())
        setup.refresh()
        #expect(throws: LiveVisionError.staleEvidence) {
            try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        }
        #expect(controls.confirmCalls == 0)
        await session.stop()
    }

    @Test func collectionCannotBorrowAnAcceptanceRevisionBeforeCandidateArrival() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.acceptedRevision += 1
        controls.showCandidate(validated: true)
        setup.refresh()
        #expect(throws: LiveVisionError.staleEvidence) {
            try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        }
        #expect(controls.confirmCalls == 0 && session.state == nil)
        await session.stop()
    }

    @Test func incompatibleCandidateImageGeometryCannotReachReview() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true, width: 640)
        setup.refresh()
        #expect(throws: LiveVisionError.staleEvidence) {
            try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        }
        #expect(controls.confirmCalls == 0)
        await session.stop()
    }

    @Test func partialProducerAcceptanceCannotBecomeReady() async throws {
        let controls = try GateSetupControls()
        controls.acceptedPlayers = [.player1]
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true)
        setup.refresh()
        #expect(throws: LiveVisionError.contextConflict) {
            try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        }
        #expect(session.state == nil && session.phase == .awaitingSetup)
        await session.stop()
    }

    @Test func stopCancelsRequestsAndOldSetupCannotArmAgain() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        try setup.requestCalibration(id: UUID())
        let request = controls.lastCalibration
        await session.stop()
        #expect(controls.cancelledCalibration == request && controls.bindingCancels == 1)
        #expect(setup.phase == .inactive)
        #expect(throws: LiveVisionError.inactiveSource) { try setup.beginBinding() }
        await session.stop()
        #expect(controls.bindingCancels == 1)
    }

    @Test func oldSetupCloseDoesNotRevokeASupersedingBindingCommand() async throws {
        let controls = try GateSetupControls()
        let session = try session(controls)
        try await session.start()
        let setup = try confirmed(session, controls)
        let new = try controls.fixture.gate.makeBindingRequest()
        setup.refresh()
        #expect(setup.phase == .restartRequired)
        setup.close()
        #expect(controls.bindingCancels == 0)
        try controls.fixture.gate.validateRequest(new)
        await session.stop()
    }
}

/// Real B2 gate/opaque request receipts, with controlled producer-only calibration results.
@MainActor
private final class GateSetupControls: LaserSetupControlling {
    let input = ControlledSessionInput()
    var fixture: TrackingIntegrationFixture
    var provider: any BodyInputProviding { input }
    var tracking: CameraTrackingDiagnostics { fixture.gate.snapshot }
    var calibration: StandingCalibrationProgress { progressOverride ?? fixture.gate.readBody().calibration }
    var acceptedRevision: UInt64 = 0
    var acceptedPlayers = PlayerID.allCases
    var bindingRequests = 0, armCalls = 0, calibrationRequests = 0, confirmCalls = 0, bindingCancels = 0
    var lastCalibration: CalibrationRequest?
    var cancelledCalibration: CalibrationRequest?
    private var progressOverride: StandingCalibrationProgress?

    init() throws {
        fixture = try TrackingIntegrationFixture()
        try fixture.gate.configureBody(LiveVisionFixtures.configuration(fixture.context.generation))
    }
    func makeBindingRequest() throws -> CameraBindingRequest {
        bindingRequests += 1
        return try fixture.gate.makeBindingRequest()
    }
    func armBinding(_ request: CameraBindingRequest) throws { armCalls += 1; try fixture.gate.arm(request: request) }
    func cancelBinding() { bindingCancels += 1; fixture.gate.revoke() }
    func requestCalibration(id: UUID) throws -> CalibrationRequest {
        calibrationRequests += 1
        let value = try fixture.gate.requestCalibration(id: id)
        lastCalibration = value
        return value
    }
    func cancelCalibration(_ request: CalibrationRequest) {
        cancelledCalibration = request
        fixture.gate.cancelCalibration(request)
        progressOverride = nil
    }
    func confirmCandidate(_ id: UUID, expectedRevision: UInt64) throws -> BodyInputContext {
        confirmCalls += 1
        guard expectedRevision == acceptedRevision, calibration.candidate?.id == id else {
            throw LiveVisionError.contextConflict
        }
        acceptedRevision += 1
        let c = fixture.context
        let context = BodyInputContext(sessionGeneration: c.generation, cameraGeometryRevision: c.geometryRevision,
            calibrationRevisions: Dictionary(uniqueKeysWithValues: acceptedPlayers.map { ($0, UInt64(1)) }),
            cutovers: [:], isActive: true)
        progressOverride = .init(request: nil, phase: .accepted, sampleCount: 10, candidate: nil, reason: "Fixture accepted")
        input.replaceContext(context)
        return context
    }
    func bindPair() throws {
        try #require(try fixture.finish(fixture.result(1, 0)))
        try #require(try fixture.finish(fixture.result(2, 0.125)))
    }
    func showCandidate(validated: Bool, id: UUID = UUID(), epoch: UUID? = nil, width: Int = 1280) {
        guard let request = lastCalibration, let binding = tracking.requestID else { return }
        let c = fixture.context
        let candidate = StandingCalibrationCandidate(id: id,
            admission: CalibrationAdmission(request: request,
                source: CameraSourceContext(generation: c.generation, epoch: epoch ?? c.epoch,
                                            geometryRevision: c.geometryRevision),
                bindingRevision: tracking.revision, bindingRequest: binding),
            firstFrameID: 1, lastFrameID: 2, firstCapturedAt: 0, lastCapturedAt: 0.125, expiresAt: 5,
            players: Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
                ($0, StandingPlayerObservation(noseY: 0.8, leftAnkleY: 0.1, rightAnkleY: 0.1,
                    hipY: 0.5, torsoLength: 0.2, originX: $0 == .player1 ? 0.75 : 0.25,
                    maskMinY: 0.05, maskMaxY: 0.9,
                    anatomy: StandingAnatomicalReferences(crownY: 0.9, leftSoleY: 0.05, rightSoleY: 0.05,
                        quality: validated ? .validated : .experimental)))
            }), imageWidth: width, imageHeight: 720, rotationAngle: 180, mirrored: false, samples: 10)
        progressOverride = .init(request: request, phase: .candidateReady, sampleCount: 10,
                                 candidate: candidate, reason: "Controlled candidate")
    }
}
