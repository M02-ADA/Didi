import SwiftUI

/// One flat playfield for the session's paw positions, targets, and confirmed pickups.
struct DiamondTimePawOverlay: View {
    let session: GameSessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let time = session.state?.gameTime ?? 0
        let paws = session.diamondTimePaws
        let diamonds = session.diamondStates.values.filter {
            if case .diamondTime = $0.lifetime { true } else { false }
        }.sorted { $0.spawn.id.uuidString < $1.spawn.id.uuidString }
        GeometryReader { proxy in
            let hudScale = min(proxy.size.width / 1210, proxy.size.height / 834)
            let top = max(proxy.safeAreaInsets.top, 258 * hudScale)
            let bottom = max(proxy.safeAreaInsets.bottom, 24)
            let left = max(proxy.safeAreaInsets.leading, 16)
            let right = max(proxy.safeAreaInsets.trailing, 16)
            let availableWidth = max(0, proxy.size.width - left - right)
            let availableHeight = max(0, proxy.size.height - top - bottom)
            let unit = min(availableWidth / LaserDiamondTimeBoard.width, availableHeight / LaserDiamondTimeBoard.height)
            if unit > 0 {
                Canvas { context, _ in
                    draw(context, unit: unit, time: time, diamonds: diamonds, paws: paws)
                }
                .frame(width: unit * LaserDiamondTimeBoard.width, height: unit * LaserDiamondTimeBoard.height)
                .position(x: left + availableWidth / 2, y: top + availableHeight / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, unit: CGFloat, time: Double,
                      diamonds: [LaserDiamondState], paws: [LaserContactHand: LaserDiamondPosition]) {
        var reacting: Set<LaserContactHand> = []
        var pickups: [(center: CGPoint, radius: CGFloat, age: Double)] = []
        for diamond in diamonds {
            let center = point(diamond.spawn.position, unit: unit)
            let radius = unit * LaserDiamondTimeBoard.diamondRadius
            if diamond.outcome == nil {
                drawDiamond(context, at: center, radius: radius)
            } else if case let .collected(hand, collectedAt) = diamond.outcome {
                let age = time - collectedAt
                if age >= 0, age < LaserDiamondTimeBoard.pickupEffectDuration {
                    if age < 0.12 { reacting.insert(hand) }
                    pickups.append((center, radius, age))
                }
            }
        }
        for hand in LaserContactHand.ordered {
            guard let position = paws[hand] else { continue }
            drawPaw(context, at: point(position, unit: unit), radius: unit * LaserDiamondTimeBoard.pawRadius,
                    player: hand.playerID, reacting: reacting.contains(hand))
        }
        for pickup in pickups {
            drawPickup(context, at: pickup.center, radius: pickup.radius, age: pickup.age)
        }
    }

    private func point(_ position: LaserDiamondPosition, unit: CGFloat) -> CGPoint {
        CGPoint(x: position.x * unit, y: position.y * unit)
    }

    private func drawPaw(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat, player: PlayerID, reacting: Bool) {
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x + (x - w / 2) * radius, y: center.y + (y - h / 2) * radius,
                                   width: w * radius, height: h * radius))
        }
        let outline = Color(red: 0.29, green: 0.12, blue: 0.10)
        let coat = player == .player1 ? Color(red: 1, green: 0.75, blue: 0.11) : Color(red: 1, green: 0.46, blue: 0.10)
        let pad = Color(red: 1, green: 0.85, blue: 0.73)
        let toeCenters: [(CGFloat, CGFloat)] = [(-0.62, -0.25), (-0.27, -0.60), (0.27, -0.60), (0.62, -0.25)]
        let silhouette = oval(0, 0.22, 1.56, 1.43)
        let toes = toeCenters.map { oval($0.0, $0.1, 0.66, 0.68) }
        for shape in [silhouette] + toes {
            context.stroke(shape, with: .color(outline), lineWidth: 0.115 * radius)
        }
        for shape in [silhouette] + toes {
            context.fill(shape, with: .color(coat))
        }
        for (x, y) in toeCenters {
            context.fill(oval(x, y, 0.36, 0.40), with: .color(pad))
        }
        let centralPad = Path { path in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center.x + radius * x, y: center.y + radius * y)
            }
            path.move(to: p(0, -0.19))
            path.addCurve(to: p(0.49, 0.39), control1: p(0.28, -0.19), control2: p(0.49, 0.12))
            path.addQuadCurve(to: p(0, 0.61), control: p(0.5, 0.69))
            path.addQuadCurve(to: p(-0.49, 0.39), control: p(-0.5, 0.69))
            path.addCurve(to: p(0, -0.19), control1: p(-0.49, 0.12), control2: p(-0.28, -0.19))
            path.closeSubpath()
        }
        context.fill(centralPad, with: .color(reacting ? .white : pad))
        context.fill(oval(-0.21, 0.07, 0.18, 0.10), with: .color(.white.opacity(0.92)))
    }

    private func drawDiamond(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x * radius, y: center.y + y * radius)
        }
        let shape = Path { path in
            path.move(to: point(-0.60, -0.68))
            path.addLines([point(0.60, -0.68), point(0.95, -0.15), point(0, 0.94), point(-0.95, -0.15)])
            path.closeSubpath()
        }
        context.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(red: 0.43, green: 0.94, blue: 1), Color(red: 0.05, green: 0.45, blue: 0.91)]),
            startPoint: point(0, -0.68), endPoint: point(0, 0.94)))
        context.stroke(shape, with: .color(Color(red: 0.05, green: 0.21, blue: 0.49)), lineWidth: radius * 0.22)
        context.stroke(shape, with: .color(.white.opacity(0.88)), lineWidth: radius * 0.08)
        let facets = Path { path in
            path.move(to: point(-0.95, -0.15))
            path.addLine(to: point(0.95, -0.15))
            path.move(to: point(-0.60, -0.68))
            path.addLines([point(-0.36, -0.15), point(0, 0.94), point(0.36, -0.15), point(0.60, -0.68)])
        }
        context.stroke(facets, with: .color(.white.opacity(0.68)), lineWidth: radius * 0.052)
    }

    private func drawPickup(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat, age: Double) {
        let progress = age / LaserDiamondTimeBoard.pickupEffectDuration
        var effect = context
        effect.opacity = 1 - progress
        if !reduceMotion {
            if age < 0.14 { drawDiamond(effect, at: center, radius: radius * (1 + progress)) }
            for index in 0..<4 {
                let angle = Double(index) * .pi / 2 + .pi / 4
                let spread = radius * (0.8 + 1.1 * progress)
                let spark = CGPoint(x: center.x + cos(angle) * spread, y: center.y + sin(angle) * spread)
                effect.draw(Text(Image(systemName: "sparkle")).font(.system(size: radius * 0.65))
                    .foregroundStyle(.yellow), at: spark)
            }
        }
        effect.draw(Text("+25").font(.system(size: max(15, radius * 0.90), weight: .black, design: .rounded))
            .foregroundStyle(.white), at: CGPoint(x: center.x, y: center.y - radius * (1.0 + (reduceMotion ? 0 : progress))))
    }
}
