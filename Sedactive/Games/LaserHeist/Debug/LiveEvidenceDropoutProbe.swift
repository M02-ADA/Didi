#if DEBUG
import Foundation

/// DEBUG `[LaserDropout]` (iPad co-op, 13 November 2026): how long each player's live evidence is
/// unusable by the readiness gate's own rule (`LiveEvidenceAttention`), one line per dropout when it
/// ends: player, frames, capture-time duration, what was missing, and the session phase. The data
/// for deciding any running grace with Jevon (PR #46 pauses on the first unusable frame), measured
/// rather than guessed. Sampled once per rendered frame from the session's latest packet, so two
/// packets inside one display frame count as one. Observation only.
///
/// It also logs the moment the tracker demands a re-bind for a player (identity latched), with how
/// long every roster player had been unusable then (iPad, 13 November 2026: a squat that hid one
/// player's hips for more than about 0.8 s latched the OTHER player and forced recalibration).
struct LiveEvidenceDropoutProbe {
    private var lastFrame: UInt64?
    private var runs: [PlayerID: (start: Double, frames: Int, missing: Set<String>)] = [:]
    private var rebind: Set<PlayerID> = []

    mutating func observe(_ packet: BodySnapshot?, roster: [PlayerID], phase: String) -> [String] {
        guard let packet, packet.frameID != lastFrame else { return [] }
        lastFrame = packet.frameID
        var lines: [String] = []
        for player in roster {
            if let need = LiveEvidenceAttention.of(packet.players[player]) {
                var run = runs[player] ?? (packet.capturedAt, 0, [])
                run.frames += 1
                // With the producer's reason (e.g. hands(lowConfidence) vs hands(missingLandmarks)):
                // whether real occlusions are reported differently from a hand out of frame.
                run.missing.insert(Self.detail(need, packet.players[player]))
                runs[player] = run
            } else if let run = runs.removeValue(forKey: player) {
                lines.append(String(format: "[LaserDropout] %@ unusable %d frame%@ · %.3f s · missing %@ · during %@",
                                    player.rawValue, run.frames, run.frames == 1 ? "" : "s", packet.capturedAt - run.start,
                                    run.missing.sorted().joined(separator: "+"), phase))
            }
        }
        for player in roster {
            let required = packet.wristContact?.players[player]?.requiresRebind == true
            if required, rebind.insert(player).inserted {
                let unusable = roster.map { other in
                    let run = runs[other].map { String(format: "%.3f s (%@)", packet.capturedAt - $0.start,
                                                       $0.missing.sorted().joined(separator: "+")) } ?? "usable"
                    return "\(other.rawValue) \(run)"
                }.joined(separator: ", ")
                lines.append("[LaserDropout] \(player.rawValue) re-bind required (identity latched) · unusable then: \(unusable) · during \(phase)")
            } else if !required {
                rebind.remove(player)
            }
        }
        return lines
    }

    private static func detail(_ need: LiveEvidenceAttention, _ sample: PlayerBodySample?) -> String {
        guard let g = sample?.geometry else { return need.rawValue }
        let fields: [EstimatedScalar] = switch need {
        case .tracking: []
        case .head: [g.crownY]
        case .hands: [g.leftWristY, g.rightWristY]
        case .feet: [g.leftSoleY, g.rightSoleY]
        }
        let reasons = Set(fields.map(\.validity).filter { $0 != .valid }.map(\.rawValue)).sorted()
        return reasons.isEmpty ? need.rawValue : "\(need.rawValue)(\(reasons.joined(separator: ",")))"
    }
}
#endif
