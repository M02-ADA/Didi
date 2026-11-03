// Isolated CP2 compiler reproduction. Not a member of any Xcode target.
import Foundation
import CoreVideo

nonisolated enum CutoutSpikeError: Error { case pool(Int32), encoding }
nonisolated struct CutoutSpikeFrame: Sendable { let bodySnapshot: BodySnapshot }
nonisolated final class CutoutSpikePixels {
    fileprivate let buffers: [PlayerID: CVPixelBuffer]
    fileprivate init(_ buffers: [PlayerID: CVPixelBuffer]) { self.buffers = buffers }
}

actor CutoutSpikeProducer {
    private let pool: CVPixelBufferPool
    let width: Int, height: Int
    init(width: Int = 64, height: Int = 96, capacity: Int = 6) throws {
        self.width = width; self.height = height
        self.capacity = capacity
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw CutoutSpikeError.pool(status) }
        self.pool = pool
    }
    private let capacity: Int

    // Actor serialization + pool threshold bounds this synthetic producer. No per-capture tasks exist.
    func make(players: Set<PlayerID> = Set(PlayerID.allCases)) throws -> sending CutoutSpikePixels {
        var buffers: [PlayerID: CVPixelBuffer] = [:]
        for id in PlayerID.allCases where players.contains(id) {
            var result: CVPixelBuffer?
            let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: capacity] as CFDictionary
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
            guard status == kCVReturnSuccess, let result else { throw CutoutSpikeError.pool(status) }
            try Self.fill(result, player: id)
            buffers[id] = result
        }
        return CutoutSpikePixels(buffers)
    }

    private static func fill(_ buffer: CVPixelBuffer, player: PlayerID) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw CutoutSpikeError.encoding }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw CutoutSpikeError.encoding }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(address, 0, stride * h)
        for y in 8..<min(92, h) {
            let row = address.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 12..<min(48, w) {
                let edge = x == 12 || x == 47 || y == 8 || y == 91
                let a: UInt8 = edge ? 128 : 255
                // Premultiplied BGRA. Yellow top-left and green bottom-right are orientation markers.
                let marker = y < 20 && x < 24
                row[x * 4] = player == .player2 && !marker ? a : 0
                row[x * 4 + 1] = marker || (y > 78 && x > 36) ? a : 0
                row[x * 4 + 2] = player == .player1 || marker ? a : 0
                row[x * 4 + 3] = a
            }
        }
    }
}


@MainActor final class CutoutSpikeStore {
    private var acceptedFrame: CutoutSpikeFrame?
    private var acceptedPixels: CutoutSpikePixels?
    func publish(_ frame: CutoutSpikeFrame, pixels: sending CutoutSpikePixels) {
        acceptedFrame = frame
        acceptedPixels = pixels
    }
}
