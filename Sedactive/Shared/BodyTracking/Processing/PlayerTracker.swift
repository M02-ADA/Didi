import Foundation

// Processing-internal values. No camera, Vision, image resources, gameplay or CP1 API changes.
nonisolated enum PlayerTrackingError: Error, Equatable, Sendable {
  case invalidPolicy, invalidContext, staleControl, incompatibleSource, staleFrame, invalidTime
  case bindingRequiresNewGeneration
}

/// All distances are in image-height units (X is aspect corrected); durations are host-clock seconds.
/// No default/live policy is supplied. Callers must explicitly select and validate experimental values.
nonisolated struct PlayerTrackingPolicy: Equatable, Sendable {
  let minimumJointConfidence: Double  // (0, 1]; raw confidence is NOT association probability.
  let minimumTorsoExtent: Double     // Positive lower bound for torso length and paired widths.
  let minimumPairSeparation: Double  // Acquisition/duplicate ambiguity distance.
  let centerGuardFraction: Double    // [0, 0.5), canonical normalized X distance from centerline.
  let acquisitionDwell: Double       // >= 0 seconds; always requires at least two observations.
  let recoveryDwell: Double          // >= 0 seconds; always requires at least two observations.
  let maximumObservationGap: Double  // Source gap limit AND maximum confirmed-anchor prediction age.
  let recoveryWindow: Double         // Seconds since last CONFIRMED match; >= gap, > recovery dwell.
  let freshness: Double              // Positive seconds for no-frame expiry; <= observation gap.
  let maximumSpeed: Double           // Positive image heights/second; prediction velocity clamp.
  let positionGate: Double           // Positive base position gate, expanded by bounded elapsed time.
  let jointResidualGate: Double      // Positive mean shared-joint displacement gate.
  let maximumLogScaleChange: Double  // Positive |log(current torso length / previous length)| gate.
  let positionWeight: Double         // Positive dimensionless cost weight on normalized position error.
  let jointWeight: Double            // Positive cost weight on normalized shared-joint error.
  let shapeWeight: Double            // Nonnegative cost weight on normalized log scale error.
  let missingEvidencePenalty: Double // Positive cost PER missing core joint / missing shape term.
  let unmatchedCost: Double          // Positive cost of refusing one slot assignment.
  let assignmentMargin: Double       // Positive cost band; ties/near alternatives are uncertainty.
  let minimumSharedCoreJoints: Int   // 3...4; must also include a corresponding shoulder or hip pair.

  func validate() throws {
    let positive = [minimumJointConfidence, minimumTorsoExtent, minimumPairSeparation,
      maximumObservationGap, recoveryWindow, freshness, maximumSpeed, positionGate,
      jointResidualGate, maximumLogScaleChange, positionWeight, jointWeight,
      missingEvidencePenalty, unmatchedCost, assignmentMargin]
    let nonnegative = [centerGuardFraction, acquisitionDwell, recoveryDwell, shapeWeight]
    guard positive.allSatisfy({ $0.isFinite && $0 > 0 }),
      nonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }), minimumJointConfidence <= 1,
      centerGuardFraction < 0.5, (3...4).contains(minimumSharedCoreJoints),
      freshness <= maximumObservationGap, maximumObservationGap <= recoveryWindow,
      recoveryDwell < recoveryWindow, assignmentMargin < unmatchedCost,
      (positionWeight + jointWeight + shapeWeight + 5 * missingEvidencePenalty
        + 2 * unmatchedCost + assignmentMargin).isFinite,
      (positionGate + maximumSpeed * maximumObservationGap).isFinite
    else { throw PlayerTrackingError.invalidPolicy }
  }
}

/// Canonical pixels are already upright; rotation records capture's applied transform, not a second one.
nonisolated struct PlayerTrackingContext: Equatable, Sendable {
  let generation: UUID
  let epoch: UUID
  let geometryRevision: UInt64
  let imageWidth: Int
  let imageHeight: Int
  let rotationAngle: Double
  let mirrored: Bool
  fileprivate func validate() throws {
    guard geometryRevision > 0, imageWidth > 0, imageHeight > 0,
      rotationAngle == 0 || rotationAngle == 180, !mirrored else {
      throw PlayerTrackingError.invalidContext
    }
  }
}
nonisolated struct PlayerTrackingSource: Equatable, Sendable {
  let context: PlayerTrackingContext
  let frameID: UInt64
  let capturedAt: Double
  let controlRevision: UInt64
}
nonisolated struct PlayerTrackingInput: Sendable {
  let source: PlayerTrackingSource
  let frame: PoseFrame
  let observationCount: Int  // Total SDK observations, including those omitted by the B1 cap.
}
nonisolated enum PlayerTrackingState: String, Sendable { case unbound, tracking, uncertain, lost }
nonisolated enum PlayerTrackingReason: String, Sendable {
  case disarmed, acquiring, acquisitionRefused, matched, missingOrWeak, ambiguous
  case recovering, overflow, expired, observationGap, inferenceFailed, invalidated
}
nonisolated struct PlayerTrackingSlotResult: Equatable, Sendable {
  let state: PlayerTrackingState
  let reason: PlayerTrackingReason
  let candidateID: UInt64?  // Refers ONLY to this result's exact source frame.
  let cost: Double?
  let requiresRebind: Bool
  let lastConfirmedAt: Double? // Read-only history watermark; tentative/refused matches never advance it.
}
nonisolated struct PlayerTrackingSnapshot: Equatable, Sendable {
  let source: PlayerTrackingSource? // Nil after reset/invalidation; expiry never fabricates a source.
  let evaluatedAt: Double?
  let controlRevision: UInt64
  let player1: PlayerTrackingSlotResult
  let player2: PlayerTrackingSlotResult
  let assignmentCount: Int
  let confirmedDescriptorCount: Int
  let provisionalDescriptorCount: Int
  subscript(_ id: PlayerID) -> PlayerTrackingSlotResult {
    id == .player1 ? player1 : player2
  }
}

/// Pure bounded value core. Later composition owns ONE instance on the existing processing worker.
/// A Sendable value is transferable, not concurrently mutable; no tasks, clocks, streams or image owners.
nonisolated struct PlayerTracker: Sendable {
  static let maximumCandidates = 8 // Same retained-value cap as B1; overflow refuses association.
  private static let core: [BodyJoint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
  let policy: PlayerTrackingPolicy
  private var context: PlayerTrackingContext?
  private var revision: UInt64 = 0
  private var armed = false
  /// DEBUG Solo Test: acquire exactly one person into P1; P2 stays unbound (never fabricated).
  private var solo = false
  private var lastBoundGeneration: UUID?
  private var lastSource: PlayerTrackingSource?
  private var evaluatedAt: Double?
  private var slots = [Slot(), Slot()]
  private var assignmentCount = 0

  init(policy: PlayerTrackingPolicy) throws {
    try policy.validate()
    self.policy = policy
  }

  /// Caller authorizes context and strictly increasing control revision. Never creates a generation.
  /// Generation UUIDs must not be reused by the future lifecycle owner (no unbounded UUID registry here).
  mutating func reset(context: PlayerTrackingContext, controlRevision: UInt64) throws {
    try context.validate()
    guard controlRevision > revision else { throw PlayerTrackingError.staleControl }
    self.context = context
    revision = controlRevision
    clear()
  }
  mutating func invalidate(controlRevision: UInt64) throws {
    guard controlRevision > revision else { throw PlayerTrackingError.staleControl }
    revision = controlRevision
    context = nil
    clear(reason: .invalidated)
  }
  private mutating func clear(reason: PlayerTrackingReason = .disarmed) {
    armed = false
    lastSource = nil
    evaluatedAt = nil
    slots = [Slot(), Slot()]
    for i in slots.indices { slots[i].reason = reason }
    assignmentCount = 0
  }
  mutating func armBinding(controlRevision: UInt64, solo: Bool = false) throws {
    guard controlRevision == revision, let context else { throw PlayerTrackingError.staleControl }
    guard context.generation != lastBoundGeneration else {
      throw PlayerTrackingError.bindingRequiresNewGeneration
    }
    #if !DEBUG
    guard !solo else { throw PlayerTrackingError.incompatibleSource }
    #endif
    // An idempotent repeated arm must not restart an existing acquisition dwell.
    armed = true
    self.solo = solo
  }

  @discardableResult
  mutating func process(_ input: PlayerTrackingInput) throws -> PlayerTrackingSnapshot {
    try validate(input.source)
    let s = input.source, f = input.frame
    guard f.sessionGeneration == s.context.generation, f.frameID == s.frameID,
      f.capturedAt == s.capturedAt, f.cameraGeometryRevision == s.context.geometryRevision,
      f.imageWidth == s.context.imageWidth, f.imageHeight == s.context.imageHeight,
      input.observationCount >= 0, f.candidates.count <= Self.maximumCandidates,
      f.candidates.count == min(input.observationCount, Self.maximumCandidates)
    else { throw PlayerTrackingError.incompatibleSource }
    try f.validate() // Check the bounded candidate count before traversing its joint dictionaries.
    // Everything above is transactional: rejected input has no effect on dwell/history/source.
    let sourceGap = lastSource.map { s.capturedAt - $0.capturedAt > policy.maximumObservationGap } ?? false
    lastSource = s
    evaluatedAt = s.capturedAt
    assignmentCount = 0
    let descriptors = f.candidates.map { descriptor($0, at: s.capturedAt, context: s.context) }
    if slots.allSatisfy({ $0.state == .unbound }) {
      acquire(descriptors, overflow: input.observationCount > f.candidates.count, source: s)
    } else {
      associate(descriptors, overflow: input.observationCount > f.candidates.count,
        at: s.capturedAt, sourceGap: sourceGap)
    }
    return snapshot
  }

  /// A real inference failure consumes its original source identity, but supplies no invented pose.
  @discardableResult
  mutating func inferenceFailed(source: PlayerTrackingSource) throws -> PlayerTrackingSnapshot {
    try validate(source)
    let gap = lastSource.map { source.capturedAt - $0.capturedAt > policy.maximumObservationGap } ?? false
    lastSource = source
    evaluatedAt = source.capturedAt
    assignmentCount = 0
    for i in slots.indices {
      refuse(i, at: source.capturedAt, reason: gap ? .observationGap : .inferenceFailed, lost: gap)
    }
    return snapshot
  }

  /// Deterministic no-frame expiry. The caller injects host-clock seconds; GameClock is not used.
  @discardableResult
  mutating func expire(at time: Double, controlRevision: UInt64) throws -> PlayerTrackingSnapshot {
    guard controlRevision == revision, context != nil else { throw PlayerTrackingError.staleControl }
    guard time.isFinite, time >= 0, time >= (evaluatedAt ?? 0) else {
      throw PlayerTrackingError.invalidTime
    }
    evaluatedAt = time
    assignmentCount = 0
    for i in slots.indices {
      if let confirmed = slots[i].confirmed, time - confirmed.time >= policy.freshness {
        refuse(i, at: time, reason: .expired)
      } else if slots[i].state == .unbound,
        let pending = slots[i].provisional, time - pending.latest.time > policy.maximumObservationGap {
        slots[i].provisional = nil
      }
    }
    return snapshot
  }

  var snapshot: PlayerTrackingSnapshot {
    PlayerTrackingSnapshot(source: lastSource, evaluatedAt: evaluatedAt, controlRevision: revision,
      player1: slots[0].result, player2: slots[1].result, assignmentCount: assignmentCount,
      confirmedDescriptorCount: slots.reduce(0) { $0 + ($1.confirmed == nil ? 0 : 1)
        + ($1.previous == nil ? 0 : 1) },
      provisionalDescriptorCount: slots.filter { $0.provisional != nil }.count)
  }

  private func validate(_ source: PlayerTrackingSource) throws {
    guard source.controlRevision == revision, context != nil else {
      throw PlayerTrackingError.staleControl
    }
    guard source.context == context else { throw PlayerTrackingError.incompatibleSource }
    guard source.frameID > 0, source.capturedAt.isFinite, source.capturedAt >= 0 else {
      throw PlayerTrackingError.invalidTime
    }
    guard source.frameID > (lastSource?.frameID ?? 0),
      lastSource == nil || source.capturedAt > lastSource!.capturedAt,
      source.capturedAt >= (evaluatedAt ?? 0) else { throw PlayerTrackingError.staleFrame }
  }

  private struct Point: Sendable {
    let x: Double, y: Double
    static func distance(_ a: Self, _ b: Self) -> Double { hypot(a.x - b.x, a.y - b.y) }
  }
  private struct Descriptor: Sendable {
    let id: UInt64, time: Double
    let points: [BodyJoint: PoseJoint] // At most four core joints; coordinates are aspect corrected.
    let scale: Double?
    var center: Point {
      let ordered = PlayerTracker.core.compactMap { points[$0] }
      return Point(x: ordered.reduce(0) { $0 + $1.x } / Double(ordered.count),
        y: ordered.reduce(0) { $0 + $1.y } / Double(ordered.count))
    }
  }
  private struct Provisional: Sendable {
    let since: Double
    let latest: Descriptor
  }
  private struct Slot: Sendable {
    var state: PlayerTrackingState = .unbound
    var reason: PlayerTrackingReason = .disarmed
    var previous: Descriptor?
    var confirmed: Descriptor?
    var provisional: Provisional?
    var candidateID: UInt64?
    var cost: Double?
    var identityAmbiguous = false // Monotonic until authorized reset; never seed a guessed trajectory.
    var result: PlayerTrackingSlotResult {
      PlayerTrackingSlotResult(state: state, reason: reason, candidateID: candidateID, cost: cost,
        requiresRebind: state == .lost || identityAmbiguous, lastConfirmedAt: confirmed?.time)
    }
  }
  private func descriptor(_ candidate: PoseCandidate, at time: Double,
    context: PlayerTrackingContext) -> Descriptor? {
    var points: [BodyJoint: PoseJoint] = [:]
    let aspect = Double(context.imageWidth) / Double(context.imageHeight)
    for joint in Self.core {
      if let p = candidate.joints[joint], p.confidence >= policy.minimumJointConfidence {
        points[joint] = PoseJoint(x: p.x * aspect, y: p.y, confidence: p.confidence)
      }
    }
    guard points.count >= policy.minimumSharedCoreJoints, hasPair(Set(points.keys)) else { return nil }
    // Partial support still needs a geometrically distinct shoulder/hip pair.
    for pair in [[BodyJoint.leftShoulder, .rightShoulder], [.leftHip, .rightHip]] {
      if let a = points[pair[0]], let b = points[pair[1]],
        hypot(a.x - b.x, a.y - b.y) < policy.minimumTorsoExtent { return nil }
    }
    var scale: Double?
    if let ls = points[.leftShoulder], let rs = points[.rightShoulder],
      let lh = points[.leftHip], let rh = points[.rightHip] {
      let shoulder = Point(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
      let hip = Point(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
      let length = Point.distance(shoulder, hip)
      guard length >= policy.minimumTorsoExtent else { return nil }
      scale = length
    }
    return Descriptor(id: candidate.candidateID, time: time, points: points, scale: scale)
  }
  private func hasPair(_ joints: Set<BodyJoint>) -> Bool {
    (joints.contains(.leftShoulder) && joints.contains(.rightShoulder))
      || (joints.contains(.leftHip) && joints.contains(.rightHip))
  }
  private func common(_ a: Descriptor, _ b: Descriptor) -> [BodyJoint] {
    Self.core.filter { a.points[$0] != nil && b.points[$0] != nil }
  }
  private func proximity(_ a: Descriptor, _ b: Descriptor) -> Double? {
    let shared = common(a, b)
    guard shared.count >= policy.minimumSharedCoreJoints, hasPair(Set(shared)) else { return nil }
    let dx = shared.reduce(0) { $0 + a.points[$1]!.x - b.points[$1]!.x } / Double(shared.count)
    let dy = shared.reduce(0) { $0 + a.points[$1]!.y - b.points[$1]!.y } / Double(shared.count)
    return hypot(dx, dy)
  }

  private enum CandidateIndependence { case distinct, overlapping, unavailable }

  /// Anchor association and current-body independence are different evidence questions.
  /// Preserve the existing duplicate metric when sufficient mutual core support exists.
  /// Option A: require comparable current core evidence, or fully observed shape distinction.
  /// Translation of a below-coverage anatomical subset cannot establish body independence.
  private func independence(_ a: Descriptor, _ b: Descriptor) -> CandidateIndependence {
    // Preserve the existing supported crossing case: two full torso shapes can be
    // distinguishable even at the same center. This is the existing shape exclusion
    // gate, not a new identity feature or a claim that size alone identifies a person.
    if let shape = shapeDifference(a, b), shape.isFinite,
      shape > policy.maximumLogScaleChange { return .distinct }
    if let distance = proximity(a, b) {
      return distance > policy.minimumPairSeparation ? .distinct : .overlapping
    }
    return .unavailable
  }

  private mutating func acquire(_ values: [Descriptor?], overflow: Bool, source: PlayerTrackingSource) {
    guard armed else { return }
    if solo { return acquireSolo(values, overflow: overflow, source: source) }
    let eligible = values.compactMap { $0 }
    guard !overflow, eligible.count == 2, eligible.allSatisfy({ $0.points.count == 4 }),
      let separation = proximity(eligible[0], eligible[1]), separation > policy.minimumPairSeparation
    else { acquisitionRefused(overflow ? .overflow : .acquisitionRefused); return }
    let aspect = Double(source.context.imageWidth) / Double(source.context.imageHeight)
    // This is acquisition-only. After binding, X ordering never chooses identity.
    let ordered = eligible.sorted { $0.center.x > $1.center.x }
    guard ordered[0].center.x / aspect > 0.5 + policy.centerGuardFraction,
      ordered[1].center.x / aspect < 0.5 - policy.centerGuardFraction
    else { acquisitionRefused(.acquisitionRefused); return }
    var continuous = true
    for i in slots.indices {
      guard let prior = slots[i].provisional,
        source.capturedAt - prior.latest.time <= policy.maximumObservationGap,
        let distance = proximity(prior.latest, ordered[i]),
        distance <= policy.positionGate,
        shapeDifference(prior.latest, ordered[i]).map({ $0 <= policy.maximumLogScaleChange }) == true
      else { continuous = false; continue }
      // An alternative initial person remains plausible: reset acquisition rather than sort through it.
      if let alternative = proximity(prior.latest, ordered[1 - i]), alternative <= policy.positionGate {
        continuous = false
      }
    }
    if continuous, slots.allSatisfy({ source.capturedAt - $0.provisional!.since >= policy.acquisitionDwell }) {
      for i in slots.indices { confirm(i, descriptor: ordered[i], cost: 0) }
      lastBoundGeneration = source.context.generation
      armed = false
    } else {
      for i in slots.indices {
        let since = continuous ? slots[i].provisional!.since : source.capturedAt
        slots[i].provisional = Provisional(since: since, latest: ordered[i])
        slots[i].reason = .acquiring
      }
    }
  }
  /// DEBUG Solo Test: exactly one fully visible person (both shoulders and hips), anywhere in
  /// the frame, held for the same acquisition dwell, becomes P1. Two people refuse (no guessing),
  /// and P2's slot is left unbound: it never receives a descriptor.
  private mutating func acquireSolo(_ values: [Descriptor?], overflow: Bool, source: PlayerTrackingSource) {
    let eligible = values.compactMap { $0 }
    guard !overflow, eligible.count == 1, let person = eligible.first, person.points.count == 4 else {
      acquisitionRefused(overflow ? .overflow : .acquisitionRefused); return
    }
    if let prior = slots[0].provisional,
      source.capturedAt - prior.latest.time <= policy.maximumObservationGap,
      let distance = proximity(prior.latest, person), distance <= policy.positionGate,
      shapeDifference(prior.latest, person).map({ $0 <= policy.maximumLogScaleChange }) == true {
      if source.capturedAt - prior.since >= policy.acquisitionDwell {
        confirm(0, descriptor: person, cost: 0)
        lastBoundGeneration = source.context.generation
        armed = false
      } else {
        slots[0].provisional = Provisional(since: prior.since, latest: person)
        slots[0].reason = .acquiring
      }
    } else {
      slots[0].provisional = Provisional(since: source.capturedAt, latest: person)
      slots[0].reason = .acquiring
    }
    slots[1].provisional = nil
  }
  private mutating func acquisitionRefused(_ reason: PlayerTrackingReason) {
    for i in slots.indices { slots[i].provisional = nil; slots[i].reason = reason }
  }
  private func shapeDifference(_ a: Descriptor, _ b: Descriptor) -> Double? {
    guard let a = a.scale, let b = b.scale else { return nil }
    return abs(log(a / b))
  }

  private enum IdentityEvidence {
    case supported(Double), excluded, unavailable
    var cost: Double? { if case let .supported(value) = self { value } else { nil } }
  }
  /// Positive eligibility is deliberately NOT checked here. A forbidden identity can still veto
  /// another person's match. Unknown/expired evidence is not the same as geometric exclusion.
  private func identityEvidence(_ slot: Slot, _ candidate: Descriptor) -> IdentityEvidence {
    guard let anchor = slot.confirmed else { return .unavailable }
    let dt = candidate.time - anchor.time
    guard dt > 0, dt <= policy.maximumObservationGap else { return .unavailable }
    let shared = common(anchor, candidate)
    guard shared.count >= policy.minimumSharedCoreJoints, hasPair(Set(shared)) else { return .unavailable }
    var dx = 0.0, dy = 0.0, residual = 0.0, weight = 0.0
    for joint in shared {
      let old = anchor.points[joint]!, new = candidate.points[joint]!
      var vx = 0.0, vy = 0.0
      if let prev = slot.previous, let p = prev.points[joint], anchor.time > prev.time {
        vx = (old.x - p.x) / (anchor.time - prev.time)
        vy = (old.y - p.y) / (anchor.time - prev.time)
        let speed = hypot(vx, vy)
        if speed > policy.maximumSpeed { vx *= policy.maximumSpeed / speed; vy *= policy.maximumSpeed / speed }
      }
      let x = new.x - (old.x + vx * dt), y = new.y - (old.y + vy * dt)
      dx += x; dy += y
      let w = min(old.confidence, new.confidence)
      residual += hypot(x, y) * w
      weight += w
    }
    let distance = hypot(dx, dy) / Double(shared.count)
    let meanResidual = residual / weight
    let gate = policy.positionGate + policy.maximumSpeed * dt
    guard distance.isFinite, meanResidual.isFinite else { return .unavailable }
    guard distance <= gate, meanResidual <= policy.jointResidualGate else { return .excluded }
    let shape = shapeDifference(anchor, candidate)
    if let shape, !shape.isFinite { return .unavailable }
    if let shape, shape > policy.maximumLogScaleChange { return .excluded }
    let shapeCost = shape.map { policy.shapeWeight * $0 / policy.maximumLogScaleChange }
      ?? policy.missingEvidencePenalty
    let cost = policy.positionWeight * distance / gate
      + policy.jointWeight * meanResidual / policy.jointResidualGate + shapeCost
      + Double(4 - shared.count) * policy.missingEvidencePenalty
    return cost.isFinite ? .supported(cost) : .unavailable
  }
  private struct Hypothesis {
    let a: Int?, b: Int?
    let cost: Double
    subscript(_ index: Int) -> Int? { index == 0 ? a : b }
  }
  private enum FrameProposal {
    case none
    case refuse(PlayerTrackingReason, latch: Bool)
    case candidate(Int, cost: Double)
  }

  private mutating func associate(_ values: [Descriptor?], overflow: Bool, at time: Double,
    sourceGap: Bool) {
    // A — Evaluate from a frame-local baseline. No permanent identity/history mutation.
    var baseline = slots
    for i in baseline.indices {
      baseline[i].candidateID = nil
      baseline[i].cost = nil
      if sourceGap {
        baseline[i] = refused(baseline[i], at: time, reason: .observationGap, lost: true)
      } else if let confirmed = baseline[i].confirmed, time - confirmed.time >= policy.recoveryWindow {
        baseline[i] = refused(baseline[i], at: time, reason: .expired, lost: true)
      }
    }
    guard !overflow else {
      slots = baseline.map { refused($0, at: time, reason: .overflow) }
      return
    }
    let candidates = values.compactMap { $0 }
    let evidence = baseline.map { slot in candidates.map { identityEvidence(slot, $0) } }
    let costs = evidence.map { $0.map(\.cost) }
    // Identity hypotheses include lost/latched people, even though they cannot receive output.
    let options: [Int?] = [nil] + candidates.indices.map { Optional($0) }
    var hypotheses: [Hypothesis] = [] // At most 73, never a retained trajectory history.
    for a in options { for b in options {
      if let a, let b, a == b { continue }
      if let a, costs[0][a] == nil { continue }
      if let b, costs[1][b] == nil { continue }
      let first = a.map { costs[0][$0]! } ?? policy.unmatchedCost
      let second = b.map { costs[1][$0]! } ?? policy.unmatchedCost
      hypotheses.append(Hypothesis(a: a, b: b, cost: first + second))
    } }
    assignmentCount = hypotheses.count
    let best = hypotheses.map(\.cost).min()!
    let plausible = hypotheses.filter { $0.cost <= best + policy.assignmentMargin }
    let contested = candidates.indices.contains { candidate in
      plausible.contains { $0.a == candidate } && plausible.contains { $0.b == candidate }
    }
    if contested {
      slots = baseline.map { refused($0, at: time, reason: .ambiguous, lost: true) }
      return
    }
    var proposals = [FrameProposal.none, .none]
    for i in baseline.indices {
      guard baseline[i].state != .lost else { continue }
      guard !baseline[i].identityAmbiguous else {
        proposals[i] = .refuse(.ambiguous, latch: false)
        continue
      }
      let choices = Set(plausible.map { $0[i] })
      guard choices.count == 1, let onlyChoice = choices.first, let choice = onlyChoice,
        let cost = costs[i][choice] else {
        proposals[i] = .refuse(choices.count > 1 ? .ambiguous : .missingOrWeak,
          latch: choices.compactMap({ $0 }).count > 1)
        continue
      }
      var duplicate = false, unknownCompetitor = false
      for j in candidates.indices where j != choice && costs[i][j] != nil {
        switch independence(candidates[choice], candidates[j]) {
        case .distinct: break
        case .overlapping: duplicate = true
        case .unavailable: unknownCompetitor = true
        }
      }
      if duplicate { proposals[i] = .refuse(.ambiguous, latch: true) }
      else if unknownCompetitor { proposals[i] = .refuse(.ambiguous, latch: false) }
      else { proposals[i] = .candidate(choice, cost: cost) }
    }

    // B — Resolve BOTH decisions against immutable evidence, before any confirmation can occur.
    // Exclusion is mandatory for EVERY supported competitor, regardless of past/current eligibility.
    // Thus a newly discovered refusal cannot weaken a peer's check. No fixed point is required:
    // predicates do not read proposals, loop-mutated slot state, or another positive output.
    var resolved = proposals
    for i in baseline.indices {
      guard case let .candidate(choice, _) = proposals[i] else { continue }
      let other = 1 - i
      var safe = true, latch = false
      // Even mutually exclusive anchor edges do not alone establish two independent bodies.
      // Both proposals read the same pair evidence; no slot's commit can bypass this gate.
      if case let .candidate(peer, _) = proposals[other] {
        switch independence(candidates[choice], candidates[peer]) {
        case .distinct: break
        case .overlapping: safe = false; latch = true
        case .unavailable: safe = false
        }
      }
      switch evidence[other][choice] {
      case .excluded:
        break
      case .unavailable:
        if baseline[other].confirmed != nil { safe = false; latch = true }
      case .supported:
        for hypothesis in plausible {
          guard let independent = hypothesis[other], independent != choice else {
            safe = false; latch = true; continue
          }
          // An independent-body explanation must also have a usable reverse comparison.
          // Otherwise an unknown cross-identity edge could create a circular justification.
          if case .unavailable = evidence[i][independent] {
            safe = false; latch = true; continue
          }
          switch independence(candidates[choice], candidates[independent]) {
          case .distinct: break
          case .overlapping: safe = false; latch = true
          case .unavailable: safe = false
          }
        }
      }
      if !safe { resolved[i] = .refuse(.ambiguous, latch: latch) }
    }

    // C — Commit the whole frame once. Recovery uses its existing capture-time dwell; tentative,
    // refused and lost outcomes retain the baseline confirmed descriptors and watermarks.
    var committed = baseline
    for i in baseline.indices {
      switch resolved[i] {
      case .none: break
      case let .refuse(reason, latch):
        committed[i] = refused(baseline[i], at: time, reason: reason, latch: latch)
      case let .candidate(choice, cost):
        committed[i] = baseline[i].state == .tracking
          ? confirmed(baseline[i], descriptor: candidates[choice], cost: cost)
          : recovered(baseline[i], descriptor: candidates[choice], cost: cost)
      }
    }
    slots = committed
  }
  private func confirmed(_ slot: Slot, descriptor: Descriptor, cost: Double) -> Slot {
    var value = slot
    value.previous = slot.confirmed
    value.confirmed = descriptor
    value.provisional = nil
    value.state = .tracking
    value.reason = .matched
    value.candidateID = descriptor.id
    value.cost = cost
    return value
  }
  private mutating func confirm(_ index: Int, descriptor: Descriptor, cost: Double) {
    slots[index] = confirmed(slots[index], descriptor: descriptor, cost: cost)
  }
  private func recovered(_ slot: Slot, descriptor: Descriptor, cost: Double) -> Slot {
    guard let anchor = slot.confirmed,
      descriptor.time - anchor.time < policy.recoveryWindow else {
      return refused(slot, at: descriptor.time, reason: .expired, lost: true)
    }
    var value = slot
    if let provisional = slot.provisional,
      descriptor.time - provisional.latest.time <= policy.maximumObservationGap,
      let distance = proximity(provisional.latest, descriptor), distance <= policy.positionGate {
      if descriptor.time - provisional.since >= policy.recoveryDwell {
        return confirmed(slot, descriptor: descriptor, cost: cost)
      }
      value.provisional = Provisional(since: provisional.since, latest: descriptor)
    } else {
      value.provisional = Provisional(since: descriptor.time, latest: descriptor)
    }
    value.reason = .recovering
    value.candidateID = nil
    value.cost = nil
    return value
  }
  private func refused(_ slot: Slot, at time: Double, reason: PlayerTrackingReason,
    lost: Bool = false, latch: Bool = false) -> Slot {
    var value = slot
    value.candidateID = nil
    value.cost = nil
    value.provisional = nil
    if slot.state == .unbound {
      value.reason = reason
      return value
    }
    guard slot.state != .lost else { return value }
    value.identityAmbiguous = slot.identityAmbiguous || latch
    let expired = slot.confirmed.map { time - $0.time >= policy.recoveryWindow } ?? true
    value.state = lost || expired ? .lost : .uncertain
    value.reason = reason
    return value
  }
  private mutating func refuse(_ index: Int, at time: Double, reason: PlayerTrackingReason,
    lost: Bool = false) {
    slots[index] = refused(slots[index], at: time, reason: reason, lost: lost)
  }
}
