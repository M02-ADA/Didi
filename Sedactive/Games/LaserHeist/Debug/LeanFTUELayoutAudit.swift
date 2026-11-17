#if DEBUG
import RealityKit
import Foundation
import CoreGraphics

/// A DEBUG launch flag is consumed once per process, never once per Retry generation.
@MainActor enum LeanFTUEPreviewLaunch {
    private static var resetConsumed = false
    static func applyReset(to tutorial: LeanTutorial) {
        guard !resetConsumed else { return }
        resetConsumed = true
        if ProcessInfo.processInfo.arguments.contains("-leanFTUEReset") { tutorial.resetForNextPlay() }
    }
}

/// On-demand, synthetic layout review ONLY. Reuses the allowed steering bounds/separation and
/// actual RealityView projection. No per-frame layout work or production avatar writes.
@MainActor enum LeanFTUELayoutAudit {
    static func inspect(scene: LaserScene, solo: Bool, index: Int, origin: CGPoint,
                        project: (SIMD3<Float>) -> CGPoint?) -> String {
        guard let robots = scene.robotAvatars, let steering = robots.steering else { return "unavailable" }
        let bounds = steering.bounds, gap = steering.minimumSeparation
        let p1 = index == 1 ? bounds.lowerBound : index == 2 ? (solo ? bounds.upperBound : bounds.upperBound - gap)
            : scene.mapping.laneCenterX[.player1, default: -0.7]
        let p2 = index == 1 ? bounds.lowerBound + gap : index == 2 ? bounds.upperBound
            : scene.mapping.laneCenterX[.player2, default: 0.7]
        var results: [[String: Any]] = []
        for (player, x) in [(PlayerID.player1, p1), (.player2, p2)] where !solo || player == .player1 {
            guard let entity = scene.players[player], let robot = robots.robots[player] else { continue }
            entity.position.x = x - robot.container.position.x
            let b = entity.visualBounds(relativeTo: nil)
            var rect = CGRect.null
            for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] { for z in [b.min.z, b.max.z] {
                guard let p = project(SIMD3(x,y,z)), p.x.isFinite, p.y.isFinite else { continue }
                rect = rect.union(CGRect(x: p.x + origin.x, y: p.y + origin.y, width: 0.01, height: 0.01))
            } } }
            if !rect.isNull {
                results.append(["player": player.rawValue, "x": rect.minX, "y": rect.minY,
                                "width": rect.width, "height": rect.height])
            }
        }
        let report: [String: Any] = ["layout": index, "solo": solo, "avatars": results]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "unavailable" }
        return text
    }
}
#endif
