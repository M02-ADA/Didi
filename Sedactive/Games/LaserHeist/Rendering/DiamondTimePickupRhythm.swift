import Foundation

/// Presentation grouping over confirmed pickup outcomes. The GameClock
/// timestamps drive grouping and decay, including during pause.
nonisolated enum DiamondTimePickupRhythm {
    static let chainWindow = 0.7
    static let accentWindow = 0.10
    static let shakeDuration = 0.24

    struct Beat {
        let start: Double
        var lastPickup: Double
        var ids: [UUID]
        var level: Int
    }

    static func beats(in states: [UUID: LaserDiamondState]) -> [Beat] {
        let pickups: [(id: UUID, time: Double)] = states.values.compactMap { state in
            guard case .diamondTime = state.lifetime,
                  case .collected(_, let time) = state.outcome else { return nil }
            return (state.spawn.id, time)
        }.sorted { $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time }

        var beats: [Beat] = []
        for pickup in pickups {
            if let last = beats.last, pickup.time - last.start < accentWindow {
                beats[beats.count - 1].lastPickup = pickup.time
                beats[beats.count - 1].ids.append(pickup.id)
                beats[beats.count - 1].level = min(last.level + 1, 5)
            } else {
                let carry = beats.last.flatMap { pickup.time - $0.lastPickup <= chainWindow ? $0.level : nil } ?? 0
                beats.append(Beat(start: pickup.time, lastPickup: pickup.time, ids: [pickup.id], level: min(carry + 1, 5)))
            }
        }
        return beats
    }

    static func shake(age: Double, level: Int) -> Float {
        guard level >= 1, age >= 0, age < shakeDuration else { return 0 }
        let progress = age / shakeDuration
        let amplitude: Float = if level >= 5 { 0.019 } else if level >= 3 { 0.016 } else { 0.010 }
        return Float(cos(progress * 3 * .pi) * pow(1 - progress, 2)) * amplitude
    }
}
