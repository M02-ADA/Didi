import Foundation

/// What one player must fix for the live round to admit their evidence, read from the latest CP1
/// packet with the live readiness gate's own rule (`LaserLiveReadiness.observe`: reliable tracking,
/// then a valid crown, both wrists, both soles and jump state). Presentation only: it names which
/// player needs attention and what to show (iPad co-op, 13 November 2026: with both chips on
/// "Ready", a round waiting for one player's feet looked frozen). It never admits, blocks or
/// judges anything.
nonisolated enum LiveEvidenceAttention: String, Equatable, Sendable {
    case tracking, head, hands, feet

    /// Nil when this player's packet would be admitted.
    static func of(_ sample: PlayerBodySample?) -> LiveEvidenceAttention? {
        guard let sample, sample.trackingStatus == .reliable else { return .tracking }
        let g = sample.geometry
        if g.crownY.validity != .valid { return .head }
        if g.leftWristY.validity != .valid || g.rightWristY.validity != .valid { return .hands }
        if g.leftSoleY.validity != .valid || g.rightSoleY.validity != .valid || sample.jumpState.validity != .valid {
            return .feet
        }
        return nil
    }

    /// Each roster player who needs attention in `packet`; empty without a packet (nothing known).
    static func players(_ packet: BodySnapshot?, roster: [PlayerID]) -> [PlayerID: LiveEvidenceAttention] {
        guard let packet else { return [:] }
        return Dictionary(uniqueKeysWithValues: roster.compactMap { player in of(packet.players[player]).map { (player, $0) } })
    }

    /// "P2: keep both feet in view." for each player, P1 first; nil when nobody needs attention.
    static func line(_ attention: [PlayerID: LiveEvidenceAttention], solo: Bool) -> String? {
        let parts = PlayerID.allCases.compactMap { player -> String? in
            guard let need = attention[player] else { return nil }
            let what: String = switch need {
            case .tracking: solo ? "stay in the middle" : "stay in your place"
            case .head: "keep your head in view"
            case .hands: "keep your hands in view"
            case .feet: "keep both feet in view"
            }
            return solo ? what.prefix(1).uppercased() + what.dropFirst() + "." : "\(player == .player1 ? "P1" : "P2"): \(what)."
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
