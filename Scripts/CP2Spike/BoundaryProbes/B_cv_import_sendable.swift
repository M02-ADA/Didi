import CoreVideo
import Foundation

// Imported CVBuffer cannot satisfy Sendable. Compiler-only experiment; not production code.
nonisolated func requiresSendable<T: Sendable>(_ value: T) {}
nonisolated func imported(_ buffer: CVPixelBuffer) { requiresSendable(buffer) }
