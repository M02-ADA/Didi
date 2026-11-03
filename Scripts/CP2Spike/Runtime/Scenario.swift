import Foundation

nonisolated struct ProducerSample: Sendable { let cpu: UInt64, copyCPU: UInt64, finished: UInt64 }
nonisolated struct Summary: Codable, Sendable {
  var handoffs = 0
  var offered = 0, cp1Published = 0, produced = 0, acquired = 0, completed = 0
  var supersededCaptures = 0, supersededData = 0, stale = 0, failed = 0, cancelled = 0, stalls = 0
  var peakPendingCaptures = 0, peakPendingData = 0, peakInFlight = 0, peakActiveProducers = 0
  var producerCPU: [Double] = [], copyCPU: [Double] = [], handoffMS: [Double] = [],
    returnMS: [Double] = []
  var acquireMS: [Double] = [], completionMS: [Double] = [], consumerWaitMS: [Double] = [],
    cp1ScheduleLatenessMS: [Double] = []
  var lastPresentedGeneration = 0, lastPresentedSequence = 0, lastProducedSequence = 0,
    lastPublishedSequence = 0, returned = 0
  var observationResources = ResourceSnapshot()
  var observationDurationSeconds = 0.0
}
actor CP1Publisher {
  private var count = 0
  func publish() { count += 1 }
  func value() -> Int { count }
  func reset() { count = 0 }
}
@MainActor final class Scenario {
  enum Event {
    case produced, acquired, completed, producedSequence, returned, faulted, publishedSequence,
      handoff
  }
  private struct Wait {
    let event: Event, count: Int
    let continuation: CheckedContinuation<Void, Never>
  }
  let ledger: Ledger
  let cp1 = CP1Publisher()
  private(set) var generation = 1
  private(set) var summary = Summary()
  private var capture: Request?
  private var pending: (CopiedPair, ProducerSample)?
  private var captureWaiter: CheckedContinuation<Request?, Never>?
  private var dataWaiter: CheckedContinuation<(CopiedPair, ProducerSample)?, Never>?
  private var inputClosed = false, productionClosed = false, consumerClosed = false
  private var waits: [Wait] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var permits = 0
  private var handoffGate: CheckedContinuation<Void, Never>?
  private var holdHandoff: Bool
  private var manual: Bool
  private var delayNS: UInt64
  private var aborted = false
  private var measuring = true, activeProducers = 0, inFlight = 0
  private var start: UInt64 = 0

  init(ledger: Ledger, manual: Bool = false, delayNS: UInt64 = 0, holdHandoff: Bool = false) {
    self.ledger = ledger
    self.manual = manual
    self.delayNS = delayNS
    self.holdHandoff = holdHandoff
  }
  func offer(_ request: Request, nominal: UInt64? = nil) {
    guard !aborted else { return }
    summary.offered += 1
    if let nominal { summary.cp1ScheduleLatenessMS.append(Double(tick() - nominal) / 1e6) }
    guard request.generation == generation else {
      summary.stale += 1
      return
    }
    if let waiter = captureWaiter {
      captureWaiter = nil
      waiter.resume(returning: request)
    } else {
      if capture != nil { summary.supersededCaptures += 1 }
      capture = request
      summary.peakPendingCaptures = 1
    }
  }
  func nextCapture() async -> Request? {
    if let capture {
      self.capture = nil
      return capture
    }
    if inputClosed { return nil }
    precondition(captureWaiter == nil)
    return await withCheckedContinuation { captureWaiter = $0 }
  }
  func beginProduction() {
    activeProducers += 1
    precondition(activeProducers == 1)
    summary.peakActiveProducers = max(summary.peakActiveProducers, activeProducers)
  }
  func produced(_ sample: ProducerSample, request: Request) {
    activeProducers -= 1
    precondition(activeProducers == 0)
    summary.produced += 1
    summary.lastProducedSequence = request.sequence
    if measuring {
      summary.producerCPU.append(Double(sample.cpu) / 1e6)
      summary.copyCPU.append(Double(sample.copyCPU) / 1e6)
    }
    signal()
  }
  func skipped(_ fault: Fault) {
    if fault == .cancelBefore { summary.cancelled += 1 } else { summary.failed += 1 }
    signal()
  }
  func publish(_ packet: CopiedPair, sample: ProducerSample) {
    guard packet.request.generation == generation, !consumerClosed else {
      summary.stale += 1
      return
    }
    if let waiter = dataWaiter {
      dataWaiter = nil
      waiter.resume(returning: (packet, sample))
    } else {
      if pending != nil { summary.supersededData += 1 }
      pending = (packet, sample)
      summary.peakPendingData = 1
    }
    summary.lastPublishedSequence = packet.request.sequence
    signal()
  }
  func nextData() async -> (CopiedPair, ProducerSample)? {
    if let pending {
      self.pending = nil
      return pending
    }
    if productionClosed { return nil }
    precondition(dataWaiter == nil)
    return await withCheckedContinuation { dataWaiter = $0 }
  }
  func beforeAcquire() async {
    summary.handoffs += 1
    signal()
    if holdHandoff { await withCheckedContinuation { handoffGate = $0 } }
  }
  func didAcquire(_ request: Request, sample: ProducerSample) {
    inFlight += 1
    precondition(inFlight == 1)
    summary.peakInFlight = max(summary.peakInFlight, inFlight)
    summary.acquired += 1
    if measuring {
      summary.handoffMS.append(Double(tick() - sample.finished) / 1e6)
      summary.acquireMS.append(Double(tick() - request.captured) / 1e6)
    }
    signal()
  }
  func awaitCompletion() async {
    let began = tick()
    defer { if measuring { summary.consumerWaitMS.append(Double(tick() - began) / 1e6) } }
    if aborted { return }
    if manual {
      if permits > 0 {
        permits -= 1
        return
      }
      precondition(gate == nil)
      await withCheckedContinuation { gate = $0 }
    } else if delayNS > 0 {
      // Performance workload only. Correctness tests use explicit permits, never sleeps.
      try? await Task.sleep(for: .nanoseconds(Int64(delayNS)))
    }
  }
  func complete(_ request: Request, taskCancelled: Bool) {
    inFlight -= 1
    precondition(inFlight == 0)
    if request.generation != generation {
      summary.stale += 1
    } else if taskCancelled || request.fault == .cancelAfter {
      summary.cancelled += 1
    } else if request.fault == .failAfter {
      summary.failed += 1
    } else if measuring {
      summary.completed += 1
      summary.completionMS.append(Double(tick() - request.captured) / 1e6)
      summary.lastPresentedGeneration = request.generation
      summary.lastPresentedSequence = request.sequence
    }
    signal()
  }
  func returned(_ elapsed: UInt64) {
    summary.returned += 1
    if measuring { summary.returnMS.append(Double(elapsed) / 1e6) }
    signal()
  }
  func invalidate() {
    generation += 1
    capture = nil
    pending = nil
  }
  func releaseOne() {
    if let gate {
      self.gate = nil
      gate.resume()
    } else {
      permits += 1
    }
  }
  func openAll() {
    manual = false
    holdHandoff = false
    if let gate {
      self.gate = nil
      gate.resume()
    }
    if let handoffGate {
      self.handoffGate = nil
      handoffGate.resume()
    }
  }
  func closeInput() {
    inputClosed = true
    if capture == nil {
      captureWaiter?.resume(returning: nil)
      captureWaiter = nil
    }
  }
  func closeProduction() {
    productionClosed = true
    if pending == nil {
      dataWaiter?.resume(returning: nil)
      dataWaiter = nil
    }
  }
  func closeConsumer() {
    consumerClosed = true
    pending = nil
  }
  func abortForError() {
    aborted = true
    capture = nil
    pending = nil
    inputClosed = true
    productionClosed = true
    consumerClosed = true
    openAll()
    captureWaiter?.resume(returning: nil)
    captureWaiter = nil
    dataWaiter?.resume(returning: nil)
    dataWaiter = nil
    let waiting = waits
    waits = []
    for w in waiting { w.continuation.resume() }
  }
  func abortRemainder() {
    capture = nil
    closeInput()
  }
  func beginObservation(manual: Bool = false, delayNS: UInt64 = 0) async {
    precondition(inFlight == 0 && activeProducers == 0)
    self.manual = manual
    self.delayNS = delayNS
    summary = Summary()
    measuring = true
    await cp1.reset()
    start = tick()
  }
  func endObservation() async -> Summary {
    measuring = false
    summary.cp1Published = await cp1.value()
    summary.observationResources = ledger.snapshot()
    summary.observationDurationSeconds = Double(tick() - start) / 1e9
    if inFlight == 1 && manual { summary.stalls += 1 }
    return summary
  }
  func snapshot() async -> Summary {
    var result = summary
    result.cp1Published = await cp1.value()
    return result
  }
  func wait(_ event: Event, count: Int) async {
    if aborted || value(event) >= count { return }
    await withCheckedContinuation {
      waits.append(Wait(event: event, count: count, continuation: $0))
    }
  }
  private func value(_ event: Event) -> Int {
    switch event {
    case .produced: summary.produced
    case .acquired: summary.acquired
    case .completed: summary.completed
    case .producedSequence: summary.lastProducedSequence
    case .returned: summary.returned
    case .faulted: summary.failed + summary.cancelled
    case .publishedSequence: summary.lastPublishedSequence
    case .handoff: summary.handoffs
    }
  }
  private func signal() {
    var remaining: [Wait] = []
    for w in waits {
      if value(w.event) >= w.count { w.continuation.resume() } else { remaining.append(w) }
    }
    waits = remaining
  }
}

@concurrent nonisolated func offer(
  _ state: Scenario, sequence: Int, generation: Int = 1, fault: Fault = .none
) async {
  // Independent simulated CP1 publication has no wait on CP2 production/copy/consumer completion.
  await state.cp1.publish()
  await state.offer(
    Request(generation: generation, sequence: sequence, captured: tick(), fault: fault))
}

nonisolated final class WholeWorkspace {
  private var pool: PoolOwner?
  private var images: PixelPair?
  private(set) var request: Request?
  private(set) var sample: ProducerSample?
  private(set) var checksum: UInt64 = 0
  private(set) var returnStarted: UInt64 = 0
  func beginReturn() { returnStarted = tick() }
  let ledger: Ledger
  init(shape: Shape, ledger: Ledger) throws {
    pool = try PoolOwner(shape: shape, ledger: ledger)
    self.ledger = ledger
  }
  func produce(_ request: Request) throws {
    let start = cpuTick()
    images = nil
    guard let pool else { throw ExperimentError.check("closed pool") }
    let pair = try pool.pair(request)
    try pair.paint()
    images = pair
    self.request = request
    sample = ProducerSample(cpu: cpuTick() - start, copyCPU: 0, finished: tick())
  }
  func verify() throws {
    guard let images else { throw ExperimentError.check("no images") }
    checksum = try images.verify()
  }
  func clear() {
    images = nil
    request = nil
    sample = nil
  }
  func exhaustion() throws {
    guard let pool else { throw ExperimentError.check("closed") }
    try pool.exhaustion()
  }
  func close() {
    clear()
    pool = nil
  }
  var stride: Int { images?.stride ?? 0 }
}
@concurrent nonisolated func prepareWhole(_ owner: sending WholeWorkspace, request: Request)
  async throws -> sending WholeWorkspace
{
  try owner.produce(request)
  return owner
}
@concurrent nonisolated func verifyWhole(_ owner: sending WholeWorkspace) async throws
  -> sending WholeWorkspace
{
  try owner.verify()
  return owner
}
@MainActor func consumeWhole(_ owner: sending WholeWorkspace, state: Scenario) async throws
  -> sending WholeWorkspace
{
  guard let request = owner.request, let sample = owner.sample else {
    throw ExperimentError.check("missing frame")
  }
  await state.beforeAcquire()
  state.didAcquire(request, sample: sample)
  let verified = try await verifyWhole(owner)
  let before = verified.checksum
  await state.awaitCompletion()
  let reverified = try await verifyWhole(verified)
  try require(reverified.checksum == before, "source mutated while consumer owned it")
  state.complete(request, taskCancelled: Task.isCancelled)
  reverified.beginReturn()
  return reverified
}
// Finite test/benchmark runs, not a production infinite recursive pump.
@concurrent nonisolated func wholePump(_ owner: sending WholeWorkspace, state: Scenario)
  async throws
{
  if Task.isCancelled {
    await state.abortRemainder()
    owner.close()
    return
  }
  guard let request = await state.nextCapture() else {
    owner.close()
    return
  }
  if request.fault == .cancelBefore || request.fault == .failBefore {
    await state.skipped(request.fault)
    return try await wholePump(owner, state: state)
  }
  await state.beginProduction()
  let produced = try await prepareWhole(owner, request: request)
  await state.produced(produced.sample!, request: request)
  let returned = try await consumeWhole(produced, state: state)
  let elapsed = tick() - returned.returnStarted
  await state.returned(elapsed)
  return try await wholePump(returned, state: state)
}
actor CopyProducer {
  private var pool: PoolOwner?
  init(shape: Shape, ledger: Ledger) throws { pool = try PoolOwner(shape: shape, ledger: ledger) }
  func make(_ request: Request) throws -> (CopiedPair, ProducerSample) {
    let start = cpuTick()
    guard let pool else { throw ExperimentError.check("closed pool") }
    let pair = try pool.pair(request)
    try pair.paint()
    let copyStart = cpuTick()
    let copied = try pair.copy()
    let copyEnd = cpuTick()
    return (
      copied, ProducerSample(cpu: cpuTick() - start, copyCPU: copyEnd - copyStart, finished: tick())
    )
  }
  func exhaustion() throws {
    guard let pool else { throw ExperimentError.check("closed") }
    try pool.exhaustion()
  }
  func close() { pool = nil }
}
@concurrent nonisolated func copyPump(_ producer: CopyProducer, state: Scenario) async throws {
  while let request = await state.nextCapture() {
    if request.fault == .cancelBefore || request.fault == .failBefore {
      await state.skipped(request.fault)
      continue
    }
    await state.beginProduction()
    let result: (CopiedPair, ProducerSample)
    do { result = try await producer.make(request) } catch {
      await state.abortForError()
      throw error
    }
    let (packet, sample) = result
    await state.produced(sample, request: request)
    await state.publish(packet, sample: sample)
  }
  await state.closeProduction()
}
@concurrent nonisolated func verifyCopied(_ packet: CopiedPair) async throws -> UInt64 {
  try packet.verify()
}
@MainActor func copyConsumer(_ state: Scenario) async throws {
  while let (packet, sample) = await state.nextData() {
    await state.beforeAcquire()
    state.didAcquire(packet.request, sample: sample)
    let before = try await verifyCopied(packet)
    await state.awaitCompletion()
    let after = try await verifyCopied(packet)
    try require(before == after, "deep-copied bytes changed during producer reuse")
    state.complete(packet.request, taskCancelled: Task.isCancelled)
    if Task.isCancelled {
      state.closeConsumer()
      return
    }
  }
  state.closeConsumer()
}
