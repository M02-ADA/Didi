//
//  ReplayBodyInput.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// Versioned synthetic source. These are transport records, never gameplay outcomes.
nonisolated struct ReplayRecord: Equatable, Sendable, Codable {
    let deliveredAt: Double
    let snapshot: BodySnapshot?
    let status: BodyInputStatus?
    let cameraGeometryRevision: UInt64?

    init(deliveredAt: Double, snapshot: BodySnapshot? = nil, status: BodyInputStatus? = nil,
         cameraGeometryRevision: UInt64? = nil) {
        self.deliveredAt = deliveredAt
        self.snapshot = snapshot
        self.status = status
        self.cameraGeometryRevision = cameraGeometryRevision
    }
}

nonisolated struct ReplayFixture: Equatable, Sendable, Codable {
    let schemaVersion: Int
    let profiles: [Player]
    let configuration: BodyInputConfiguration
    let cameraGeometryRevision: UInt64
    let records: [ReplayRecord]

    static func decode(_ data: Data) throws -> Self {
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        try fixture.validate()
        return fixture
    }

    func validate() throws {
        try requireBodyValue(schemaVersion == 1 && cameraGeometryRevision > 0, "fixture version/geometry")
        try configuration.validate()
        for profile in profiles { try profile.validate() }
        let ids = Set(profiles.map(\.id))
        try requireBodyValue(ids.count == profiles.count && Set(configuration.selectedPlayers.ids).isSubset(of: ids),
                             "fixture profiles")
        var previousTime = 0.0
        var previousGeometry = cameraGeometryRevision
        // Finite fixture validation, not a growing runtime history or diagnostics archive.
        var observations: [UUID: [UInt64: BodySnapshot]] = [:]
        for record in records {
            try requireBodyValue(record.deliveredAt.isFinite && record.deliveredAt >= previousTime, "delivery order")
            previousTime = record.deliveredAt
            let payloadCount = (record.snapshot == nil ? 0 : 1) + (record.status == nil ? 0 : 1)
                + (record.cameraGeometryRevision == nil ? 0 : 1)
            try requireBodyValue(payloadCount == 1, "one replay payload")
            if let revision = record.cameraGeometryRevision {
                try requireBodyValue(revision >= previousGeometry, "camera geometry revision cannot regress")
                previousGeometry = revision
            }
            if let snapshot = record.snapshot {
                try snapshot.validate()
                try requireBodyValue(snapshot.capturedAt <= record.deliveredAt, "capture precedes delivery")
                if let previous = observations[snapshot.sessionGeneration]?[snapshot.frameID], previous != snapshot {
                    throw BodyInputContractError.conflictingObservation
                }
                observations[snapshot.sessionGeneration, default: [:]][snapshot.frameID] = snapshot
            }
        }
    }
}

/// CP1's synthetic producer. No camera, game clock, renderer, timer or wall-clock reads.
@MainActor
final class ReplayBodyInput: BodyInputProviding {
    let fixture: ReplayFixture
    private(set) var latestSnapshot: BodySnapshot?
    private(set) var status: BodyInputStatus = .stopped
    private(set) var diagnostics = BodyInputDiagnostics()
    private(set) var now = 0.0
    private(set) var delivery: BodyInputDelivery = .closed
    private(set) var progress: BodyInputProgress = .waiting

    private var configuration: BodyInputConfiguration?
    private var cameraRevision: UInt64
    private var cutovers: [PlayerID: BodyInputCutover] = [:]
    // Generation identity must never be reused within this provider's lifetime.
    // This stores only UUIDs, not samples or an unbounded frame/event queue.
    private var usedGenerations: Set<UUID> = []
    private var cursor = 0
    private var active = false
    private var lastProgressAt: Double?
    private var stream: AsyncStream<BodySnapshot>?
    private var continuation: AsyncStream<BodySnapshot>.Continuation?
    private(set) var subscriptionToken: UUID?
    private var observer: (@MainActor (BodyInputStatusEvent) -> Void)?
    private var observerToken: UUID?
    private var notifying = false
    private var statusRevision: UInt64 = 0
    private var statusOccurredAt = 0.0

    init(fixture: ReplayFixture) throws {
        try fixture.validate()
        self.fixture = fixture
        cameraRevision = fixture.cameraGeometryRevision
    }

    var currentContext: BodyInputContext? {
        guard let configuration else { return nil }
        return BodyInputContext(sessionGeneration: configuration.sessionGeneration,
                                selectedPlayers: configuration.selectedPlayers,
                                cameraGeometryRevision: cameraRevision,
                                calibrationRevisions: configuration.calibrations.mapValues(\.revision),
                                cutovers: cutovers, isActive: active && status == .running)
    }

    func start(configuration: BodyInputConfiguration) async throws {
        try checkControl()
        try configuration.validate()
        if active {
            guard self.configuration == configuration else { throw BodyInputOperationError.configurationChanged }
            return
        }
        guard !usedGenerations.contains(configuration.sessionGeneration) else { throw BodyInputOperationError.generationReused }
        try validateCalibrations(configuration.calibrations, configuration: configuration,
                                 cameraRevision: fixture.cameraGeometryRevision, at: 0)
        self.configuration = configuration
        usedGenerations.insert(configuration.sessionGeneration)
        cameraRevision = fixture.cameraGeometryRevision
        cutovers = configuration.calibrations.mapValues {
            BodyInputCutover(frameID: $0.sourceFrameID, capturedAt: $0.capturedAt)
        }
        now = 0
        cursor = 0
        latestSnapshot = nil
        diagnostics = BodyInputDiagnostics()
        lastProgressAt = nil
        progress = .waiting
        active = true
        prepareStream()
        status = .starting
        notify()
        status = .running
        notify()
    }

    func stop() async {
        // Observer callbacks may request asynchronous control, never synchronous reentrant mutation.
        guard !notifying else { return }
        stopSource()
    }

    @discardableResult
    func setCalibrations(_ values: [PlayerID: PlayerCalibration], generation: UUID) async throws -> BodyInputContext {
        try checkControl()
        guard active, let configuration else { throw BodyInputOperationError.notRunning }
        guard generation == configuration.sessionGeneration else { throw BodyInputOperationError.wrongGeneration }
        let replacement = configuration.replacingCalibrations(values)
        try replacement.validate()
        try validateCalibrations(values, configuration: replacement, cameraRevision: cameraRevision, at: now)
        for (id, old) in configuration.calibrations {
            if let new = values[id], new != old {
                try requireBodyValue(new.revision > old.revision, "calibration revision must advance")
            }
        }
        if configuration.calibrations == values { return currentContext! }
        // No suspension within commit; only captures AFTER this cutover may use a changed baseline.
        let watermark = fixture.records.compactMap(\.snapshot)
            .filter { $0.sessionGeneration == generation && $0.capturedAt <= now }
            .map(\.frameID).max() ?? 0
        var newCutovers = cutovers
        for id in configuration.selectedPlayers.ids where configuration.calibrations[id] != values[id] {
            newCutovers[id] = BodyInputCutover(frameID: max(watermark, values[id]?.sourceFrameID ?? 0), capturedAt: now)
        }
        self.configuration = replacement
        cutovers = newCutovers
        latestSnapshot = nil
        lastProgressAt = nil
        progress = .waiting
        notify()
        return currentContext!
    }

    func snapshotStream(generation: UUID) throws -> AsyncStream<BodySnapshot> {
        try checkControl()
        try requireGeneration(generation)
        guard delivery != .claimed else { throw BodyInputOperationError.consumerAlreadyClaimed }
        if stream == nil { prepareStream() }
        delivery = .claimed
        notify()
        return stream!
    }

    func releaseSnapshotSubscription(generation: UUID) throws {
        try checkControl()
        try requireGeneration(generation)
        closeDelivery(reason: .released)
        notify()
    }

    @discardableResult
    func statusUpdates(_ observer: @escaping @MainActor (BodyInputStatusEvent) -> Void) throws -> UUID {
        try checkControl()
        guard self.observer == nil else { throw BodyInputOperationError.observerAlreadyRegistered }
        let token = UUID()
        self.observer = observer
        observerToken = token
        deliverCurrentEvent()
        return token
    }

    func removeStatusObserver(_ token: UUID) throws {
        try checkControl()
        if token == observerToken { observer = nil; observerToken = nil }
    }

    /// Synchronous manual scheduling: equal deliveredAt records preserve fixture order. EOF stays running.
    func advance(to time: Double) throws {
        try checkControl()
        guard active else { throw BodyInputOperationError.notRunning }
        try requireBodyValue(time.isFinite && time >= now, "replay time must advance monotonically")
        while cursor < fixture.records.count && fixture.records[cursor].deliveredAt <= time && active {
            let record = fixture.records[cursor]
            cursor += 1
            now = record.deliveredAt
            if let snapshot = record.snapshot { publish(snapshot) }
            if let status = record.status { transition(to: status) }
            if let revision = record.cameraGeometryRevision { changeCameraGeometry(to: revision) }
            investigateProgress()
        }
        now = time
        investigateProgress()
    }

    private func publish(_ snapshot: BodySnapshot) {
        guard let context = currentContext, context.accepts(snapshot) else {
            diagnostics.rejected()
            return
        }
        if latestSnapshot == nil || snapshot.frameID > latestSnapshot!.frameID { latestSnapshot = snapshot }
        // Unique late completions ARE progress; duplicate transport delivery is not.
        let duplicate = fixture.records.prefix(max(0, cursor - 1)).contains {
            $0.snapshot?.sessionGeneration == snapshot.sessionGeneration && $0.snapshot?.frameID == snapshot.frameID
        }
        if !duplicate {
            lastProgressAt = now
            if progress != .progressing { progress = .progressing; notify() }
        }
        guard let continuation else { return }
        switch continuation.yield(snapshot) {
        case .enqueued: break
        case .dropped: diagnostics.dropped()
        case .terminated: diagnostics.terminatedYield()
        @unknown default: break
        }
    }

    private func prepareStream() {
        guard let configuration else { return }
        let pair = AsyncStream<BodySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(configuration.snapshotBufferCapacity))
        let token = UUID()
        let generation = configuration.sessionGeneration
        subscriptionToken = token
        stream = pair.stream
        continuation = pair.continuation
        delivery = .prepared
        continuation?.onTermination = { @Sendable [weak self] termination in
            let reason: BodyInputTerminationReason
            switch termination {
            case .cancelled: reason = .cancelled
            case .finished: reason = .finished
            @unknown default: reason = .finished
            }
            Task { @MainActor [weak self] in
                self?.deliveryTerminated(token: token, generation: generation, reason: reason)
            }
        }
    }

    // Internal so tests can deterministically exercise a delayed callback, without sleeps/yield guesses.
    func deliveryTerminated(token: UUID, generation: UUID, reason: BodyInputTerminationReason = .cancelled) {
        guard subscriptionToken == token, configuration?.sessionGeneration == generation else { return }
        closeDelivery(reason: reason)
        notify()
    }

    private func closeDelivery(reason: BodyInputTerminationReason) {
        guard continuation != nil else { return }
        let old = continuation
        subscriptionToken = nil
        continuation = nil
        stream = nil
        delivery = .closed
        diagnostics.terminated(reason)
        old?.finish()
    }

    private func stopSource() {
        guard status != .stopped else { return }
        active = false
        latestSnapshot = nil
        progress = .waiting
        lastProgressAt = nil
        closeDelivery(reason: .stopped)
        status = .stopped
        notify()
    }

    private func transition(to newStatus: BodyInputStatus) {
        switch newStatus {
        case .stopped: stopSource(); return
        case .failed:
            active = false
            latestSnapshot = nil
            closeDelivery(reason: .failed)
        case .interrupted:
            latestSnapshot = nil
        case .running, .starting: break
        }
        status = newStatus
        lastProgressAt = nil
        progress = .waiting
        notify()
    }

    private func changeCameraGeometry(to revision: UInt64) {
        guard cameraRevision != revision, let configuration else { return }
        cameraRevision = revision
        self.configuration = configuration.replacingCalibrations([:])
        cutovers = [:]
        latestSnapshot = nil
        lastProgressAt = nil
        progress = .waiting
        notify()
    }

    private func investigateProgress() {
        guard active, status == .running, let lastProgressAt,
              case let .diagnostic(threshold) = configuration?.noProgressPolicy,
              now - lastProgressAt >= threshold, progress != .suspectedStall else { return }
        progress = .suspectedStall
        notify()
    }

    private func requireGeneration(_ generation: UUID) throws {
        guard active, let configuration else { throw BodyInputOperationError.notRunning }
        guard configuration.sessionGeneration == generation else { throw BodyInputOperationError.wrongGeneration }
    }

    private func checkControl() throws {
        if notifying { throw BodyInputOperationError.reentrantControl }
    }

    private func validateCalibrations(_ values: [PlayerID: PlayerCalibration], configuration: BodyInputConfiguration,
                                      cameraRevision: UInt64, at time: Double) throws {
        for calibration in values.values {
            try requireBodyValue(calibration.cameraGeometryRevision == cameraRevision
                                 && calibration.capturedAt <= time, "calibration camera/time context")
        }
    }

    private func notify() {
        if statusRevision < .max { statusRevision += 1 }
        statusOccurredAt = now
        deliverCurrentEvent()
    }

    private func deliverCurrentEvent() {
        guard let observer else { return }
        notifying = true
        observer(BodyInputStatusEvent(sessionGeneration: configuration?.sessionGeneration, occurredAt: statusOccurredAt,
                                      statusRevision: statusRevision, status: status, context: currentContext,
                                      delivery: delivery, progress: progress))
        notifying = false
    }
}
