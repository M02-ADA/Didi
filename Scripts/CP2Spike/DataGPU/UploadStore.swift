import Foundation
import Metal
import RealityKit
import simd

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

nonisolated struct UploadResult: Sendable, Codable {
  let token: UUID
  let frameID: UInt64
  let gpuSucceeded: Bool
  let activated: [String]
  let cancelled: Bool
  let stagingCopyMilliseconds: Double
  let submittedToCallbackMilliseconds: Double
  let gpuMilliseconds: Double
  let error: String?
}
@MainActor final class TextureSurface {
  let texture: LowLevelTexture
  let model: ModelEntity
  init() throws {
    texture = try LowLevelTexture(
      descriptor: .init(
        pixelFormat: .bgra8Unorm_srgb, width: 512, height: 768,
        textureUsage: [.shaderRead, .renderTarget]))
    let resource = try TextureResource(from: texture)
    var material = UnlitMaterial(applyPostProcessToneMap: false)
    material.color = .init(tint: .white, texture: .init(resource))
    material.blending = .transparent(opacity: 1.0)
    // Full 0–1 UVs, horizontal mirror once; positive entity scale preserves culling.
    var mesh = MeshDescriptor(name: "full-canvas-mirrored")
    mesh.positions = .init([[-0.5, -0.5, 0], [0.5, -0.5, 0], [-0.5, 0.5, 0], [0.5, 0.5, 0]])
    mesh.normals = .init(Array(repeating: [0, 0, 1], count: 4))
    mesh.textureCoordinates = .init([[1, 0], [0, 0], [1, 1], [0, 1]])
    mesh.primitives = .triangles([0, 1, 2, 1, 3, 2])
    model = ModelEntity(mesh: try MeshResource.generate(from: [mesh]), materials: [material])
    model.isEnabled = false  // Never show uninitialized storage.
  }
}
// Completion owns this MainActor reference even if the demo/store is destroyed mid-upload.
// No mutable Metal value crosses executors; only this actor-confined lifetime owner does.
@MainActor final class StagingPin {
  private var buffers: [any MTLBuffer]
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var released = false
  var retainedBuffers: Int { buffers.count }
  init(_ buffers: [any MTLBuffer]) { self.buffers = buffers }
  fileprivate func release() {
    guard !released else { return }
    buffers.removeAll()
    released = true
    waiter?.resume()
    waiter = nil
  }
  func untilReleased() async {
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }
}
@MainActor final class UploadJob {
  let token = UUID()
  let frame: SyntheticCutoutFrame
  let slots: [PlayerID]
  let backs: [PlayerID: Int]
  let started: UInt64
  let stagingMS: Double
  var cancelled = false
  var waiter: CheckedContinuation<UploadResult, Never>?
  init(
    frame: SyntheticCutoutFrame, slots: [PlayerID], backs: [PlayerID: Int], started: UInt64,
    stagingMS: Double
  ) {
    self.frame = frame
    self.slots = slots
    self.backs = backs
    self.started = started
    self.stagingMS = stagingMS
  }
}

// Isolated experimental consumer, NOT a production CP2 API. All mutable Metal resources stay MainActor.
@MainActor final class UploadStore {
  let root = Entity()
  private(set) var surfaces: [PlayerID: [TextureSurface]] = [:]
  private(set) var front: [PlayerID: Int] = [:]
  private(set) var displayed: [PlayerID: BodySnapshot] = [:]
  private(set) var context: BodyInputContext
  let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let staging: [any MTLBuffer]
  private let readbacks: [any MTLBuffer]
  private var job: UploadJob?
  private(set) var lastPin: StagingPin?
  private(set) var pending: SyntheticCutoutFrame?
  private var watermark: UInt64?
  private(set) var commits = 0, completions = 0, dropped = 0, ignoredCallbacks = 0, quarantined = 0
  private(set) var lastResult: UploadResult?
  private(set) var peakInFlight = 0
  var busy: Bool { job != nil }
  var onActivation: (@MainActor () -> Void)?
  init(context: BodyInputContext = spikeContext(), readback: Bool = true) throws {
    self.context = context
    var made: [PlayerID: [TextureSurface]] = [:]
    for id in PlayerID.allCases { made[id] = try [TextureSurface(), TextureSurface()] }
    guard let d = made[.player1]?.first?.texture.read().device, let q = d.makeCommandQueue() else {
      throw SpikeError.invalid("RealityKit device/queue unavailable")
    }
    device = d
    queue = q
    for pair in made.values {
      for surface in pair {
        try check(
          surface.texture.read().device.registryID == d.registryID, "same actual RK backing device")
        root.addChild(surface.model)
      }
    }
    surfaces = made
    var s: [any MTLBuffer] = []
    var r: [any MTLBuffer] = []
    for _ in PlayerID.allCases {
      guard let b = d.makeBuffer(length: 4096 * 768, options: .storageModeShared) else {
        throw SpikeError.invalid("staging allocation")
      }
      s.append(b)
      if readback {
        guard let v = d.makeBuffer(length: 4096 * 768, options: .storageModeShared) else {
          throw SpikeError.invalid("readback allocation")
        }
        r.append(v)
      }
    }
    staging = s
    readbacks = r
  }
  func setContext(_ new: BodyInputContext) {
    if new.sessionGeneration != context.sessionGeneration
      || new.cameraGeometryRevision != context.cameraGeometryRevision
    {
      watermark = nil
    }
    context = new
    pending = nil
    for id in PlayerID.allCases {
      if let shown = displayed[id], !new.accepts(shown, playerID: id) {
        surfaces[id]?.forEach { $0.model.isEnabled = false }
        displayed[id] = nil
        front[id] = nil
      }
    }
    // In-flight still pins staging; completion checks current context per slot.
  }
  private func presentationCompatible(_ snapshot: BodySnapshot, _ id: PlayerID) -> Bool {
    context.calibrationRevisions[id] != nil
      && snapshot.players[id]?.calibrationRevision != nil
      && snapshot.players[id]?.trackingStatus == .reliable
      && context.accepts(snapshot, playerID: id)
  }
  @discardableResult func offer(_ frame: SyntheticCutoutFrame) throws -> Bool {
    try frame.bodySnapshot.validate()
    guard frame.bodySnapshot.sessionGeneration == context.sessionGeneration,
      frame.bodySnapshot.cameraGeometryRevision == context.cameraGeometryRevision,
      PlayerID.allCases.contains(where: { presentationCompatible(frame.bodySnapshot, $0) }),
      watermark == nil || frame.bodySnapshot.frameID > watermark!
    else {
      dropped += 1
      return false
    }
    for (id, image) in frame.players {
      _ = try checkedBytes(width: image.width, height: image.height, stride: image.bytesPerRow)
      try check(image.bytes.count == image.bytesPerRow * image.height, "immutable data length")
      _ = try image.placement.fullQuad(
        width: image.width, height: image.height, lane: spikeLayout.centerX(for: id))
    }
    if pending != nil { dropped += 1 }
    watermark = frame.bodySnapshot.frameID
    pending = frame
    return true
  }
  func cancelPending() { pending = nil }
  func cancel(_ token: UUID) { if job?.token == token { job?.cancelled = true } }
  func encodeAndSubmit(
    gate: (any MTLSharedEvent)? = nil, failBeforeCommit: Bool = false,
    completionFailureForTest: Bool = false
  ) throws -> UUID? {
    guard job == nil else { return nil }
    guard let frame = pending else { return nil }
    pending = nil
    let ids = PlayerID.allCases.filter {
      frame.players[$0] != nil && presentationCompatible(frame.bodySnapshot, $0)
    }
    guard !ids.isEmpty else { return nil }
    guard let cb = queue.makeCommandBuffer() else { throw SpikeError.invalid("command buffer") }
    cb.label = "CP2 immutable Data pair \(frame.bodySnapshot.frameID)"
    if let gate { cb.encodeWaitForEvent(gate, value: 1) }
    var backs: [PlayerID: Int] = [:]
    let copyStart = nanos()
    for id in ids {
      let index = id == .player1 ? 0 : 1
      let image = frame.players[id]!
      image.bytes.withUnsafeBytes { raw in
        staging[index].contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
      }  // No escaped Data pointer; Metal owns a separate bounded copy.
    }
    let copyMS = Double(nanos() - copyStart) / 1e6
    do {
      guard let blit = cb.makeBlitCommandEncoder() else { throw SpikeError.invalid("blit encoder") }
      defer { blit.endEncoding() }
      for id in ids {
        let index = id == .player1 ? 0 : 1
        let image = frame.players[id]!
        let back = 1 - (front[id] ?? 1)
        backs[id] = back
        let destination = surfaces[id]![back].texture.replace(using: cb)
        try check(
          destination.device.registryID == device.registryID
            && destination.pixelFormat == .bgra8Unorm_srgb, "destination device/format")
        blit.copy(
          from: staging[index], sourceOffset: 0, sourceBytesPerRow: image.bytesPerRow,
          sourceBytesPerImage: image.bytes.count,
          sourceSize: .init(width: 512, height: 768, depth: 1), to: destination,
          destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        if !readbacks.isEmpty {
          blit.copy(
            from: destination, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: 512, height: 768, depth: 1), to: readbacks[index],
            destinationOffset: 0, destinationBytesPerRow: 2048, destinationBytesPerImage: 2048 * 768
          )
        }
        if failBeforeCommit { throw SpikeError.invalid("injected precommit encoding error") }
      }
    } catch {
      // No commit. Retire every back passed to replace; old visible fronts survive.
      for (id, back) in backs {
        let old = surfaces[id]![back]
        old.model.removeFromParent()
        let replacement = try TextureSurface()
        surfaces[id]![back] = replacement
        root.addChild(replacement.model)
        quarantined += 1
      }
      throw error
    }
    let current = UploadJob(
      frame: frame, slots: ids, backs: backs, started: nanos(), stagingMS: copyMS)
    job = current
    peakInFlight = max(peakInFlight, 1)
    let token = current.token
    let pin = StagingPin(staging + readbacks)
    lastPin = pin
    cb.addCompletedHandler { [weak self, pin] completed in
      let ok = completed.status == .completed && !completionFailureForTest
      let error =
        completionFailureForTest
        ? "injected terminal failure AFTER actual GPU completion"
        : completed.error.map { String(describing: $0) }
      let gpuMS = max(0, (completed.gpuEndTime - completed.gpuStartTime) * 1000)
      // Only immutable scalars/token hop executors, never command buffer or storage.
      Task { @MainActor [weak self, pin] in
        pin.release()
        self?.complete(token, ok: ok, error: error, gpuMS: gpuMS)
      }
    }
    commits += 1
    cb.commit()  // Exactly one submission authority.
    return token
  }
  func result(_ token: UUID) async throws -> UploadResult {
    if lastResult?.token == token { return lastResult! }
    guard let job, job.token == token, job.waiter == nil else {
      throw SpikeError.invalid("unknown/duplicate result waiter")
    }
    return await withCheckedContinuation { job.waiter = $0 }
  }
  private func complete(_ token: UUID, ok: Bool, error: String?, gpuMS: Double) {
    guard let current = job, current.token == token else {
      ignoredCallbacks += 1
      return
    }
    completions += 1
    var activated: [String] = []
    if ok && !current.cancelled {
      // All placement/debug/visibility mutations are synchronous; no await in this block.
      for id in current.slots where presentationCompatible(current.frame.bodySnapshot, id) {
        let image = current.frame.players[id]!
        let back = current.backs[id]!
        if let rect = try? image.placement.fullQuad(
          width: 512, height: 768, lane: spikeLayout.centerX(for: id))
        {
          let next = surfaces[id]![back]
          next.model.scale = [Float(rect.width), Float(rect.height), 1]
          next.model.position = [
            Float(rect.x + rect.width / 2), Float(rect.y + rect.height / 2), 0,
          ]
          surfaces[id]!.forEach { $0.model.isEnabled = false }
          next.model.isEnabled = true
          front[id] = back
          displayed[id] = current.frame.bodySnapshot
          activated.append(id.rawValue)
        }
      }
    }
    let value = UploadResult(
      token: token, frameID: current.frame.bodySnapshot.frameID, gpuSucceeded: ok,
      activated: activated, cancelled: current.cancelled,
      stagingCopyMilliseconds: current.stagingMS,
      submittedToCallbackMilliseconds: Double(nanos() - current.started) / 1e6,
      gpuMilliseconds: gpuMS, error: error)
    lastResult = value
    job = nil  // Pins/staging become reusable ONLY after GPU terminal callback.
    current.waiter?.resume(returning: value)
    onActivation?()
  }
  // Verification only: readback was encoded in the same command buffer and is read after completion.
  func verifyReadback(_ frame: SyntheticCutoutFrame, slots: [PlayerID] = PlayerID.allCases) throws {
    try check(!busy && readbacks.count == 2, "readback fence")
    for id in slots {
      let i = id == .player1 ? 0 : 1
      let raw = readbacks[i].contents()
      for y in 0..<768 {
        for x in 0..<512 {
          try check(
            raw.loadUnaligned(fromByteOffset: y * 2048 + x * 4, as: UInt32.self)
              == syntheticPixel(x: x, y: y, player: id, frame: frame.bodySnapshot.frameID),
            "actual GPU readback differs")
        }
      }
    }
  }
  func replayCompletionForTest(_ token: UUID) {
    // This diagnostic hook may replay only a stale callback, never forge a live GPU fence.
    guard job?.token != token else { return }
    complete(token, ok: true, error: nil, gpuMS: 0)
  }
}
