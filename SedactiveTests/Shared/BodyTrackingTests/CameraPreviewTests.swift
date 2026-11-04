#if DEBUG
  import CoreGraphics
  import CoreVideo
  import Foundation
  import Synchronization
  import Testing
  @testable import Sedactive

  nonisolated private final class PreviewClock: Sendable {
    let value = Mutex(100.0)
    func now() -> Double { value.withLock { $0 } }
    func advance(_ delta: Double = 0.25) { value.withLock { $0 += delta } }
  }
  private actor DelayedPreviewConverter: CameraPreviewConverting {
    private var gate: CheckedContinuation<Void, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func convert(_ input: CameraPreviewInput) async -> CameraPreviewFrame? {
      calls += 1
      await withCheckedContinuation {
        gate = $0
        entry?.resume()
        entry = nil
      }
      guard let image = input.backing.image(descriptor: input.metadata.descriptor) else {
        return nil
      }
      return CameraPreviewFrame(
        subscription: input.subscription, metadata: input.metadata, image: image)
    }
    func entered() async {
      if gate != nil { return }
      await withCheckedContinuation { entry = $0 }
    }
    func release() {
      gate?.resume()
      gate = nil
    }
  }
  nonisolated private enum PreviewFixtures {
    static func metadata(_ context: CameraSourceContext, id: UInt64 = 1, at time: Double = 100)
      throws -> CameraFrameMetadata
    {
      CameraFrameMetadata(
        context: context, frameID: id, capturedAt: time,
        descriptor: try CameraFrameDescriptor(
          width: 8, height: 8, bytesPerRow: 64,
          pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 1024), rotationAngle: 0,
        mirrored: false)
    }
    static func packet(_ preview: CameraDiagnosticPreview, at now: Double) throws
      -> CameraPreviewFrame
    {
      try #require(preview.takeLatest(at: now))
    }
    static func bytes() -> Data {
      var data = Data(repeating: 0, count: 512)
      for row in 0..<8 {
        for x in 0..<8 {
          let i = row * 64 + x * 4
          data[i] = 17
          data[i + 1] = 33
          data[i + 2] = 201
          data[i + 3] = 0
        }
      }
      return data
    }
  }
  nonisolated struct CameraPreviewTests {
    @Test func providerOnlyRetentionKeepsCreditUntilFinalRelease() throws {
      let budget = CameraPreviewBudget(limit: 512)
      var provider: CGDataProvider?
      do {
        let reservation = try #require(budget.reserve(512))
        let backing = CameraPreviewBacking(bytes: PreviewFixtures.bytes(), reservation: reservation)
        let d = try PreviewFixtures.metadata(CameraTestFrames.context()).descriptor
        let created = try #require(backing.image(descriptor: d))
        var image: CGImage? = created
        provider = image?.dataProvider
        image = nil
      }
      #expect(budget.usage.bytes == 512)
      #expect(budget.reserve(512) == nil)
      let copy = try #require(provider?.data)
      #expect(CFDataGetLength(copy) == 512)
      #expect(CFDataGetBytePtr(copy)![2] == 201)
      provider = nil
      #expect(budget.usage.bytes == 0)
      #expect(budget.usage.backings == 0)
    }
    @Test func paddedBGRAIsOpaqueAndDrawsCorrectChannels() throws {
      let budget = CameraPreviewBudget(limit: 512)
      let r = try #require(budget.reserve(512))
      let owner = CameraPreviewBacking(bytes: PreviewFixtures.bytes(), reservation: r)
      let image = try #require(
        owner.image(descriptor: PreviewFixtures.metadata(CameraTestFrames.context()).descriptor))
      #expect(image.bytesPerRow == 64)
      #expect(image.alphaInfo == .noneSkipFirst)
      var target = Data(count: 8 * 8 * 4)
      try target.withUnsafeMutableBytes { bytes in
        let ctx = try #require(
          CGContext(
            data: bytes.baseAddress, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
              | CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
      }
      #expect(target[0] == 17 && target[1] == 33 && target[2] == 201 && target[3] == 255)
    }
    @Test func disabledOversizedAndCadenceOffersDoNotCopy() throws {
      let clock = PreviewClock()
      let context = CameraTestFrames.context()
      var config = CameraPreviewConfiguration()
      config.maximumPayloadBytes = 256
      let preview = CameraDiagnosticPreview(configuration: config, clock: clock.now)
      preview.updateContext(context)
      var copies = 0
      let meta = try PreviewFixtures.metadata(context)
      preview.offer(metadata: meta) {
        copies += 1
        return PreviewFixtures.bytes()
      }
      preview.setEnabled(true)
      preview.offer(metadata: meta) {
        copies += 1
        return PreviewFixtures.bytes()
      }
      #expect(copies == 0)
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test func delayedConversionRejectsContextAndNeverBlocksPrimaryOrSpawnsReplacement()
      async throws
    {
      let converter = DelayedPreviewConverter()
      let clock = PreviewClock()
      let preview = CameraDiagnosticPreview(clock: clock.now, converter: converter)
      let context = CameraTestFrames.context()
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      preview.offer(metadata: try PreviewFixtures.metadata(context)) { PreviewFixtures.bytes() }
      await converter.entered()
      clock.advance()
      preview.offer(metadata: try PreviewFixtures.metadata(context, id: 2, at: clock.now())) {
        Issue.record("Busy preview unexpectedly copied")
        return PreviewFixtures.bytes()
      }
      #expect(preview.statistics.busyDrops == 1)
      preview.invalidate(context)
      preview.updateContext(CameraTestFrames.context(2))
      #expect(preview.budget.usage.bytes == 512)
      worker.cancel()
      await converter.release()
      _ = await completions.next()
      await worker.value
      #expect(preview.takeLatest(at: clock.now()) == nil)
      #expect(preview.budget.usage.bytes == 0)
      #expect(await converter.calls == 1)
      // Lifetime claim prevents cancellation from introducing another worker.
      await preview.run()
    }
    @Test func latestOnlyCadenceDuplicatesExpiryAndDisable() async throws {
      let clock = PreviewClock()
      let context = CameraTestFrames.context()
      let preview = CameraDiagnosticPreview(clock: clock.now)
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      let first = try PreviewFixtures.metadata(context)
      preview.offer(metadata: first) { PreviewFixtures.bytes() }
      _ = await completions.next()
      preview.offer(metadata: first) {
        Issue.record("Duplicate copied")
        return PreviewFixtures.bytes()
      }
      preview.offer(metadata: try PreviewFixtures.metadata(context, id: 2)) {
        Issue.record("Cadence violation copied")
        return PreviewFixtures.bytes()
      }
      clock.advance()
      let second = try PreviewFixtures.metadata(context, id: 3, at: clock.now())
      preview.offer(metadata: second) { PreviewFixtures.bytes() }
      _ = await completions.next()
      var displayed: CameraPreviewFrame? = try PreviewFixtures.packet(preview, at: clock.now())
      #expect(displayed?.metadata == second)
      #expect(preview.statistics.cadenceDrops == 1 && preview.statistics.staleDrops == 1)
      clock.advance(2)
      #expect(!preview.isCurrent(displayed!, at: clock.now()))
      preview.setEnabled(false)
      #expect(!preview.isCurrent(displayed!, at: clock.now()))
      #expect(preview.budget.usage.bytes == 512)
      displayed = nil
      worker.cancel()
      await worker.value
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test func budgetIncludesProviderRetainedImagesBeyondPackets() async throws {
      let clock = PreviewClock()
      let context = CameraTestFrames.context()
      var config = CameraPreviewConfiguration()
      config.maximumBytes = 1024
      let preview = CameraDiagnosticPreview(configuration: config, clock: clock.now)
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      var providers: [CGDataProvider] = []
      for id in UInt64(1)...2 {
        preview.offer(metadata: try PreviewFixtures.metadata(context, id: id, at: clock.now())) {
          PreviewFixtures.bytes()
        }
        _ = await completions.next()
        do {
          let packet = try #require(preview.takeLatest(at: clock.now()))
          providers.append(packet.image.dataProvider!)
        }
        clock.advance()
      }
      preview.offer(metadata: try PreviewFixtures.metadata(context, id: 3, at: clock.now())) {
        Issue.record("Budget exhausted but copied pixels")
        return PreviewFixtures.bytes()
      }
      #expect(preview.statistics.budgetDrops == 1)
      #expect(preview.budget.usage.bytes == 1024)
      preview.setEnabled(false)
      #expect(preview.budget.usage.bytes == 1024)
      providers.removeAll()
      worker.cancel()
      await worker.value
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test func primaryAdmissionContinuesWhilePreviewNeverStartsAndSourceReuseIsIndependent() throws
    {
      let store = FrameStore()
      let context = CameraTestFrames.context()
      _ = store.begin(context)
      store.preview.setEnabled(true)
      let source = try CameraTestFrames.buffer()
      for _ in 0..<20 {
        try CameraTestFrames.fill(source, 12)
        let metadata = CameraFrameMetadata(
          context: context, frameID: try store.nextIdentity(context),
          capturedAt: CameraHostClock.now(),
          descriptor: try CameraFrameDescriptor(
            width: 8, height: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(source),
            pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 1024),
          rotationAngle: 0, mirrored: false)
        try store.copy(source, metadata: metadata)
      }
      #expect(store.diagnostics.superseded == 19)
      #expect(store.preview.statistics.admitted == 1)
      #expect(store.preview.statistics.busyDrops == 19)
      #expect(store.usage.frames == 1)  // Preview did not retain any of the retired raw sources.
      store.end(context)
      #expect(store.usage.bytes == 0 && store.preview.budget.usage.bytes == 0)
    }
    @Test func independentCloneSurvivesMutableProducerReuseAndRepeatedSubscription() async throws {
      let clock = PreviewClock()
      let context = CameraTestFrames.context()
      let preview = CameraDiagnosticPreview(clock: clock.now)
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      var source = PreviewFixtures.bytes()
      for id in UInt64(1)...3 {
        preview.offer(metadata: try PreviewFixtures.metadata(context, id: id, at: clock.now())) {
          source.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        }
        source[0] = 99
        _ = await completions.next()
        do {
          let packet = try #require(preview.takeLatest(at: clock.now()))
          let data = try #require(packet.image.dataProvider?.data)
          #expect(CFDataGetBytePtr(data)![0] == (id == 1 ? 17 : 99))
          preview.setEnabled(false)
          #expect(!preview.isCurrent(packet, at: clock.now()))
        }
        preview.setEnabled(true)
        clock.advance()
      }
      worker.cancel()
      await worker.value
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test(arguments: [0, 1, 2])
    func eachContextComponentRejectsLateCompletionWithoutCancellingWorker(_ component: Int)
      async throws
    {
      let clock = PreviewClock()
      let converter = DelayedPreviewConverter()
      let preview = CameraDiagnosticPreview(clock: clock.now, converter: converter)
      let old = CameraTestFrames.context()
      let next = CameraSourceContext(
        generation: component == 0 ? UUID() : old.generation,
        epoch: component == 1 ? UUID() : old.epoch,
        geometryRevision: component == 2 ? old.geometryRevision + 1 : old.geometryRevision)
      preview.updateContext(old)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      preview.offer(metadata: try PreviewFixtures.metadata(old)) { PreviewFixtures.bytes() }
      await converter.entered()
      preview.invalidate(old)
      preview.updateContext(next)
      await converter.release()
      _ = await completions.next()
      #expect(preview.takeLatest(at: clock.now()) == nil)
      #expect(preview.statistics.contextDrops == 1)
      worker.cancel()
      await worker.value
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test func disableAndReattachRejectsOldTokenAndReusesOneWorker() async throws {
      let clock = PreviewClock()
      let converter = DelayedPreviewConverter()
      let preview = CameraDiagnosticPreview(clock: clock.now, converter: converter)
      let context = CameraTestFrames.context()
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      preview.offer(metadata: try PreviewFixtures.metadata(context)) { PreviewFixtures.bytes() }
      await converter.entered()
      preview.setEnabled(false)
      preview.setEnabled(true)
      await converter.release()
      _ = await completions.next()
      #expect(preview.takeLatest(at: clock.now()) == nil)
      clock.advance()
      preview.offer(metadata: try PreviewFixtures.metadata(context, id: 2, at: clock.now())) {
        PreviewFixtures.bytes()
      }
      await converter.entered()
      await converter.release()
      _ = await completions.next()
      do {
        let packet = try PreviewFixtures.packet(preview, at: clock.now())
        #expect(packet.metadata.frameID == 2)
      }
      #expect(await converter.calls == 2)
      preview.setEnabled(false)
      worker.cancel()
      await worker.value
      #expect(preview.budget.usage.bytes == 0)
    }
    @Test func completedJobReleasesPixelsWhileWorkerRemainsWaiting() async throws {
      let clock = PreviewClock()
      let context = CameraTestFrames.context()
      let preview = CameraDiagnosticPreview(clock: clock.now)
      preview.updateContext(context)
      preview.setEnabled(true)
      let worker = Task { await preview.run() }
      var completions = preview.jobCompletions.makeAsyncIterator()
      preview.offer(metadata: try PreviewFixtures.metadata(context)) { PreviewFixtures.bytes() }
      _ = await completions.next()
      do {
        let packet = try PreviewFixtures.packet(preview, at: clock.now())
        #expect(packet.metadata.frameID == 1)
      }
      preview.invalidate(context)
      #expect(preview.budget.usage.bytes == 0)  // No cancellation/new frame required to release a completed job.
      worker.cancel()
      await worker.value
    }
    @Test func aspectFitAndExactlyOneMirror() {
      let rect = CameraPreviewLayout.rect(
        image: CGSize(width: 1280, height: 720), in: CGSize(width: 1000, height: 1000))
      #expect(rect == CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
      #expect(
        CameraPreviewLayout.mirroredPoint(CGPoint(x: 0, y: 1), in: rect)
          == CGPoint(x: 1000, y: 218.75))
      #expect(
        CameraPreviewLayout.mirroredPoint(CGPoint(x: 1, y: 0), in: rect) == CGPoint(x: 0, y: 781.25)
      )
      #expect(CameraPreviewLayout.rect(image: .zero, in: CGSize(width: 10, height: 10)) == .zero)
    }
  }
#endif
