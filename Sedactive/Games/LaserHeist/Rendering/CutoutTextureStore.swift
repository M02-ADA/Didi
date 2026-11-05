//
//  CutoutTextureStore.swift
//  Sedactive
//

import Metal
import RealityKit

/// GPU side of the live player cutouts (CP2 Phase 2).
///
/// Each player owns two persistent `LowLevelTexture`s: a front that is shown
/// and a back that is hidden. An upload writes only into hidden backs, so a
/// texture RealityKit swaps in when its command buffer completes is never seen
/// until the presenter checks the lease and flips it to the front.
///
/// Bounds: one staging buffer per player, sized to the image and capped by
/// `maximumImageBytes`, and at most one command buffer in flight. The store
/// handles its own GPU completion: it clears its busy state when the GPU has
/// actually finished, whether or not the caller that submitted still exists,
/// and staging is reused only after that. The completion handler keeps the
/// staging alive even if the store is released first. Textures are created
/// once per canvas size, never per frame.
@MainActor
final class CutoutTextureStore {
    enum StoreError: Error, Equatable {
        case busy, imageTooLarge, commandBufferUnavailable
    }

    /// Two hidden-or-shown textures for one player at one canvas size.
    struct Surfaces {
        let width: Int
        let height: Int
        let textures: [LowLevelTexture]
        let resources: [TextureResource]
    }

    /// One submitted command buffer and everything it reads or writes. It is
    /// referenced by the GPU completion handler, which pins `staging` until
    /// the GPU has finished.
    final class Upload {
        let players: [PlayerID]
        /// The surface index each player's image was written into.
        let targets: [PlayerID: Int]
        fileprivate let staging: [MTLBuffer]
        /// Set when its result must not be shown (context change, detach).
        var isCancelled = false
        fileprivate init(targets: [(PlayerID, Int)], staging: [MTLBuffer]) {
            players = targets.map(\.0)
            self.targets = Dictionary(uniqueKeysWithValues: targets)
            self.staging = staging
        }
    }

    /// The device RealityKit renders with, read back from one of its own textures.
    let device: MTLDevice
    let maximumImageBytes: Int
    private let queue: MTLCommandQueue
    private(set) var surfaces: [PlayerID: Surfaces] = [:]
    private var frontIndex: [PlayerID: Int] = [:]
    private var staging: [PlayerID: MTLBuffer] = [:]
    private(set) var inFlight: Upload?
    private(set) var submittedCount = 0
    private(set) var completedCount = 0
    /// Wakes whoever presents from this store once it can accept an upload
    /// again, including after an upload whose submitter has gone away.
    var onIdle: (() -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Fails when Metal or `LowLevelTexture` is unavailable; callers keep the
    /// pictogram fallback.
    init(maximumImageBytes: Int) throws {
        let probe = try LowLevelTexture(descriptor: Self.descriptor(width: 1, height: 1))
        device = probe.read().device
        guard let queue = device.makeCommandQueue() else { throw StoreError.commandBufferUnavailable }
        queue.label = "Sedactive.cutouts"
        self.queue = queue
        self.maximumImageBytes = maximumImageBytes
    }

    var stagingBufferCount: Int { staging.count }

    /// The texture a player's `index` surface shows, creating both surfaces
    /// for this canvas size if needed. Returns whether they were (re)created,
    /// which leaves the player with nothing on the front.
    @discardableResult
    func prepareSurfaces(for player: PlayerID, width: Int, height: Int) throws -> Bool {
        if let current = surfaces[player], current.width == width, current.height == height { return false }
        let textures = try (0..<2).map { _ in try LowLevelTexture(descriptor: Self.descriptor(width: width, height: height)) }
        let resources = try textures.map { try TextureResource(from: $0) }
        surfaces[player] = Surfaces(width: width, height: height, textures: textures, resources: resources)
        frontIndex[player] = nil
        return true
    }

    func frontIndex(for player: PlayerID) -> Int? { frontIndex[player] }

    /// The hidden surface the next upload for `player` writes into.
    func backIndex(for player: PlayerID) -> Int { (frontIndex[player] ?? 1) == 0 ? 1 : 0 }

    /// Copies each image into its player's staging buffer and blits it into
    /// that player's hidden back texture, in one command buffer. After the GPU
    /// finishes, on the main actor, the store first clears its busy state,
    /// then runs `completion` with whether it succeeded, then calls `onIdle`.
    /// Throws before anything is encoded if the store is busy or an image does
    /// not fit, so a failed call changes no texture.
    func submit(
        _ images: [(player: PlayerID, image: CutoutImage)],
        completion: @escaping @MainActor (Upload, Bool) -> Void
    ) throws -> Upload {
        guard inFlight == nil else { throw StoreError.busy }
        for (player, image) in images {
            let descriptor = image.descriptor
            guard descriptor.byteCount <= maximumImageBytes else { throw StoreError.imageTooLarge }
            try prepareSurfaces(for: player, width: descriptor.width, height: descriptor.height)
            if (staging[player]?.length ?? 0) < descriptor.byteCount {
                guard let buffer = device.makeBuffer(length: descriptor.byteCount, options: .storageModeShared) else {
                    throw StoreError.commandBufferUnavailable
                }
                buffer.label = "Sedactive.cutout.staging.\(player.rawValue)"
                staging[player] = buffer
            }
        }
        guard let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw StoreError.commandBufferUnavailable
        }
        var pinned: [MTLBuffer] = []
        var targets: [(PlayerID, Int)] = []
        for (player, image) in images {
            guard let buffer = staging[player], let target = surfaces[player] else { continue }
            let descriptor = image.descriptor
            // Scoped read of the immutable CP2 bytes into our own staging; the
            // source address never escapes this closure. Row stride is kept as is.
            image.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: min(bytes.count, descriptor.byteCount))
                }
            }
            let index = backIndex(for: player)
            let destination = target.textures[index].replace(using: commandBuffer)
            blit.copy(
                from: buffer, sourceOffset: 0,
                sourceBytesPerRow: descriptor.bytesPerRow, sourceBytesPerImage: descriptor.byteCount,
                sourceSize: MTLSize(width: descriptor.width, height: descriptor.height, depth: 1),
                to: destination, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            pinned.append(buffer)
            targets.append((player, index))
        }
        blit.endEncoding()
        let upload = Upload(targets: targets, staging: pinned)
        commandBuffer.addCompletedHandler { [upload] buffer in
            let succeeded = buffer.status == .completed
            Task { @MainActor [weak self] in
                self?.finish(upload)
                completion(upload, succeeded)
                self?.becameIdle()
            }
        }
        inFlight = upload
        submittedCount += 1
        commandBuffer.commit()
        return upload
    }

    /// Suspends until no upload is on the GPU.
    func waitUntilIdle() async {
        guard inFlight != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The GPU has finished `upload`: staging may be reused from now on.
    private func finish(_ upload: Upload) {
        completedCount += 1
        if inFlight === upload { inFlight = nil }
    }

    private func becameIdle() {
        guard inFlight == nil else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
        onIdle?()
    }

    /// Makes the surface `upload` wrote for `player` the front, after the
    /// upload has completed and the caller has checked it is still current.
    /// Returns that index, or `nil` if the upload has no image for `player`.
    /// Never derived from the current front, which a fallback may have reset.
    func activate(_ upload: Upload, player: PlayerID) -> Int? {
        guard inFlight !== upload, let index = upload.targets[player] else { return nil }
        frontIndex[player] = index
        return index
    }

    /// Forgets which surface is shown, e.g. after a fallback, so the next
    /// upload can use either one.
    func clearFront(_ player: PlayerID) {
        frontIndex[player] = nil
    }

    private static func descriptor(width: Int, height: Int) -> LowLevelTexture.Descriptor {
        // CP2 images are BGRA8, sRGB-encoded and straight alpha; the blit keeps the bytes as they are.
        LowLevelTexture.Descriptor(
            textureType: .type2D, pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, depth: 1, mipmapLevelCount: 1,
            textureUsage: [.shaderRead])
    }
}
