//
//  LaserHitReactionPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of the laser HIT reaction without a camera or a round:
/// `-replay -hitReactionPreview [p1|p2|both] [high|low] [clear|unavailable] [reduce] [repeat] [seconds|pre]`.
/// The mascots stand in their lanes (rest pose, no body data) with the shared beam at their
/// plane; every 1.8 s the chosen players get the chosen verdict through the scene's own
/// `presentOutcome` (the production path). `repeat` sends a second HIT 0.3 s later (a restart,
/// never a stack); `reduce` previews Reduce Motion; `seconds` holds the reaction at that time
/// (screenshots). Presentation review only: no session, verdict or game time.
@MainActor
final class LaserHitReactionPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-hitReactionPreview") }

    struct Request {
        var players: [PlayerID] = PlayerID.allCases
        var high = true
        var outcome = LaserFeedback.Outcome.hit
        var reduceMotion = false
        var repeats = false
        var heldAt: Double?
    }

    static var requested: Request {
        let arguments = ProcessInfo.processInfo.arguments
        var request = Request()
        guard let index = arguments.firstIndex(of: "-hitReactionPreview") else { return request }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        if rest.contains("p1") { request.players = [.player1] }
        if rest.contains("p2") { request.players = [.player2] }
        request.high = !rest.contains("low")
        if rest.contains("clear") { request.outcome = .clear }
        if rest.contains("unavailable") { request.outcome = .unavailable }
        request.reduceMotion = rest.contains("reduce")
        request.repeats = rest.contains("repeat")
        request.heldAt = rest.compactMap(Double.init).first
        if rest.contains("pre") { request.heldAt = -1 }
        return request
    }

    static let period = 1.8
    private var subscription: EventSubscription?
    private var now = 0.0

    func start(on content: RealityViewCameraContent, scene: LaserScene, robots: RobotAvatarLayer, request: Request) {
        RobotAvatarLayer.forcesReducedMotionForHits = request.reduceMotion
        robots.smoothing = 0.03
        // The preview bands of `LaserApproachPreview`: a high beam (missed DUCK), a low one (missed JUMP).
        let band: ClosedRange<Float> = request.high ? 1.239...1.261 : 0.249...0.271
        scene.setLaserBand(lowerEdge: band.lowerBound, upperEdge: band.upperBound)
        scene.setLaserDepth(scene.mapping.interactionPlaneZ)
        scene.setLaserDangerSide(request.high ? .above : .below)
        scene.setLaserVisualState(.active)
        scene.isLaserVisible = true
        func strike() { for player in request.players { scene.presentOutcome(request.outcome, for: player) } }
        robots.render(now: 0)
        if let heldAt = request.heldAt {
            // Settle the rest pose, strike, then show the reaction at exactly `heldAt`.
            robots.render(now: 0.5)
            guard heldAt >= 0 else { return } // `pre`: the moment before the beam strikes
            strike()
            robots.render(now: 1)
            if request.repeats, heldAt > 0.3 {
                robots.render(now: 1.3)
                strike()
                robots.render(now: 1.3 + 0.0001)
                robots.render(now: 1.3 + (heldAt - 0.3))
            } else {
                robots.render(now: 1 + heldAt)
            }
            return
        }
        var sinceStrike = Self.period
        var repeated = true
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            now += event.deltaTime
            sinceStrike += event.deltaTime
            if sinceStrike >= Self.period {
                sinceStrike = 0
                repeated = !request.repeats
                strike()
            } else if !repeated, sinceStrike >= 0.3 {
                repeated = true
                strike()
            }
            robots.render(now: now)
        }
    }
}
#endif
