import SwiftUI
import RealityKit

/// The existing HUD's central row ends at 58 + 65 = 123 artboard points.
/// Place the cue in the measured space BETWEEN that row and the projected standing heads.
nonisolated struct LeanCuePlacement: Equatable {
    let frame: CGRect
    let scale: CGFloat
    static func make(viewport: CGSize, headTopFraction: CGFloat?) -> Self? {
        guard viewport.width > 0, viewport.height > 0, let headTopFraction,
              headTopFraction.isFinite, headTopFraction > 0, headTopFraction < 1 else { return nil }
        let k = min(viewport.width / 1210, viewport.height / 834)
        let hudBottom = 123 * k
        let headTop = headTopFraction * viewport.height
        let scale = min(k, (headTop - hudBottom - 24) / 128)
        guard scale > 0 else { return nil }
        let size = CGSize(width: 900 * scale, height: 128 * scale)
        return Self(frame: CGRect(x: (viewport.width - size.width) / 2,
            y: (hudBottom + headTop - size.height) / 2, width: size.width, height: size.height), scale: scale)
    }
}

/// Two cached pieces of instruction artwork, matching LaserFeedback.cueArt's rounded-black
/// font, white face, SF arrow and hard/soft shadows. No per-frame image/material generation.
@MainActor enum LeanInstructionArtwork {
    static let left = make(right: false)
    static let right = make(right: true)
    private static func make(right: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 900, height: 128), format: format).image { context in
            let cg = context.cgContext
            let system = UIFont.systemFont(ofSize: 72, weight: .black)
            let font = system.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 72) } ?? system
            let label = NSAttributedString(string: right ? "LEAN RIGHT" : "LEAN LEFT", attributes: [
                .font: font, .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black, .strokeWidth: -3.0])
            let arrow = UIImage(systemName: right ? "arrow.right" : "arrow.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 72 * 0.86, weight: .black))!
            let textSize = label.size(), symbolSize = arrow.size, gap: CGFloat = 8
            let start = (900 - textSize.width - symbolSize.width - gap) / 2
            let symbolX = right ? start + textSize.width + gap : start
            let textX = right ? start : start + symbolSize.width + gap
            let rect = CGRect(x: symbolX, y: (128 - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height)
            func draw() {
                for dx in [-2.0, 0, 2] { for dy in [-2.0, 0, 2] where dx != 0 || dy != 0 {
                    arrow.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: rect.offsetBy(dx: dx, dy: dy))
                } }
                arrow.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
                label.draw(at: CGPoint(x: textX, y: (128 - textSize.height) / 2))
            }
            cg.saveGState(); cg.setShadow(offset: CGSize(width: 0, height: 4), blur: 8,
                color: UIColor.black.withAlphaComponent(0.25).cgColor); draw(); cg.restoreGState()
            cg.saveGState(); cg.setShadow(offset: CGSize(width: 3, height: 5), blur: 0,
                color: UIColor.black.withAlphaComponent(0.91).cgColor); draw(); cg.restoreGState()
            draw()
        }
    }
}

/// A bounded projection on initial scene readiness / viewport change, not a layout solver.
/// Translate bounding-box corners mathematically to existing steering extremes; never move avatars.
@MainActor enum LeanCueProjection {
    static func headTop(scene: LaserScene, viewport: CGSize,
                        project: (SIMD3<Float>) -> CGPoint?) -> CGFloat? {
        guard viewport.height > 0, let robots = scene.robotAvatars, let steering = robots.steering,
              robots.robots.keys.allSatisfy({
                  robots.trackedRootPosition($0) != nil && (robots.steeringReading($0)?.frameDT ?? 0) > 0
              }) else { return nil }
        var top: CGFloat?
        for player in robots.robots.keys {
            guard let entity = scene.players[player], let currentX = robots.mascotWorldX(player) else { continue }
            let b = entity.visualBounds(relativeTo: nil)
            for destination in [steering.bounds.lowerBound, steering.bounds.upperBound] {
                let shift = destination - currentX
                for x in [b.min.x, b.max.x] { for z in [b.min.z, b.max.z] {
                    if let p = project(SIMD3(x + shift, b.max.y, z)), p.y.isFinite {
                        top = min(top ?? p.y, p.y)
                    }
                } }
            }
        }
        return top.map { $0 / viewport.height }
    }
}
