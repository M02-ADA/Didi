//
//  PerfSpans.swift
//  Sedactive
//

import Foundation
import QuartzCore
#if DEBUG
import Synchronization
#endif

/// DEBUG ONLY measurement (Kevin, 22 November 2026; with `-perfLog`): how long named pieces of per-frame
/// work take on the thread that runs them, summed per `LaserPerfMonitor` window and reported in its
/// `[LaserPerf]` line (per-frame average, the longest single call, and the call count). Release and
/// runs without `-perfLog` just run the work.
nonisolated enum PerfSpans {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-perfLog")
    private struct Span { var total = 0.0, longest = 0.0, count = 0 }
    private static let spans = Mutex([String: Span]())

    @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let start = CACurrentMediaTime()
        defer {
            let elapsed = CACurrentMediaTime() - start
            spans.withLock {
                var span = $0[name] ?? Span()
                span.total += elapsed
                span.longest = max(span.longest, elapsed)
                span.count += 1
                $0[name] = span
            }
        }
        return try work()
    }

    /// Adds a duration measured elsewhere (e.g. from one thread to another) as one call of `name`.
    static func record(_ name: String, _ elapsed: Double) {
        guard isEnabled else { return }
        spans.withLock {
            var span = $0[name] ?? Span()
            span.total += elapsed
            span.longest = max(span.longest, elapsed)
            span.count += 1
            $0[name] = span
        }
    }

    /// The window's spans (ms: average per frame over `frames`, longest call, calls), then cleared.
    static func drain(frames: Int) -> String {
        let taken = spans.withLock { current -> [String: Span] in defer { current = [:] }; return current }
        guard !taken.isEmpty, frames > 0 else { return "" }
        return taken.sorted { $0.value.total > $1.value.total }.map { name, s in
            String(format: "%@ %.2f/fr max %.1f n%d", name, s.total * 1000 / Double(frames), s.longest * 1000, s.count)
        }.joined(separator: " · ")
    }
    #else
    @inline(__always) @discardableResult
    static func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T { try work() }
    @inline(__always) static func record(_ name: String, _ elapsed: Double) {}
    #endif
}
