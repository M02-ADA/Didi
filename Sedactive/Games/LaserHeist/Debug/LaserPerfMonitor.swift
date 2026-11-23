//
//  LaserPerfMonitor.swift
//  Sedactive
//

#if DEBUG
import Foundation
import QuartzCore
import RealityKit
import Synchronization
import Darwin
import os

/// DEBUG ONLY (Kevin, 22 November 2026; launch with `-perfLog`): measures a physical iPad run so
/// repeated games, co-op and Diamond Time can be compared with numbers instead of impressions.
/// Nothing here changes gameplay; without `-perfLog` every entry point returns at once.
///
/// Every `window` seconds it prints one `[LaserPerf]` line: the session number and phase, the render
/// loop's frame intervals (mean, p95, max, frames longer than `longFrame`), the app's memory footprint,
/// the scene's entity count, how many instances of each session-scoped type are alive
/// (`LaserPerfMonitor.alive`), the camera pipeline's own latency (`CameraCaptureMetrics`) and the
/// thermal state. When a round view closes it prints a `[LaserPerfSession]` summary per phase.
/// Every line also goes to `Documents/LaserPerf-<launch time>.log` in the app's container, so a run
/// survives a dropped console connection: copy it with `xcrun devicectl device copy from
/// --domain-type appDataContainer --domain-identifier com.Edward-Kristian.Sedactive --source Documents/…`.
/// Live view: `xcrun devicectl device process launch --console … -perfLog`, grep `LaserPerf`.
/// DEBUG ONLY: counts its owner in and out of `LaserPerfMonitor.alive` (a stored property of a
/// session-scoped class: `private let perfToken = PerfAliveToken("Name")`).
nonisolated final class PerfAliveToken: Sendable {
    let name: String
    init(_ name: String) {
        self.name = name
        LaserPerfMonitor.alive(name, 1)
        LaserPerfMonitor.alive(name + ".made", 1) // never decremented: how many were ever built
    }
    deinit { LaserPerfMonitor.alive(name, -1) }
}

@MainActor
final class LaserPerfMonitor {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-perfLog")
    static let shared = LaserPerfMonitor()
    /// The camera pipeline's statistics (set once by the app in DEBUG).
    static var cameraStatistics: (@Sendable () -> CameraCaptureStatistics)?

    /// The run's log file (Documents), opened by `start()`.
    private static var file: FileHandle?
    private(set) static var fileName: String?

    /// Opens this launch's log file and writes a first line (`-perfLog` only; called once at launch).
    static func start() {
        guard isEnabled, file == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "LaserPerf-\(formatter.string(from: Date())).log"
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documents.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = try? FileHandle(forWritingTo: url)
            fileName = name
        }
        emit(String(format: "[LaserPerf] logger ready · file Documents/%@ · mem %.1f MB · thermal %@ · build %@",
                     fileName ?? "(none)", footprintMB(), thermal(),
                     Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
    }

    /// Prints a line and appends it to the run's file.
    static func emit(_ line: String) {
        print(line)
        guard let file else { return }
        let stamped = String(format: "%.3f ", CACurrentMediaTime()) + line + "\n"
        try? file.write(contentsOf: Data(stamped.utf8))
    }

    static let window = 2.0
    /// A frame interval longer than this counts as a long frame (two 60 Hz frames).
    static let longFrame = 0.025

    // MARK: Live instances (any isolation)

    private static let counts = Mutex([String: Int]())

    /// Counts a session-scoped instance in (`+1`, init) or out (`-1`, deinit). Cheap; always on in DEBUG.
    nonisolated static func alive(_ type: String, _ delta: Int) {
        counts.withLock { $0[type, default: 0] += delta }
    }

    nonisolated static func aliveCounts() -> [String: Int] { counts.withLock { $0 } }

    // MARK: Frames

    private struct Stats {
        var intervals: [Double] = []
        var long = 0
        mutating func add(_ dt: Double) {
            intervals.append(dt)
            if dt > LaserPerfMonitor.longFrame { long += 1 }
        }
        var line: String {
            guard !intervals.isEmpty else { return "no frames" }
            let sorted = intervals.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            return String(format: "%d frames · dt mean %.1f p95 %.1f max %.1f ms · %.0f fps · long %d (%.1f%%)",
                          sorted.count, mean * 1000, p95 * 1000, sorted.last! * 1000, 1 / mean, long,
                          100 * Double(long) / Double(sorted.count))
        }
    }

    /// Points of Interest signposts (Instruments): phase intervals and long frames.
    private static let signposter = OSSignposter(subsystem: "com.Edward-Kristian.Sedactive", category: .pointsOfInterest)
    private var phaseInterval: OSSignpostIntervalState?
    private var session = 0
    private var phase = "setup"
    private var windowStart: Double?
    private var last: Double?
    private var windowStats = Stats()
    private var phaseStats: [String: Stats] = [:]
    private var phaseOrder: [String] = []
    private var sessionMemory: (start: Double, peak: Double)?
    private var sessionEntities: (start: Int, peak: Int)?
    private var sessionStarted: Double?

    /// A round view appeared (its scene is new).
    func sessionBegan() {
        guard Self.isEnabled else { return }
        session += 1
        phase = "setup"
        last = nil
        windowStart = nil
        windowStats = Stats()
        phaseStats = [:]
        phaseOrder = []
        let memory = Self.footprintMB()
        sessionMemory = (memory, memory)
        sessionEntities = nil
        sessionStarted = CACurrentMediaTime()
        Self.emit(String(format: "[LaserPerfSession] #%d BEGIN · mem %.1f MB · thermal %@ · alive %@", session, memory,
                     Self.thermal(), Self.aliveLine()))
    }

    /// One render tick. `phase`: what the round shows now; `scene`: counted once per window.
    func frame(now: Double, phase rawPhase: String, scene: LaserScene?) {
        guard Self.isEnabled else { return }
        let phase = rawPhase
        if phase != self.phase {
            // Instruments: one Points of Interest interval per phase.
            if let interval = phaseInterval { Self.signposter.endInterval("Phase", interval) }
            phaseInterval = Self.signposter.beginInterval("Phase", id: Self.signposter.makeSignpostID(),
                                                          "\(phase, privacy: .public)")
            self.phase = phase
            if !phaseOrder.contains(phase) { phaseOrder.append(phase) }
        }
        if let last {
            let dt = now - last
            // A gap past 1 s is a pause of the render loop (backgrounded, a modal), not a frame.
            if dt > 0, dt < 1 {
                windowStats.add(dt)
                phaseStats[phase, default: Stats()].add(dt)
                if dt > Self.longFrame {
                    Self.signposter.emitEvent("LongFrame", "\(Int(dt * 1000)) ms in \(phase, privacy: .public)")
                }
            }
        }
        last = now
        let start = windowStart ?? now
        windowStart = start
        guard now - start >= Self.window else { return }
        let memory = Self.footprintMB()
        let entities = scene.map { Self.count($0.root) }
        if var m = sessionMemory { m.peak = max(m.peak, memory); sessionMemory = m }
        if let entities {
            sessionEntities = (sessionEntities?.start ?? entities.all, max(sessionEntities?.peak ?? 0, entities.all))
        }
        let entityLine = entities.map { "entities \($0.all) (models \($0.models), shown \($0.shown))" } ?? "no scene"
        let spans = PerfSpans.drain(frames: windowStats.intervals.count)
        Self.emit(String(format: "[LaserPerf] #%d %@ · %@ · mem %.1f MB · %@ · thermal %@ · alive %@%@%@", session, phase,
                     windowStats.line, memory, entityLine, Self.thermal(), Self.aliveLine(), Self.cameraLine(),
                     spans.isEmpty ? "" : " · spans " + spans))
        windowStats = Stats()
        windowStart = now
    }

    /// The round view closed: one summary line per phase, then memory and entity totals.
    func sessionEnded() {
        guard Self.isEnabled, sessionStarted != nil else { return }
        for phase in phaseOrder {
            Self.emit("[LaserPerfSession] #\(session) \(phase): \(phaseStats[phase]?.line ?? "no frames")")
        }
        let memory = Self.footprintMB()
        let m = sessionMemory ?? (memory, memory)
        Self.emit(String(format: "[LaserPerfSession] #%d END after %.0f s · mem start %.1f peak %.1f end %.1f MB · entities start %d peak %d · thermal %@ · alive %@",
                     session, CACurrentMediaTime() - (sessionStarted ?? 0), m.start, max(m.peak, memory), memory,
                     sessionEntities?.start ?? -1, sessionEntities?.peak ?? -1, Self.thermal(), Self.aliveLine()))
        sessionStarted = nil
    }

    // MARK: Readings

    /// The app's memory footprint (what jetsam limits), MB.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func count(_ root: Entity) -> (all: Int, models: Int, shown: Int) {
        var all = 0, models = 0, shown = 0
        func walk(_ e: Entity, enabled: Bool) {
            all += 1
            let on = enabled && e.isEnabled
            if e.components.has(ModelComponent.self) { models += 1; if on { shown += 1 } }
            for child in e.children { walk(child, enabled: on) }
        }
        walk(root, enabled: true)
        return (all, models, shown)
    }

    private static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "?"
        }
    }

    private static func aliveLine() -> String {
        let counts = aliveCounts().filter { $0.value != 0 }
        return counts.isEmpty ? "-" : counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    private static func cameraLine() -> String {
        guard let stats = cameraStatistics?() else { return "" }
        func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        return " · camera \(stats.processingFPS.map { String(format: "%.1f", $0) } ?? "-") fps processed, processing p50 \(ms(stats.processing.p50MS)) p95 \(ms(stats.processing.p95MS)) ms, wait p95 \(ms(stats.wait.p95MS)) ms, capture→done p95 \(ms(stats.endToEnd.p95MS)) ms, rejects \(stats.processingRejects), pixel bytes \(stats.ownedPixelBytes / 1024) KB"
    }
}
#endif
