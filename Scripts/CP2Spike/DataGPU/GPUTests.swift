import Foundation
import Metal

@main struct GPUTests {
  static func main() async {
    do {
      var tests: [String] = []
      var measurements: [UploadResult] = []
      let producer = SyntheticProducer()
      let padded = SyntheticProducer(padded: true)
      let store = try UploadStore()
      let first = try await producer.produce(frame: 1)
      for (id, image) in first.players { try verifyImage(image, player: id, frame: 1) }
      for id in PlayerID.allCases {
        let image = first.players[id]!
        let bytes = image.bytes
        let yellow = 70 * image.bytesPerRow + 100 * 4
        try check(
          Array(bytes[yellow..<(yellow + 4)]) == [0, 255, 255, 255],
          "independent BGRA yellow anchor")
        let edge = 200 * image.bytesPerRow + 80 * 4
        try check(
          bytes[edge + 3] == 128 && bytes[edge + (id == .player1 ? 2 : 0)] == 128,
          "independent premultiplied edge anchor")
        try check(Array(bytes[0..<4]) == [0, 0, 0, 0], "independent transparent padding anchor")
      }
      _ = try await producer.produce(frame: 99)
      for (id, image) in first.players { try verifyImage(image, player: id, frame: 1) }
      tests.append(
        "CPU BGRA/premultiplied/corner/sequence bytes remain immutable after source reuse")
      let unavailable = try EstimatedScalar(value: nil, validity: .notCalibrated)
      let invalidGeometry = BodyGeometry(
        crownY: unavailable, leftWristY: unavailable, rightWristY: unavailable,
        leftSoleY: unavailable, rightSoleY: unavailable, centerX: unavailable)
      for calibrated in [false, true] {
        store.setContext(spikeContext(revisions: calibrated ? [.player1: 1, .player2: 1] : [:]))
        let samples = Dictionary(
          uniqueKeysWithValues: PlayerID.allCases.map { id in
            (
              id,
              PlayerBodySample(
                playerID: id, calibrationRevision: calibrated ? 1 : nil,
                trackingStatus: .uncertain, geometry: invalidGeometry,
                jumpState: JumpState(phase: .unknown, validity: .notCalibrated))
            )
          })
        let noIdentity = BodySnapshot(
          sessionGeneration: spikeGeneration, frameID: 0, capturedAt: 0,
          cameraGeometryRevision: 1, players: samples)
        try check(
          !(try store.offer(
            SyntheticCutoutFrame(
              bodySnapshot: noIdentity, players: first.players, copyMilliseconds: 0))),
          "ready image cannot bypass absent calibration or uncertain identity")
      }
      store.setContext(spikeContext())
      tests.append("absent accepted calibration and uncertain tracking cannot publish ready images")
      try store.offer(first)
      let t1 = try store.encodeAndSubmit()!
      let r1 = try await store.result(t1)
      try check(r1.gpuSucceeded && r1.activated.count == 2, "first actual GPU pair")
      try store.verifyReadback(first)
      tests.append("actual Metal sRGB buffer-to-LowLevelTexture blit and exact two-player readback")
      let paddedFrame = try await padded.produce(frame: 2)
      try check(
        paddedFrame.players.values.allSatisfy { $0.bytesPerRow == 4096 }, "actual padded stride")
      for (id, image) in paddedFrame.players { try verifyImage(image, player: id, frame: 2) }
      try store.offer(paddedFrame)
      let paddedToken = try store.encodeAndSubmit()!
      try check(try await store.result(paddedToken).gpuSucceeded, "padded GPU")
      try store.verifyReadback(paddedFrame)
      tests.append("padded source rows 4096 bytes copied correctly, no row bleed")
      guard let gate = store.device.makeSharedEvent() else {
        throw SpikeError.invalid("shared event")
      }
      let held = try await producer.produce(frame: 3)
      try store.offer(held)
      let heldToken = try store.encodeAndSubmit(gate: gate)!
      try check(
        store.busy && store.commits == 3 && store.completions == 2, "submitted upload is pinned")
      for frame in 4...20 { try store.offer(try await producer.produce(frame: UInt64(frame))) }
      try check(store.pending?.bodySnapshot.frameID == 20 && store.busy, "latest frame bound")
      try check(try store.encodeAndSubmit() == nil, "no staging reuse while GPU gated")
      store.cancel(heldToken)
      try check(store.busy, "cancel cannot reclaim submitted memory")
      gate.signaledValue = 1
      let heldResult = try await store.result(heldToken)
      try check(
        heldResult.gpuSucceeded && heldResult.cancelled && heldResult.activated.isEmpty,
        "cancel suppresses activation")
      try store.verifyReadback(held)
      tests.append(
        "actual GPU fence: cancel pins staging, one pending pair, 17 producer frames progress")
      let newest = store.pending!
      let nextToken = try store.encodeAndSubmit()!
      store.replayCompletionForTest(heldToken)
      try check(store.busy && store.ignoredCallbacks == 1, "old callback cannot settle next job")
      try check(try await store.result(nextToken).activated.count == 2, "resume newest")
      try store.verifyReadback(newest)
      try check(
        !(try store.offer(held)) && !(try store.offer(newest)),
        "late/duplicate rejected after acquire")
      tests.append("replacement watermark survives acquire; duplicate and old callbacks harmless")
      let next = try await producer.produce(frame: 21)
      try store.offer(next)
      let gate2 = store.device.makeSharedEvent()!
      let stale = try store.encodeAndSubmit(gate: gate2)!
      store.setContext(spikeContext(revisions: [.player2: 1]))
      try check(
        !(try store.offer(first)), "calibration change cannot regress unchanged P2 watermark")
      try check(
        store.displayed[.player1] == nil && store.busy, "calibration removed, GPU still pinned")
      gate2.signaledValue = 1
      let partial = try await store.result(stale)
      try check(
        partial.activated == ["player2"], "unchanged slot survives full calibration replacement")
      tests.append("atomic context replacement invalidates P1 and preserves compatible P2")
      store.setContext(spikeContext())
      let before = try await producer.produce(frame: 22)
      try store.offer(before)
      store.cancelPending()
      try check(try store.encodeAndSubmit() == nil, "cancel before commit")
      tests.append("cancellation before submission commits nothing")
      try store.offer(try await producer.produce(frame: 23))
      let commits = store.commits
      do {
        _ = try store.encodeAndSubmit(failBeforeCommit: true)
        throw SpikeError.invalid("failure injection did not throw")
      } catch SpikeError.invalid(let reason) {
        try check(reason == "injected precommit encoding error", "expected failure")
      }
      try check(
        store.commits == commits && !store.busy && store.quarantined == 1,
        "precommit failure retires hidden back")
      let recovery = try await producer.produce(frame: 24)
      try store.offer(recovery)
      let recoveryToken = try store.encodeAndSubmit()!
      try check(
        try await store.result(recoveryToken).activated.count == 2,
        "queue progresses after uncommitted replace")
      try store.verifyReadback(recovery)
      tests.append(
        "throw after first LowLevelTexture replacement: no commit, quarantine, subsequent queue recovery"
      )
      let one = try await producer.produce(frame: 25)
      let absent = SyntheticCutoutFrame(
        bodySnapshot: one.bodySnapshot, players: [.player2: one.players[.player2]!],
        copyMilliseconds: one.copyMilliseconds)
      try store.offer(absent)
      let oneToken = try store.encodeAndSubmit()!
      try check(try await store.result(oneToken).activated == ["player2"], "partial source absence")
      tests.append("P1 unavailable, P2 upload succeeds with original combined provenance")
      let oldGeneration = try await producer.produce(frame: 26)
      try store.offer(oldGeneration)
      let gate3 = store.device.makeSharedEvent()!
      let old = try store.encodeAndSubmit(gate: gate3)!
      let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
      store.setContext(spikeContext(generation: generation))
      try check(store.displayed.isEmpty && store.busy, "generation clears visibility, pins remain")
      gate3.signaledValue = 1
      try check(try await store.result(old).activated.isEmpty, "old generation not current")
      try check(!(try store.offer(oldGeneration)), "stale offered generation")
      let fresh = try await producer.produce(frame: 1, generation: generation)
      try store.offer(fresh)
      let freshToken = try store.encodeAndSubmit()!
      try check(
        try await store.result(freshToken).activated.count == 2,
        "new generation restarts IDs safely")
      tests.append("generation invalidation before actual GPU completion, then safe new generation")
      let failedFrame = try await producer.produce(frame: 2, generation: generation)
      try store.offer(failedFrame)
      let failureToken = try store.encodeAndSubmit(completionFailureForTest: true)!
      let failure = try await store.result(failureToken)
      try check(
        !failure.gpuSucceeded && failure.activated.isEmpty && !store.busy,
        "terminal failure releases staging without activation")
      try check(
        store.displayed.values.allSatisfy { $0.frameID == 1 },
        "failed acknowledgement preserves prior fronts")
      tests.append(
        "injected failed acknowledgement after real GPU fence: both slots suppressed, storage released (not a real GPU fault)"
      )
      for id in PlayerID.allCases {
        let image = first.players[id]!
        let p = image.placement.playerPlaneRect
        let c = image.placement.textureContentRectPx
        let q = try image.placement.fullQuad(
          width: 512, height: 768, lane: spikeLayout.centerX(for: id))
        let sx = q.width / 512
        let sy = q.height / 768
        let L = spikeLayout.centerX(for: id)
        // Raster content x reflects; y stays upright, with independent source heights.
        try check(
          abs((q.x + (512 - c.x - c.width) * sx) - (2 * L - p.x - p.width)) < 1e-9,
          "mirror padded position")
        try check(
          abs((q.y + (768 - c.y - c.height) * sy) - p.y) < 1e-9, "padding vertical alignment")
        try check(abs(sx - sy) < 1e-9, "uniform shared scale")
      }
      let knownP1 = try first.players[.player1]!.placement.fullQuad(
        width: 512, height: 768, lane: -0.8)
      let knownP2 = try first.players[.player2]!.placement.fullQuad(
        width: 512, height: 768, lane: 0.8)
      try check(
        abs(knownP1.x + 1.352) < 1e-9 && abs(knownP1.y + 0.071) < 1e-9
          && abs(knownP1.width - 1.024) < 1e-9, "independent P1 numeric mapping")
      try check(
        abs(knownP2.x - 0.248) < 1e-9 && abs(knownP2.y + 0.295) < 1e-9
          && abs(knownP2.height - 1.536) < 1e-9, "independent P2 numeric mapping")
      tests.append("asymmetric full-canvas size/translation/UV reflection and shared scale")
      // Warmup 5, then 30 measured pairs; CPU verification/readback excluded from reported upload timing.
      var copies: [Double] = []
      for sequence in 3...37 {
        let f = try await producer.produce(frame: UInt64(sequence), generation: generation)
        try store.offer(f)
        let token = try store.encodeAndSubmit()!
        let result = try await store.result(token)
        try check(result.gpuSucceeded && result.activated.count == 2, "measurement upload")
        if sequence >= 8 {
          measurements.append(result)
          copies.append(f.copyMilliseconds)
        }
        if sequence == 37 { try store.verifyReadback(f) }
      }
      try check(
        store.commits == store.completions && store.peakInFlight == 1,
        "one commit/terminal completion per job")
      tests.append(
        "35 sequential front/back uploads, five warmup + 30 measured; balanced commits/completions")
      weak var weakStore: UploadStore?
      do {
        let temporary = try UploadStore(readback: false)
        weakStore = temporary
        try temporary.offer(try await producer.produce(frame: 100))
        let token = try temporary.encodeAndSubmit()!
        _ = try await temporary.result(token)
      }
      try check(weakStore == nil, "store and staging lifetime cleanup")
      tests.append("terminal completion permits store/staging deallocation")
      weak var abandonedStore: UploadStore?
      let orphanGate = store.device.makeSharedEvent()!
      var retainedPin: StagingPin?
      do {
        let temporary = try UploadStore(readback: false)
        abandonedStore = temporary
        try temporary.offer(try await producer.produce(frame: 101))
        _ = try temporary.encodeAndSubmit(gate: orphanGate)
        retainedPin = temporary.lastPin
      }
      try check(
        abandonedStore == nil && retainedPin?.retainedBuffers == 2
          && retainedPin?.released == false,
        "store teardown cannot release gated GPU staging")
      orphanGate.signaledValue = 1
      await retainedPin?.untilReleased()
      try check(
        retainedPin?.retainedBuffers == 0 && retainedPin?.released == true,
        "orphan upload releases pins only at actual GPU completion")
      tests.append(
        "store destroyed mid-upload: independent completion pin retains staging until actual terminal fence"
      )
      let report: [String: Any] = [
        "platform": "native macOS Apple M5 (not iPad or Simulator)", "device": store.device.name,
        "deviceRegistryID": store.device.registryID, "testsPassed": tests.count, "testsFailed": 0,
        "tests": tests, "commits": store.commits, "completions": store.completions,
        "drops": store.dropped, "peakInFlight": store.peakInFlight, "stagingBytes": 2 * 4096 * 768,
        "verificationReadbackBytes": 2 * 4096 * 768, "producerCopyMilliseconds": copies,
        "uploads": try JSONSerialization.jsonObject(with: JSONEncoder().encode(measurements)),
      ]
      let output = CommandLine.arguments.dropFirst().first ?? "/private/tmp/cp2-gpu/results.json"
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
      print(
        "PASS \(tests.count) assertion groups; \(store.commits) actual GPU commits/completions; \(store.device.name)"
      )
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(1)
    }
  }
}
