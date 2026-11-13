#if DEBUG
import Foundation

/// DEBUG `[LaserDropout]` (iPad co-op, 13 November 2026): how long each player's live evidence is
/// unusable by the readiness gate's own rule (`LiveEvidenceAttention`), one line per dropout when it
/// ends: player, frames, capture-time duration, what was missing, and the session phase. The data
/// for deciding any running grace with Jevon (PR #46 pauses on the first unusable frame), measured
/// rather than guessed. Sampled once per rendered frame from the session's latest packet, so two
/// packets inside one display frame count as one. Observation only.
struct LiveEvidenceDropoutProbe {
    private var lastFrame: UInt64?
    private var runs: [PlayerID: (start: Double, frames: Int, missing: Set<String>)] = [:]

    mutating func observe(_ packet: BodySnapshot?, roster: [PlayerID], phase: String) -> [String] {
        guard let packet, packet.frameID != lastFrame else { return [] }
        lastFrame = packet.frameID
        var lines: [String] = []
        for player in roster {
            if let need = LiveEvidenceAttention.of(packet.players[player]) {
                var run = runs[player] ?? (packet.capturedAt, 0, [])
                run.frames += 1
                run.missing.insert(need.rawValue)
                runs[player] = run
            } else if let run = runs.removeValue(forKey: player) {
                lines.append(String(format: "[LaserDropout] %@ unusable %d frame%@ · %.3f s · missing %@ · during %@",
                                    player.rawValue, run.frames, run.frames == 1 ? "" : "s", packet.capturedAt - run.start,
                                    run.missing.sorted().joined(separator: "+"), phase))
            }
        }
        return lines
    }
}
#endif
