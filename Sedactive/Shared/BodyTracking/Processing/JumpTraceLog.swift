//
//  JumpTraceLog.swift
//  Sedactive
//

#if DEBUG
import Foundation

/// DEBUG ONLY (Kevin, 21 November 2026 — Edo-owned area, for his review): a rolling per-player trace
/// of the jump estimator's input and decisions, to diagnose jumps the iPad rejects (a butt-kick jump:
/// heels to the buttocks). `BodyInputService` adds one line per frame; when the game judges a jump
/// laser, `GameSessionCoordinator` prints that player's last `capacity` lines as `[LaserJumpTrace]`
/// (grep the device console for it). Nothing here is read by gameplay.
///
/// Each line: capture host time, frame, the raw Vision hips / knees / ankles (image y, 0 = top,
/// with confidence; "--" when Vision gave none), the soles and hips in game units (as the estimator
/// gets them; "x" = not valid this frame), the lift, take-off line, phase and the estimator's reason.
nonisolated enum JumpTraceLog {
    /// About 4 s at 30 fps.
    static let capacity = 120
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [PlayerID: [(time: Double, text: String)]] = [:]

    static func add(_ player: PlayerID, time: Double, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        var trace = lines[player] ?? []
        trace.append((time, text))
        if trace.count > capacity { trace.removeFirst(trace.count - capacity) }
        lines[player] = trace
    }

    /// The player's buffered lines (oldest first).
    static func lines(for player: PlayerID) -> [(time: Double, text: String)] {
        lock.lock(); defer { lock.unlock() }
        return lines[player] ?? []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        lines = [:]
    }

    /// One joint as "y/conf" (image y, 2 decimals; confidence, 2 decimals) or "--".
    static func joint(_ j: PoseJoint?) -> String {
        j.map { String(format: "%.3f/%.2f", $0.y, $0.confidence) } ?? "--"
    }
}
#endif
