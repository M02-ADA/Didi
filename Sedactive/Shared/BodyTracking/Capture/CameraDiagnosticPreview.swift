#if DEBUG
  import CoreGraphics
  import Foundation
  import Darwin
  import Synchronization

  nonisolated struct CameraPreviewConfiguration: Sendable {
    var maximumFPS = 5.0
    var maximumPayloadBytes = 4 * 1024 * 1024
    var maximumBytes = 12 * 1024 * 1024
    // DEBUG freshness experiment only; never a camera-stall/gameplay timeout.
    var maximumAge = 1.0
  }
  nonisolated struct CameraPreviewUsage: Sendable {
    let bytes: Int, peakBytes: Int, backings: Int
  }
  nonisolated final class CameraPreviewBudget: Sendable {
    private struct Counts { var bytes = 0, peak = 0, backings = 0 }
    private let state = Mutex(Counts())
    private let limit: Int
    private let onBytesChanged: @Sendable (Int) -> Void
    init(limit: Int, onBytesChanged: @escaping @Sendable (Int) -> Void = { _ in }) {
      self.limit = limit
      self.onBytesChanged = onBytesChanged
    }
    func reserve(_ bytes: Int) -> CameraPreviewReservation? {
      state.withLockIfAvailable {
        guard bytes > 0, $0.backings < 3, bytes <= limit - $0.bytes else { return nil }
        $0.bytes += bytes
        $0.backings += 1
        $0.peak = max($0.peak, $0.bytes)
        onBytesChanged($0.bytes)
        return CameraPreviewReservation(budget: self, bytes: bytes)
      } ?? nil
    }
    fileprivate func release(_ bytes: Int) {
      state.withLock {
        $0.bytes -= bytes
        $0.backings -= 1
        onBytesChanged($0.bytes)
      }
    }
    var usage: CameraPreviewUsage {
      state.withLock {
        CameraPreviewUsage(bytes: $0.bytes, peakBytes: $0.peak, backings: $0.backings)
      }
    }
  }
  nonisolated final class CameraPreviewReservation: Sendable {
    private let budget: CameraPreviewBudget
    private let bytes: Int
    fileprivate init(budget: CameraPreviewBudget, bytes: Int) {
      self.budget = budget
      self.bytes = bytes
    }
    deinit { budget.release(bytes) }
  }

  /// Immutable pixels, retained by CGDataProvider itself, not merely by the image packet.
  /// C info is an ARC pin to this checked-Sendable owner, never an escaped pixel address.
  nonisolated final class CameraPreviewBacking: Sendable {
    private let bytes: Data
    private let reservation: CameraPreviewReservation
    private let pinOutstanding = Mutex(false)
    init(bytes: Data, reservation: CameraPreviewReservation) {
      self.bytes = bytes
      self.reservation = reservation
    }
    private static func read(
      _ info: UnsafeMutableRawPointer?, into buffer: UnsafeMutableRawPointer,
      at position: Int64, count: Int
    ) -> Int {
      guard let info, position >= 0, position <= Int64(Int.max), count >= 0 else { return 0 }
      let owner = Unmanaged<CameraPreviewBacking>.fromOpaque(info).takeUnretainedValue()
      let offset = Int(position)
      guard offset < owner.bytes.count else { return 0 }
      let length = min(count, owner.bytes.count - offset)
      owner.bytes.withUnsafeBytes {
        buffer.copyMemory(from: $0.baseAddress!.advanced(by: offset), byteCount: length)
      }
      return length  // Both source and Core Graphics destination pointers are scoped to this call.
    }
    private static func releasePin(_ info: UnsafeMutableRawPointer?) {
      guard let info else { return }
      let owner = Unmanaged<CameraPreviewBacking>.fromOpaque(info).takeUnretainedValue()
      let release = owner.pinOutstanding.withLock { value in
        let old = value
        value = false
        return old
      }
      if release { Unmanaged<CameraPreviewBacking>.fromOpaque(info).release() }
    }
    func image(descriptor d: CameraFrameDescriptor) -> CGImage? {
      guard bytes.count == d.byteCount else { return nil }
      // One provider per backing. Avoid a second hidden full-frame CFData copy.
      guard
        pinOutstanding.withLock({ value in
          if value { return false }
          value = true
          return true
        })
      else { return nil }
      let info = Unmanaged.passRetained(self).toOpaque()
      var callbacks = CGDataProviderDirectCallbacks(
        version: 0, getBytePointer: nil,
        releaseBytePointer: nil,
        getBytesAtPosition: { CameraPreviewBacking.read($0, into: $1, at: $2, count: $3) },
        releaseInfo: { CameraPreviewBacking.releasePin($0) })
      guard
        let provider = CGDataProvider(
          directInfo: info, size: Int64(d.byteCount), callbacks: &callbacks)
      else {
        // A creator reference still owns self here; the pin gate also covers synchronous failed-create cleanup.
        Self.releasePin(info)
        return nil
      }
      guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
      return CGImage(
        width: d.width, height: d.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: d.bytesPerRow, space: space,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
          CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
  }
  nonisolated struct CameraPreviewInput: Sendable {
    let id: UUID, subscription: UUID
    let metadata: CameraFrameMetadata
    let backing: CameraPreviewBacking
  }
  nonisolated struct CameraPreviewFrame: Sendable {
    let subscription: UUID
    let metadata: CameraFrameMetadata
    let image: CGImage
  }
  protocol CameraPreviewConverting: Actor {
    func convert(_ input: CameraPreviewInput) async -> CameraPreviewFrame?
  }
  actor CameraPreviewConverter: CameraPreviewConverting {
    func convert(_ input: CameraPreviewInput) -> CameraPreviewFrame? {
      guard let image = input.backing.image(descriptor: input.metadata.descriptor) else {
        return nil
      }
      return CameraPreviewFrame(
        subscription: input.subscription, metadata: input.metadata, image: image)
    }
  }
  nonisolated struct CameraPreviewStatistics: Sendable {
    var admitted: UInt64 = 0, converted: UInt64 = 0, presented: UInt64 = 0
    var busyDrops: UInt64 = 0, cadenceDrops: UInt64 = 0, budgetDrops: UInt64 = 0
    var contextDrops: UInt64 = 0, staleDrops: UInt64 = 0, failures: UInt64 = 0
    var conversion = CameraLatencyWindow(), age = CameraLatencyWindow(),
      copying = CameraLatencyWindow()
    var firstPresentation: Double?, lastPresentation: Double?
    mutating func increment(_ key: WritableKeyPath<Self, UInt64>) {
      if self[keyPath: key] < .max { self[keyPath: key] += 1 }
    }
    var displayFPS: Double? {
      guard presented > 1, let firstPresentation, let lastPresentation,
        lastPresentation > firstPresentation
      else { return nil }
      return Double(presented - 1) / (lastPresentation - firstPresentation)
    }
  }

  /// One retained worker, optional independent bytes, latest-only output. Never reads FrameStore.acquire.
  nonisolated final class CameraDiagnosticPreview: Sendable {
    private struct State {
      var enabled = false
      var context: CameraSourceContext?
      var subscription = UUID()
      var busy: UUID?
      var input: CameraPreviewInput?
      var pending: CameraPreviewFrame?
      var lastSeen: UInt64?
      var nextOffer: Double = 0
      var statistics = CameraPreviewStatistics()
      var workerClaimed = false
    }
    let configuration: CameraPreviewConfiguration
    let budget: CameraPreviewBudget
    private let state = Mutex(State())
    private let clock: @Sendable () -> Double
    private let converter: any CameraPreviewConverting
    let jobCompletions: AsyncStream<Void>
    private let completed: AsyncStream<Void>.Continuation
    private let wake: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(
      configuration: CameraPreviewConfiguration = .init(),
      clock: @escaping @Sendable () -> Double = CameraHostClock.now,
      converter: any CameraPreviewConverting = CameraPreviewConverter(),
      onBytesChanged: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
      precondition(
        configuration.maximumFPS.isFinite && configuration.maximumFPS > 0
          && configuration.maximumPayloadBytes > 0 && configuration.maximumBytes > 0
          && configuration.maximumAge.isFinite && configuration.maximumAge > 0)
      self.configuration = configuration
      self.clock = clock
      self.converter = converter
      budget = CameraPreviewBudget(
        limit: configuration.maximumBytes, onBytesChanged: onBytesChanged)
      let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      wake = stream.stream
      continuation = stream.continuation
      let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      jobCompletions = completion.stream
      completed = completion.continuation
    }
    deinit {
      continuation.finish()
      completed.finish()
    }
    private static func clear(_ s: inout State) {
      s.subscription = UUID()
      s.pending = nil
      if s.input != nil {
        s.input = nil
        s.busy = nil
      }
      // If conversion actually owns the input, its busy token stays until completion.
      s.lastSeen = nil
      s.nextOffer = 0
    }
    func setEnabled(_ enabled: Bool) {
      state.withLock {
        guard $0.enabled != enabled else { return }
        $0.enabled = enabled
        Self.clear(&$0)
      }
    }
    func updateContext(_ context: CameraSourceContext) {
      state.withLock {
        guard $0.context != context else { return }
        $0.context = context
        Self.clear(&$0)
        $0.statistics = CameraPreviewStatistics()
      }
    }
    func invalidate(_ context: CameraSourceContext) {
      state.withLock {
        if $0.context == context {
          $0.context = nil
          Self.clear(&$0)
        }
      }
    }
    var statistics: CameraPreviewStatistics { state.withLock { $0.statistics } }
    /// Called only after primary publication, outside the primary state lock. No async/per-frame Task.
    func offer(metadata: CameraFrameMetadata, copy: () -> Data) {
      let now = clock()
      let ticket: (UUID, UUID, CameraPreviewReservation)? =
        state.withLockIfAvailable {
          guard $0.enabled, $0.context == metadata.context else { return nil }
          guard metadata.frameID > ($0.lastSeen ?? 0), !metadata.mirrored,
            metadata.capturedAt.isFinite, now.isFinite, now >= metadata.capturedAt,
            now - metadata.capturedAt <= configuration.maximumAge,
            metadata.descriptor.byteCount <= configuration.maximumPayloadBytes
          else {
            $0.statistics.increment(\.staleDrops)
            return nil
          }
          $0.lastSeen = metadata.frameID
          guard $0.busy == nil else {
            $0.statistics.increment(\.busyDrops)
            return nil
          }
          guard now >= $0.nextOffer else {
            $0.statistics.increment(\.cadenceDrops)
            return nil
          }
          guard let reservation = budget.reserve(metadata.descriptor.byteCount) else {
            $0.statistics.increment(\.budgetDrops)
            return nil
          }
          let id = UUID()
          $0.busy = id
          $0.nextOffer = now + 1 / configuration.maximumFPS
          return (id, $0.subscription, reservation)
        } ?? nil
      guard let ticket else { return }
      let bytes = copy()
      let input = CameraPreviewInput(
        id: ticket.0, subscription: ticket.1, metadata: metadata,
        backing: CameraPreviewBacking(bytes: bytes, reservation: ticket.2))
      state.withLock {
        guard $0.busy == ticket.0 else { return }
        guard $0.enabled, $0.context == metadata.context, $0.subscription == ticket.1,
          bytes.count == metadata.descriptor.byteCount
        else {
          $0.busy = nil
          $0.statistics.increment(\.contextDrops)
          return
        }
        $0.statistics.increment(\.admitted)
        $0.statistics.copying.record(seconds: clock() - now)
        $0.input = input
        continuation.yield(())
      }
    }
    @concurrent func run() async {
      let claimed = state.withLock { s in
        guard !s.workerClaimed else { return false }
        s.workerClaimed = true
        return true
      }
      guard claimed else { return }
      // Claim is lifetime-long. Cancellation cannot create a second worker while an old conversion is stuck.
      for await _ in wake {
        if Task.isCancelled { break }
        await processNextJob()
        completed.yield(())
      }
      state.withLock {
        $0.enabled = false
        Self.clear(&$0)
      }
    }
    private func processNextJob() async {
      let input = state.withLock { s in
        let value = s.input
        s.input = nil
        return value
      }
      guard let input else { return }
      let started = clock()
      let image = await converter.convert(input)
      state.withLock {
        guard $0.busy == input.id else { return }
        $0.busy = nil
        guard !Task.isCancelled, $0.enabled, $0.context == input.metadata.context,
          $0.subscription == input.subscription
        else {
          $0.statistics.increment(\.contextDrops)
          return
        }
        guard let image, image.metadata == input.metadata,
          image.subscription == input.subscription
        else {
          $0.statistics.increment(\.failures)
          return
        }
        $0.statistics.increment(\.converted)
        $0.statistics.conversion.record(seconds: clock() - started)
        $0.pending = image
      }
    }
    func isCurrent(_ frame: CameraPreviewFrame, at now: Double) -> Bool {
      state.withLock {
        $0.enabled && $0.context == frame.metadata.context && $0.subscription == frame.subscription
          && now >= frame.metadata.capturedAt
          && now - frame.metadata.capturedAt <= configuration.maximumAge
      }
    }
    func takeLatest(at now: Double) -> CameraPreviewFrame? {
      state.withLock {
        guard let frame = $0.pending else { return nil }
        $0.pending = nil
        guard $0.enabled, $0.context == frame.metadata.context,
          $0.subscription == frame.subscription,
          now >= frame.metadata.capturedAt,
          now - frame.metadata.capturedAt <= configuration.maximumAge
        else {
          $0.statistics.increment(\.staleDrops)
          return nil
        }
        $0.statistics.increment(\.presented)
        $0.statistics.age.record(seconds: now - frame.metadata.capturedAt)
        $0.statistics.firstPresentation = $0.statistics.firstPresentation ?? now
        $0.statistics.lastPresentation = now
        return frame
      }
    }
  }
  nonisolated enum CameraPreviewProcessMemory {
    static func residentBytes() -> UInt64? {
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
      }
      return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
  }

  nonisolated enum CameraPreviewLayout {
    static func rect(image: CGSize, in bounds: CGSize) -> CGRect {
      guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0,
        image.width.isFinite, image.height.isFinite, bounds.width.isFinite, bounds.height.isFinite
      else { return .zero }
      let scale = min(bounds.width / image.width, bounds.height / image.height)
      let width = image.width * scale
      let height = image.height * scale
      return CGRect(
        x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height
      )
    }
    static func mirroredPoint(_ canonical: CGPoint, in rect: CGRect) -> CGPoint {
      CGPoint(
        x: rect.minX + (1 - canonical.x) * rect.width,
        y: rect.minY + (1 - canonical.y) * rect.height)
    }
  }
#endif
