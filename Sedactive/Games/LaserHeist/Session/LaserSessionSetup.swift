import Foundation
import Observation

/// A consumer-side port over Edo's existing controls. It adds no producer contract or baseline store.
@MainActor
protocol LaserSetupControlling: AnyObject {
    var provider: any BodyInputProviding { get }
    var tracking: CameraTrackingDiagnostics { get }
    var calibration: StandingCalibrationProgress { get }
    var acceptedRevision: UInt64 { get }
    func makeBindingRequest() throws -> CameraBindingRequest
    func armBinding(_ request: CameraBindingRequest) throws
    func cancelBinding()
    func requestCalibration(id: UUID) throws -> CalibrationRequest
    func cancelCalibration(_ request: CalibrationRequest)
    func confirmCandidate(_ id: UUID, expectedRevision: UInt64) throws -> BodyInputContext
}

/// Uses the retained live provider and its one tracker; no new camera, observer, or CP1 reader.
@MainActor
final class LaserLiveSetupControls: LaserSetupControlling {
    let service: BodyInputService
    init(service: BodyInputService) { self.service = service }
    var provider: any BodyInputProviding { service }
    var tracking: CameraTrackingDiagnostics { service.camera.frames.tracking.snapshot }
    var calibration: StandingCalibrationProgress { service.calibrationProgress }
    var acceptedRevision: UInt64 { service.acceptedContextRevision }
    func makeBindingRequest() throws -> CameraBindingRequest { try service.makeBindingRequest() }
    func armBinding(_ request: CameraBindingRequest) throws { try service.armBinding(request) }
    func cancelBinding() { service.cancelBinding() }
    func requestCalibration(id: UUID) throws -> CalibrationRequest { try service.requestStandingCalibration(id: id) }
    func cancelCalibration(_ request: CalibrationRequest) { service.cancelStandingCalibration(request) }
    func confirmCandidate(_ id: UUID, expectedRevision: UInt64) throws -> BodyInputContext {
        try service.confirmStandingCandidate(id, expectedContextRevision: expectedRevision)
    }
}

nonisolated enum LaserSetupPhase: Equatable, Sendable {
    case inactive, awaitingBinding, binding, confirmPlayers, waitingForReliablePair
    case awaitingCalibration, calibrating, reviewCandidate, awaitingGameplayReadiness
    case blocked(String), restartRequired
}

/// Request/confirmation state only. The producer remains the authority for identity and calibration.
@MainActor @Observable
final class LaserSessionSetup {
    private struct Binding: Equatable {
        let request: UUID
        let context: PlayerTrackingContext
        let revision: UInt64
    }
    private struct CandidateTicket {
        let id: UUID
        let request: CalibrationRequest
        let binding: Binding
        let acceptedRevision: UInt64
    }
    private let controls: any LaserSetupControlling
    private let generation: UUID
    private var active = false
    private var bindingRequest: CameraBindingRequest?
    private var bindingRevision: UInt64?
    private var confirmed: Binding?
    private var calibrationRequest: CalibrationRequest?
    private var calibrationRevision: UInt64?
    private var candidateTicket: CandidateTicket?
    private(set) var phase: LaserSetupPhase = .inactive
    private(set) var sampleCount = 0
    private(set) var reason = ""

    init(controls: any LaserSetupControlling, generation: UUID) {
        self.controls = controls
        self.generation = generation
    }

    func activate() { active = true; phase = .awaitingBinding; refresh() }

    /// Called only for an explicit player intent. Repeated Arm uses the exact same opaque receipt.
    func beginBinding() throws {
        guard active, controls.provider.currentContext?.sessionGeneration == generation,
              controls.provider.currentContext?.isActive == true else { throw LiveVisionError.inactiveSource }
        if bindingRequest == nil {
            bindingRequest = try controls.makeBindingRequest()
            bindingRevision = controls.tracking.revision
        }
        guard let request = bindingRequest else { throw LiveVisionError.invalidRequest }
        do {
            try controls.armBinding(request)
            bindingRevision = controls.tracking.revision
            refresh()
        } catch {
            if case PlayerTrackingError.bindingRequiresNewGeneration = error { phase = .restartRequired }
            else { phase = .blocked(String(describing: error)) }
            throw error
        }
    }

    func confirmPlayers() throws {
        refresh()
        guard let binding = currentReliableBinding() else { throw LiveVisionError.staleEvidence }
        confirmed = binding
        refresh()
    }

    /// Request tokens, including cancellation, are always the producer's originals.
    func requestCalibration(id: UUID) throws {
        refresh()
        guard let binding = currentReliableBinding(), confirmed == binding else {
            throw LiveVisionError.invalidRequest
        }
        if let request = calibrationRequest {
            guard request.id == id else { throw LiveVisionError.invalidRequest }
            return
        }
        let revision = controls.acceptedRevision
        let request = try controls.requestCalibration(id: id)
        guard controls.acceptedRevision == revision else {
            controls.cancelCalibration(request)
            throw LiveVisionError.contextConflict
        }
        calibrationRequest = request
        calibrationRevision = revision
        candidateTicket = nil
        refresh()
    }

    func cancelCalibration() {
        let request = calibrationRequest
        calibrationRequest = nil
        calibrationRevision = nil
        candidateTicket = nil
        if let request { controls.cancelCalibration(request) }
        refresh()
    }

    func confirmCandidate(id: UUID) throws {
        refresh()
        guard phase == .reviewCandidate, let ticket = candidateTicket, ticket.id == id,
              calibrationRequest == ticket.request, currentReliableBinding() == ticket.binding,
              confirmed == ticket.binding, controls.acceptedRevision == ticket.acceptedRevision else {
            throw LiveVisionError.staleEvidence
        }
        do {
            let committed = try controls.confirmCandidate(id, expectedRevision: ticket.acceptedRevision)
            guard committed == controls.provider.currentContext, committed.isActive,
                  committed.sessionGeneration == generation,
                  PlayerID.allCases.allSatisfy({ committed.calibrationRevisions[$0] != nil }) else {
                throw LiveVisionError.contextConflict
            }
            calibrationRequest = nil
            calibrationRevision = nil
            candidateTicket = nil
            refresh()
        } catch {
            phase = .blocked(String(describing: error))
            throw error
        }
    }

    /// Safe in the coordinator's existing status callback: reads only, no reentrant producer control.
    func refresh() {
        guard active else { return }
        guard let context = controls.provider.currentContext, context.isActive,
              context.sessionGeneration == generation else {
            confirmed = nil; candidateTicket = nil; calibrationRequest = nil; calibrationRevision = nil
            phase = .restartRequired
            return
        }
        guard bindingRequest != nil else { phase = .awaitingBinding; return }
        let tracking = controls.tracking
        guard tracking.requestID == bindingRequest?.requestID, tracking.revision == bindingRevision else {
            confirmed = nil; candidateTicket = nil; calibrationRequest = nil; calibrationRevision = nil
            phase = .restartRequired
            return
        }
        if [tracking.latest?.player1, tracking.latest?.player2].contains(where: { $0?.requiresRebind == true }) {
            confirmed = nil; candidateTicket = nil; calibrationRequest = nil; calibrationRevision = nil
            phase = .restartRequired
            return
        }
        guard let binding = currentReliableBinding() else {
            candidateTicket = nil
            phase = tracking.acknowledgment == nil ? .binding : .waitingForReliablePair
            return
        }
        guard confirmed == binding else { phase = .confirmPlayers; return }
        if PlayerID.allCases.allSatisfy({ context.calibrationRevisions[$0] != nil }) {
            phase = .awaitingGameplayReadiness // J03 still checks evidence, settling, and all blockers.
            return
        }
        guard let request = calibrationRequest else { phase = .awaitingCalibration; return }
        guard calibrationRevision == controls.acceptedRevision else {
            candidateTicket = nil
            phase = .blocked("Accepted calibration context changed during collection")
            return
        }
        let progress = controls.calibration
        sampleCount = progress.sampleCount
        reason = progress.reason
        guard progress.request == request else {
            calibrationRequest = nil; calibrationRevision = nil; candidateTicket = nil
            phase = .blocked(progress.reason)
            return
        }
        guard let candidate = progress.candidate, progress.phase == .candidateReady else {
            switch progress.phase {
            case .cancelled, .expired, .stoppedForReview:
                calibrationRequest = nil; calibrationRevision = nil; candidateTicket = nil; phase = .blocked(progress.reason)
            default: phase = .calibrating
            }
            return
        }
        guard candidate.admission.request == request,
              candidate.admission.bindingRequest == binding.request,
              candidate.admission.bindingRevision == binding.revision,
              candidate.admission.source.generation == binding.context.generation,
              candidate.admission.source.epoch == binding.context.epoch,
              candidate.admission.source.geometryRevision == binding.context.geometryRevision,
              candidate.imageWidth == binding.context.imageWidth, candidate.imageHeight == binding.context.imageHeight,
              candidate.rotationAngle == binding.context.rotationAngle, candidate.mirrored == binding.context.mirrored else {
            candidateTicket = nil; phase = .blocked("Calibration source changed")
            return
        }
        if candidateTicket?.id != candidate.id {
            candidateTicket = CandidateTicket(id: candidate.id, request: request, binding: binding,
                                             acceptedRevision: controls.acceptedRevision)
        }
        guard candidateTicket?.acceptedRevision == controls.acceptedRevision else {
            phase = .blocked("Accepted calibration context changed")
            return
        }
        guard candidate.hasValidatedAnatomy else {
            phase = .blocked("Crown and soles still require validated anatomical evidence")
            return
        }
        phase = .reviewCandidate
    }

    func close() {
        active = false
        phase = .inactive
        let calibration = calibrationRequest
        let tracking = controls.tracking
        let ownsBinding = bindingRequest != nil && tracking.revision == bindingRevision
            && (tracking.requestID == nil || tracking.requestID == bindingRequest?.requestID)
        calibrationRequest = nil; calibrationRevision = nil; candidateTicket = nil; confirmed = nil; bindingRequest = nil
        if let calibration { controls.cancelCalibration(calibration) }
        if ownsBinding { controls.cancelBinding() }
    }

    private func currentReliableBinding() -> Binding? {
        guard active, let context = controls.provider.currentContext, context.isActive,
              context.sessionGeneration == generation, let request = bindingRequest,
              let revision = bindingRevision else { return nil }
        let tracking = controls.tracking
        guard tracking.requestID == request.requestID, tracking.revision == revision,
              let ack = tracking.acknowledgment, ack.requestID == request.requestID,
              ack.source.controlRevision == revision,
              let latest = tracking.latest, let source = latest.source,
              latest.controlRevision == revision, source.controlRevision == revision,
              source.context == ack.source.context, source.context.generation == generation,
              source.context.geometryRevision == context.cameraGeometryRevision,
              source.frameID >= ack.source.frameID, source.capturedAt >= ack.source.capturedAt,
              [ack.player1, ack.player2, latest.player1, latest.player2].allSatisfy({
                  $0.state == .tracking && !$0.requiresRebind
              }) else { return nil }
        return Binding(request: request.requestID, context: source.context, revision: revision)
    }
}
