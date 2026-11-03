import Darwin
import Foundation

nonisolated struct BenchmarkResult: Codable, Sendable {
  let model: String, scenario: String
  let warmupFrames: Int, measurementFrames: Int, inputHz: Int, delayMilliseconds: Int
  let window: Summary, finalResources: ResourceSnapshot
  let processPeakRSSBytes: Int64
  let simulatedStagingBytes: Int
}
@MainActor private func benchmarkDriver(
  _ state: Scenario, model: String, scenario: String,
  warmup: Int, frames: Int, hz: Int
) async throws -> Summary {
  defer {
    state.openAll()
    state.closeInput()
  }
  for i in 1...warmup {
    await offer(state, sequence: i)
    await state.wait(.acquired, count: i)
    await state.wait(.completed, count: i)
    if model == "whole" { await state.wait(.returned, count: i) }
  }
  let delay: UInt64 =
    scenario == "slow"
    ? 50_000_000 : ((scenario == "moderate" || scenario == "faults") ? 8_000_000 : 0)
  await state.beginObservation(manual: scenario == "never", delayNS: delay)
  let epoch = tick()
  let period = UInt64(1_000_000_000 / hz)
  for i in 1...frames {
    let target = epoch + UInt64(i - 1) * period
    let now = tick()
    if target > now { try await Task.sleep(for: .nanoseconds(Int64(target - now))) }
    let fault: Fault =
      scenario == "faults" && i % 10 == 0 ? (i % 20 == 0 ? .cancelAfter : .failAfter) : .none
    // CP1 gets its own publication before the CP2 mailbox offer, never awaiting the producer.
    await state.cp1.publish()
    state.offer(
      Request(generation: 1, sequence: i + warmup, captured: tick(), fault: fault), nominal: target)
  }
  let end = epoch + UInt64(frames) * period
  let atEnd = tick()
  if atEnd < end { try await Task.sleep(for: .nanoseconds(Int64(end - atEnd))) }
  let result = await state.endObservation()
  // For 'never', this is explicitly teardown AFTER observation, not timeout-based reclaim/recovery.
  return result
}
@concurrent nonisolated func benchmark(
  model: String, scenario: String, warmup: Int, frames: Int, hz: Int
) async throws -> BenchmarkResult {
  let ledger = Ledger()
  let measured = await Scenario(ledger: ledger)
  let result: Summary
  if model == "whole" {
    let owner = try WholeWorkspace(shape: .standard, ledger: ledger)
    async let driving = benchmarkDriver(
      measured, model: model, scenario: scenario, warmup: warmup, frames: frames, hz: hz)
    try await wholePump(owner, state: measured)
    result = try await driving
  } else {
    let producer = try CopyProducer(shape: .standard, ledger: ledger)
    async let driving = benchmarkDriver(
      measured, model: model, scenario: scenario, warmup: warmup, frames: frames, hz: hz)
    async let producing: Void = copyPump(producer, state: measured)
    try await copyConsumer(measured)
    try await producing
    await producer.close()
    result = try await driving
  }
  try assertReleased(ledger)
  try require(result.cp1Published == frames, "CP1 lost scheduled publications")
  var usage = rusage()
  guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ExperimentError.check("getrusage") }
  return BenchmarkResult(
    model: model, scenario: scenario, warmupFrames: warmup, measurementFrames: frames,
    inputHz: hz,
    delayMilliseconds: scenario == "slow"
      ? 50 : ((scenario == "moderate" || scenario == "faults") ? 8 : 0),
    window: result, finalResources: ledger.snapshot(), processPeakRSSBytes: Int64(usage.ru_maxrss),
    simulatedStagingBytes: 0)
}

@main struct RuntimeComparison {
  static func main() async {
    do {
      let a = Array(CommandLine.arguments.dropFirst())
      func arg(_ key: String, fallback: String) -> String {
        guard let i = a.firstIndex(of: key), a.indices.contains(i + 1) else { return fallback }
        return a[i + 1]
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data: Data
      var failed = false
      if a.contains("--correctness") {
        let tests = await runCorrectness()
        data = try encoder.encode(tests)
        failed = tests.contains { !$0.passed }
      } else {
        let model = arg("--model", fallback: "whole")
        let scenario = arg("--scenario", fallback: "none")
        let warmup = Int(arg("--warmup", fallback: "12")) ?? 12
        let frames = Int(arg("--frames", fallback: "90")) ?? 90
        let hz = Int(arg("--hz", fallback: "60")) ?? 60
        try require(
          ["whole", "copy"].contains(model)
            && ["none", "moderate", "slow", "faults", "never"].contains(scenario)
            && warmup > 0 && warmup <= 30 && frames > 0 && frames <= 240 && hz > 0 && hz <= 120,
          "CLI bounds")
        data = try encoder.encode(
          await benchmark(model: model, scenario: scenario, warmup: warmup, frames: frames, hz: hz))
      }
      let path = arg("--output", fallback: "")
      if path.isEmpty {
        print(String(decoding: data, as: UTF8.self))
      } else {
        try data.write(to: URL(fileURLWithPath: path))
      }
      if failed { exit(1) }
    } catch {
      print("RUNTIME COMPARISON FAILED: \(error)")
      exit(1)
    }
  }
}

#if CP2_RUNTIME_NEGATIVE
  @concurrent nonisolated func forbiddenRuntimeAlias() async throws {
    let ledger = Ledger()
    let owner = try WholeWorkspace(shape: .standard, ledger: ledger)
    let alias = owner
    let request = Request(generation: 1, sequence: 1, captured: tick(), fault: .none)
    _ = try await prepareWhole(owner, request: request)
    try alias.produce(request)  // Must be diagnosed; no runtime execution of this control.
  }
#endif
