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
    /// People the camera sees right now (raw, unassociated pose candidates), for setup hints only.
    var peopleInView: Int? { get }
    #if DEBUG
    // Requirements (not extension-only) so the live controls' versions are the ones called.
    var debugPeople: [(x: Double, core: [Double])] { get }
    var debugVision: String { get }
    #endif
}

extension LaserSetupControlling {
    var peopleInView: Int? { nil }
    #if DEBUG
    var debugPeople: [(x: Double, core: [Double])] { [] }
    var debugVision: String { "" }
    #endif
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
    var peopleInView: Int? {
        guard let latest = service.camera.frames.poses.snapshot.latest,
              latest.source.context == service.camera.state.context else { return nil }
        let age = CameraHostClock.now() - latest.source.capturedAt
        guard age >= 0, age < LiveAvatarPresenter.maximumPoseAge * 2 else { return 0 }
        return min(2, latest.frame.candidates.count)
    }
    #if DEBUG
    /// Vision's raw body count and the age of its latest result (DEBUG setup log).
    var debugVision: String {
        guard let latest = service.camera.frames.poses.snapshot.latest else { return "vision: no result yet" }
        return String(format: "vision: %d bodies, result %.2fs old, %d completed",
                      latest.observationCount, CameraHostClock.now() - latest.source.capturedAt,
                      service.camera.frames.poses.snapshot.statistics.completed)
    }
    /// Raw pose candidates now: mean x and shoulder/hip confidences (DEBUG setup log).
    var debugPeople: [(x: Double, core: [Double])] {
        guard let latest = service.camera.frames.poses.snapshot.latest else { return [] }
        return latest.frame.candidates.map { c in
            let core: [BodyJoint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
            let xs = core.compactMap { c.joints[$0]?.x }
            return (xs.isEmpty ? -1 : xs.reduce(0, +) / Double(xs.count), core.map { c.joints[$0]?.confidence ?? 0 })
        }
    }
    #endif
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
    /// Read-only access for the automatic driver's presence and diagnostics.
    var diagnosticControls: any LaserSetupControlling { controls }
    /// The current phase's reason text (blocked phases), for hints and diagnostics.
    var diagnosticReason: String { if case .blocked(let why) = phase { why } else { reason } }
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
    var candidateIDForConfirmation: UUID? { phase == .reviewCandidate ? candidateTicket?.id : nil }
    var canCancelCalibration: Bool { active && calibrationRequest != nil }
    var hasConfirmedReliablePair: Bool {
        guard let binding = currentReliableBinding() else { return false }
        return confirmed == binding
    }
    /// POSE-FIRST CANDIDATE (Kevin, 14 Nov 2026 — needs Jevon's review; DEBUG only): the confirmed
    /// pair is still here, each player tracked OR held by squat presence (both shoulders exactly
    /// where they were, never ambiguous, never lost). Identity loss still fails it.
    var hasConfirmedPresentPair: Bool {
        guard let binding = currentReliableBinding(allowingPresence: true) else { return false }
        return confirmed == binding
    }

    /// The players this setup links and calibrates: both, or P1 alone in a DEBUG Solo Test.
    let roster: [PlayerID]

    init(controls: any LaserSetupControlling, generation: UUID, roster: [PlayerID] = PlayerID.allCases) {
        self.controls = controls
        self.generation = generation
        self.roster = roster
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
                  roster.allSatisfy({ committed.calibrationRevisions[$0] != nil }) else {
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
            #if DEBUG
            print("[LaserSetupRestart] setup: context inactive or changed")
            #endif
            phase = .restartRequired
            return
        }
        guard bindingRequest != nil else { phase = .awaitingBinding; return }
        let tracking = controls.tracking
        guard tracking.requestID == bindingRequest?.requestID, tracking.revision == bindingRevision else {
            confirmed = nil; candidateTicket = nil; calibrationRequest = nil; calibrationRevision = nil
            #if DEBUG
            print("[LaserSetupRestart] setup: binding request/revision changed")
            #endif
            phase = .restartRequired
            return
        }
        if roster.contains(where: { tracking.latest?[$0].requiresRebind == true }) {
            #if DEBUG
            if roster == [.player1] {
                // DEBUG Solo Test: the tracker re-links the only person in view inside this same
                // binding (`PlayerTracker` solo re-link), so wait for it instead of restarting setup.
                // The players are confirmed again once tracked; calibration samples taken while
                // P1 was lost were already dropped (identity failure restarts the window).
                if phase != .waitingForReliablePair { print("[LaserSetupRestart] setup: solo P1 lost · waiting for re-link (no restart)") }
                confirmed = nil
                phase = .waitingForReliablePair
                return
            }
            #endif
            confirmed = nil; candidateTicket = nil; calibrationRequest = nil; calibrationRevision = nil
            #if DEBUG
            // Once per transition (it re-evaluates on every status read).
            if phase != .restartRequired { print("[LaserSetupRestart] setup: rebind required · " + roster.map { id in
                let slot = tracking.latest?[id]
                return "\(id.rawValue) \(slot?.state.rawValue ?? "-")/\(slot?.reason.rawValue ?? "-")"
            }.joined(separator: ", ") + " · people \(controls.peopleInView ?? -1) · \(controls.debugVision)") }
            #endif
            phase = .restartRequired
            return
        }
        guard let binding = currentReliableBinding() else {
            candidateTicket = nil
            phase = tracking.acknowledgment == nil ? .binding : .waitingForReliablePair
            return
        }
        guard confirmed == binding else { phase = .confirmPlayers; return }
        if roster.allSatisfy({ context.calibrationRevisions[$0] != nil }) {
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
        if case .refused(let why) = candidate.acceptance {
            phase = .blocked(why)
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

    private func currentReliableBinding(allowingPresence: Bool = false) -> Binding? {
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
              roster.allSatisfy({ id in
                  let bound = id == .player1 ? ack.player1 : ack.player2, now = latest[id]
                  return bound.state == .tracking && !bound.requiresRebind && !now.requiresRebind
                      && (now.state == .tracking
                          || (allowingPresence && now.state == .uncertain && now.presentCandidateID != nil))
              }) else { return nil }
        return Binding(request: request.requestID, context: source.context, revision: revision)
    }
}
