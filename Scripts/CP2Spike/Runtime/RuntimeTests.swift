import CoreVideo
import Foundation

typealias Driver = @MainActor @Sendable (Scenario) async throws -> Void
@MainActor private func guardedDrive(_ state: Scenario, action: Driver) async throws {
  defer {
    state.openAll()
    state.closeInput()
  }
  try await action(state)
}
@concurrent nonisolated func driven(
  model: String, shape: Shape = .standard, ledger: Ledger,
  action: @escaping Driver
) async throws -> Summary {
  let state = await Scenario(ledger: ledger, manual: true)
  if model == "whole" {
    let owner = try WholeWorkspace(shape: shape, ledger: ledger)
    async let driving: Void = guardedDrive(state, action: action)
    do { try await wholePump(owner, state: state) } catch {
      await state.abortForError()
      _ = try? await driving
      throw error
    }
    try await driving
  } else {
    let producer = try CopyProducer(shape: shape, ledger: ledger)
    async let driving: Void = guardedDrive(state, action: action)
    async let producing: Void = copyPump(producer, state: state)
    do { try await copyConsumer(state) } catch {
      await state.abortForError()
      _ = try? await producing
      _ = try? await driving
      await producer.close()
      throw error
    }
    try await producing
    await producer.close()
    try await driving
  }
  return await state.snapshot()
}
nonisolated func assertReleased(_ ledger: Ledger) throws {
  let c = ledger.snapshot()
  try require(c.pools == 0 && c.sourceBuffers == 0 && c.dataPairs == 0, "resources not released")
  try require(c.locks == c.unlocks, "unbalanced CV locks")
  try require(
    c.peakPools <= 1 && c.peakSourceBuffers <= 6 && c.peakDataPairs <= 3, "resource cap exceeded")
}
nonisolated struct TestRecord: Codable, Sendable { let name: String, passed: Bool, detail: String }

@concurrent nonisolated func runCorrectness() async -> [TestRecord] {
  var records: [TestRecord] = []
  for model in ["whole", "copy"] {
    for padded in [false, true] {
      let name = "\(model): exact two-player bytes, \(padded ? "padded" : "packed") rows and reuse"
      progress("RUN \(name)")
      do {
        let ledger = Ledger()
        let s = try await driven(model: model, shape: padded ? .padded : .standard, ledger: ledger)
        { state in
          for i in 1...5 {
            await offer(state, sequence: i)
            await state.wait(.acquired, count: i)
            state.releaseOne()
            await state.wait(.completed, count: i)
          }
        }
        try require(s.completed == 5 && s.cp1Published == 5, "missing frames")
        let c = ledger.snapshot()
        try require(c.poolsCreated == 1 && c.uniqueBufferIDs < 10, "persistent pool did not reuse")
        if padded {
          try require(c.maxImageBytes > 512 * 768 * 4, "padding was not actually exercised")
        }
        try assertReleased(ledger)
        records.append(
          TestRecord(
            name: name, passed: true,
            detail:
              "5 P1/P2 frames checked byte-for-byte twice; checked row padding and pool identities")
        )
      } catch {
        records.append(TestRecord(name: name, passed: false, detail: String(describing: error)))
      }
    }
    progress("RUN \(model) next gated scenario")
    do {
      let ledger = Ledger()
      let s = try await driven(model: model, ledger: ledger) { state in
        await offer(state, sequence: 1)
        await state.wait(.acquired, count: 1)
        // Completion is deliberately withheld. No timeout/sleep establishes success.
        for i in 2...16 { await offer(state, sequence: i) }
        if model == "copy" { await state.wait(.publishedSequence, count: 16) }
        let blocked = await state.snapshot()
        let resources = ledger.snapshot()
        try require(
          blocked.cp1Published == 16 && blocked.completed == 0,
          "CP1 blocked or consumer escaped gate")
        try require(resources.poolsCreated == 1 && resources.pools == 1, "replacement pool created")
        if model == "whole" {
          try require(
            blocked.produced == 1 && resources.sourceBuffers == 2,
            "producer touched a transferred workspace")
          try require(blocked.supersededCaptures >= 14, "latest capture was not bounded/replaced")
        } else {
          try require(
            blocked.produced >= 2 && resources.dataPairs <= 3 && resources.sourceBuffers <= 2,
            "copy producer failed progress/bounds")
          try require(blocked.supersededData > 0, "pending Data was not replaced")
        }
        state.releaseOne()
        await state.wait(.acquired, count: 2)
        state.releaseOne()
      }
      try require(s.lastPresentedSequence == 16, "did not resume with latest capture")
      try assertReleased(ledger)
      records.append(
        TestRecord(
          name:
            "\(model): delayed/never-in-window, CP1 progress, immutable hold, latest-frame resume",
          passed: true,
          detail:
            "16 offers while first consumer gated; no replacement pools; explicit return only after observation; no permanent-loss recovery claimed"
        ))
    } catch {
      records.append(
        TestRecord(
          name: "\(model): delayed/never-in-window", passed: false,
          detail: String(describing: error)))
    }
    progress("RUN \(model) delayed/backpressure")
    for fault in [Fault.cancelBefore, .failBefore, .failAfter, .cancelAfter] {
      progress("RUN \(model) \(fault.rawValue)")
      do {
        let ledger = Ledger()
        let s = try await driven(model: model, ledger: ledger) { state in
          await offer(state, sequence: 1, fault: fault)
          if fault == .failAfter || fault == .cancelAfter {
            await state.wait(.acquired, count: 1)
            state.releaseOne()
            await state.wait(.produced, count: 1)
          }
          if fault == .failBefore || fault == .cancelBefore { await state.wait(.faulted, count: 1) }
          // A second key cannot bypass the first explicit completion gate.
          await offer(state, sequence: 2)
          let acquiredTarget = (fault == .failAfter || fault == .cancelAfter) ? 2 : 1
          await state.wait(.acquired, count: acquiredTarget)
          state.releaseOne()
        }
        try require(
          s.failed + s.cancelled == 1 && s.lastPresentedSequence == 2,
          "failure/cancel affected later output")
        try assertReleased(ledger)
        records.append(
          TestRecord(
            name: "\(model): \(fault.rawValue)", passed: true,
            detail: "safe cleanup and next frame progress"))
      } catch {
        records.append(
          TestRecord(
            name: "\(model): \(fault.rawValue)", passed: false, detail: String(describing: error)))
      }
    }
    progress("RUN \(model) next gated scenario")
    do {
      let ledger = Ledger()
      let s = try await driven(model: model, ledger: ledger) { state in
        await offer(state, sequence: 1)
        await state.wait(.acquired, count: 1)
        state.invalidate()
        await offer(state, sequence: 2, generation: 1)  // Explicit old-generation capture.
        state.releaseOne()
        await offer(state, sequence: 100, generation: 2)
        await state.wait(.acquired, count: 2)
        state.releaseOne()
      }
      try require(
        s.stale >= 2 && s.lastPresentedGeneration == 2 && s.lastPresentedSequence == 100,
        "old generation became current")
      try require(ledger.snapshot().poolsCreated == 1, "context change allocated another pool")
      try assertReleased(ledger)
      records.append(
        TestRecord(
          name: "\(model): generation invalidation", passed: true,
          detail: "old acquired output rejected at completion; one pool"))
    } catch {
      records.append(
        TestRecord(
          name: "\(model): generation invalidation", passed: false,
          detail: String(describing: error)))
    }
    progress("RUN \(model) next gated scenario")
    do {
      let ledger = Ledger()
      let s = try await driven(model: model, ledger: ledger) { state in
        for session in 1...6 {
          if session > 1 { state.invalidate() }
          await offer(state, sequence: session, generation: session)
          await state.wait(.acquired, count: session)
          state.releaseOne()
          await state.wait(.completed, count: session)
        }
      }
      try require(
        s.completed == 6 && ledger.snapshot().poolsCreated == 1, "session resource growth")
      try assertReleased(ledger)
      records.append(
        TestRecord(
          name: "\(model): six sessions", passed: true,
          detail: "same pool across generations, zero checked-out/copy resources after join"))
    } catch {
      records.append(
        TestRecord(name: "\(model): six sessions", passed: false, detail: String(describing: error))
      )
    }
    do {
      let ledger = Ledger()
      if model == "whole" {
        let owner = try WholeWorkspace(shape: .standard, ledger: ledger)
        try owner.exhaustion()
        owner.close()
      } else {
        let producer = try CopyProducer(shape: .standard, ledger: ledger)
        try await producer.exhaustion()
        await producer.close()
      }
      try require(ledger.snapshot().peakSourceBuffers == 6, "did not reach capacity")
      try assertReleased(ledger)
      records.append(
        TestRecord(
          name: "\(model): pool exhaustion", passed: true,
          detail: "7th buffer rejected; releasing holders restored capacity; balanced locks"))
    } catch {
      records.append(
        TestRecord(
          name: "\(model): pool exhaustion", passed: false, detail: String(describing: error)))
    }
    do {
      try await actualCancellation(model: model)
      records.append(
        TestRecord(
          name: "\(model): actual Task.cancel while consumer owns resources", passed: true,
          detail:
            "cancel did not force-release held resources; explicit completion returned ownership before join"
        ))
    } catch {
      records.append(
        TestRecord(
          name: "\(model): actual cancellation", passed: false, detail: String(describing: error)))
    }
    do {
      try await actualCancellation(model: model, duringTransfer: true)
      records.append(
        TestRecord(
          name: "\(model): actual cancellation during handoff", passed: true,
          detail:
            "explicit pre-acquisition gate; no forced resource release; cancelled output never accepted"
        ))
    } catch {
      records.append(
        TestRecord(
          name: "\(model): handoff cancellation", passed: false, detail: String(describing: error)))
    }
  }
  do {
    let huge = Shape(width: Int.max, height: 768, alignment: 64)
    do {
      _ = try huge.byteCount(stride: Int.max)
      throw ExperimentError.check("overflow accepted")
    } catch ExperimentError.check(let message) {
      try require(message != "overflow accepted", message)
    }
    do {
      _ = try Shape.standard.byteCount(stride: 1)
      throw ExperimentError.check("short stride accepted")
    } catch ExperimentError.check(let message) {
      try require(message != "short stride accepted", message)
    }
    records.append(
      TestRecord(
        name: "checked image arithmetic", passed: true, detail: "overflow/short-stride rejected"))
  } catch {
    records.append(
      TestRecord(name: "checked image arithmetic", passed: false, detail: String(describing: error))
    )
  }
  return records
}

@concurrent private func actualCancellation(model: String, duringTransfer: Bool = false)
  async throws
{
  let ledger = Ledger()
  let state = await Scenario(ledger: ledger, manual: true, holdHandoff: duringTransfer)
  if model == "whole" {
    // One scoped task for cancellation injection; pool is constructed inside its disconnected scope.
    // Always joined; no per-frame or detached tasks.
    let task = Task { @concurrent in
      let owner = try WholeWorkspace(shape: .standard, ledger: ledger)
      do { try await wholePump(owner, state: state) } catch {
        await state.abortForError()
        throw error
      }
    }
    await offer(state, sequence: 1)
    await state.wait(duringTransfer ? .handoff : .acquired, count: 1)
    task.cancel()
    let retained = ledger.snapshot().sourceBuffers == 2
    await state.closeInput()
    await state.openAll()
    try await task.value
    try require(retained, "Task.cancel force-reclaimed owner")
  } else {
    let producer = try CopyProducer(shape: .standard, ledger: ledger)
    async let pumping: Void = copyPump(producer, state: state)
    let task = Task { @MainActor in try await copyConsumer(state) }
    await offer(state, sequence: 1)
    await state.wait(duringTransfer ? .handoff : .acquired, count: 1)
    task.cancel()
    let retained = ledger.snapshot().dataPairs >= 1
    await state.closeInput()
    await state.openAll()
    try await task.value
    try await pumping
    await producer.close()
    try require(retained, "Task.cancel released in-use data")
  }
  let s = await state.snapshot()
  try require(s.cancelled == 1 && s.completed == 0, "cancelled consumer presented frame")
  try assertReleased(ledger)
}
