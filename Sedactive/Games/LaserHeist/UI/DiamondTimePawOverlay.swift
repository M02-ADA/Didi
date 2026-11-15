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
                Canvas { context, size in
                    draw(context, size: size, unit: unit, time: time, diamonds: diamonds, paws: paws)
                }
                .frame(width: unit * LaserDiamondTimeBoard.width, height: unit * LaserDiamondTimeBoard.height)
                .position(x: left + availableWidth / 2, y: top + availableHeight / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, unit: CGFloat, time: Double,
                      diamonds: [LaserDiamondState], paws: [LaserContactHand: LaserDiamondPosition]) {
        var pawPickupAges: [LaserContactHand: Double] = [:]
        var pickups: [(center: CGPoint, radius: CGFloat, age: Double, player: PlayerID)] = []
        for diamond in diamonds {
            let center = point(diamond.spawn.position, unit: unit)
            let radius = unit * LaserDiamondTimeBoard.diamondRadius
            if diamond.outcome == nil {
                drawDiamond(context, at: center, radius: radius)
            } else if case let .collected(hand, collectedAt) = diamond.outcome {
                let age = time - collectedAt
                if age >= 0, age < LaserDiamondTimeBoard.pickupEffectDuration {
                    pawPickupAges[hand] = min(pawPickupAges[hand] ?? age, age)
                    pickups.append((center, radius, age, hand.playerID))
                }
            }
        }
        for hand in LaserContactHand.ordered {
            guard let position = paws[hand] else { continue }
            drawPaw(context, at: point(position, unit: unit), radius: unit * LaserDiamondTimeBoard.pawRadius,
                    player: hand.playerID, pickupAge: pawPickupAges[hand])
        }
        for pickup in pickups {
            drawPickup(context, at: pickup.center, radius: pickup.radius, age: pickup.age, player: pickup.player, canvas: size)
        }
    }

    private func point(_ position: LaserDiamondPosition, unit: CGFloat) -> CGPoint {
        CGPoint(x: position.x * unit, y: position.y * unit)
    }

    private func drawPaw(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat, player: PlayerID, pickupAge: Double?) {
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
        let shapes = [silhouette] + toes
        let charge = pickupAge.map { pow(max(0, 1 - $0 / 0.30), 1.5) } ?? 0
        let padLit = (pickupAge ?? .infinity) < 0.12
        if !reduceMotion, charge > 0 {
            // The aura follows this paw. Its silhouette and hitbox stay fixed.
            var glow = context
            glow.addFilter(.blur(radius: radius * 0.14))
            for shape in shapes {
                glow.stroke(shape, with: .color(coat.opacity(charge * 0.95)), lineWidth: radius * 0.32)
            }
        }
        for shape in shapes {
            context.stroke(shape, with: .color(outline), lineWidth: 0.115 * radius)
        }
        for shape in shapes {
            context.fill(shape, with: .color(coat))
            if !reduceMotion, charge > 0 {
                context.fill(shape, with: .color(.white.opacity(0.40 * charge)))
            }
        }
        for (x, y) in toeCenters {
            context.fill(oval(x, y, 0.36, 0.40), with: .color(padLit ? .white : pad))
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
        context.fill(centralPad, with: .color(padLit ? .white : pad))
        context.fill(oval(-0.21, 0.07, 0.18, 0.10), with: .color(.white.opacity(0.92)))
    }

    private func drawDiamond(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat) {
        // Match the HUD flight artwork. Fit the complete image inside the target's
        // screen-space bounds and preserve its original aspect ratio during pickup.
        let diamond = context.resolve(Image("LaserHeistUI/diamond"))
        let scale = 2 * radius / max(diamond.size.width, diamond.size.height)
        let size = CGSize(width: diamond.size.width * scale, height: diamond.size.height * scale)
        let bounds = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                            width: size.width, height: size.height)
        context.draw(diamond, in: bounds)
    }

    private func drawPickup(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat, age: Double,
                            player: PlayerID, canvas: CGSize) {
        let duration = LaserDiamondTimeBoard.pickupEffectDuration
        let accent = player == .player1
            ? Color(red: 1, green: 0.83, blue: 0.28)
            : Color(red: 1, green: 0.57, blue: 0.26)
        if !reduceMotion {
            let pulse = min(1, age / 0.22)
            if pulse < 1 {
                let spread = 1 - pow(1 - pulse, 3)
                let reach = radius * (0.9 + 1.95 * spread)
                let ring = Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach,
                                                 width: 2 * reach, height: 2 * reach))
                let opacity = pow(1 - pulse, 2)
                let stroke = max(2, radius * 0.13)
                context.stroke(ring, with: .color(accent.opacity(0.88 * opacity)), lineWidth: stroke)
                context.stroke(ring, with: .color(.white.opacity(0.76 * opacity)), lineWidth: stroke * 0.32)
            }

            let popDuration = 0.08
            let collapseDuration = 0.16
            if age < popDuration + collapseDuration {
                let rise = min(1, age / popDuration)
                let fall = max(0, (age - popDuration) / collapseDuration)
                let scale = (1 + 0.30 * (1 - pow(1 - rise, 3))) * (1 - fall * fall)
                var gem = context
                gem.opacity = 1 - fall
                drawDiamond(gem, at: center, radius: radius * scale)

                // The existing 3D pickup starts with a short flash. Recreate it
                // with the same sprite so the highlight follows the gem's silhouette.
                if age < 0.10 {
                    var flash = context
                    flash.opacity = 0.55 * (1 - age / 0.10)
                    flash.addFilter(.brightness(0.7))
                    drawDiamond(flash, at: center, radius: radius * scale)
                }
            }

            let burst = min(1, age / 0.36)
            if burst < 1 {
                var fragments = context
                fragments.opacity = 1 - burst * burst
                let travel = 1 - pow(1 - burst, 3)
                let colors: [Color] = [
                    Color(red: 1, green: 0.86, blue: 0.32),
                    Color(red: 0.38, green: 0.95, blue: 1),
                    Color(red: 1, green: 0.55, blue: 0.84),
                    Color(red: 0.78, green: 0.70, blue: 1)
                ]
                for index in 0..<12 {
                    let star = index.isMultiple(of: 3)
                    let angle = Double(index) * .pi / 6 + .pi / 12
                    let size = radius * (star ? 1.52 : 1.08) * (1 - 0.36 * burst)
                    let spread = radius * (0.90 + (star ? 2.65 : 2.15) * travel)
                    let dx = cos(angle), dy = sin(angle)
                    // Shorten outward travel near an edge so the stars stay on the board.
                    let padding = size * 0.65
                    let edgeX = dx > 0 ? canvas.width - padding - center.x : center.x - padding
                    let edgeY = dy > 0 ? canvas.height - padding - center.y : center.y - padding
                    let distance = max(0, min(spread, edgeX / abs(dx), edgeY / abs(dy)))
                    let position = CGPoint(x: center.x + dx * distance, y: center.y + dy * distance)
                    let color = colors[(index / 3 + index % 3) % colors.count]
                    if !star {
                        let tail = min(distance, size * (1 - burst))
                        let streak = Path { path in
                            path.move(to: CGPoint(x: position.x - dx * tail, y: position.y - dy * tail))
                            path.addLine(to: position)
                        }
                        fragments.stroke(streak, with: .color(color.opacity(0.48)),
                                         style: StrokeStyle(lineWidth: max(1, size * 0.10), lineCap: .round))
                    }
                    if star {
                        fragments.draw(Text(Image(systemName: "sparkle"))
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(color), at: position)
                    } else {
                        let x = position.x, y = position.y
                        let shard = Path { path in
                            path.move(to: CGPoint(x: x + dx * size * 0.62, y: y + dy * size * 0.62))
                            path.addLines([
                                CGPoint(x: x - dy * size * 0.30, y: y + dx * size * 0.30),
                                CGPoint(x: x - dx * size * 0.48, y: y - dy * size * 0.48),
                                CGPoint(x: x + dy * size * 0.30, y: y - dx * size * 0.30)
                            ])
                            path.closeSubpath()
                        }
                        fragments.fill(shard, with: .color(color))
                        fragments.stroke(shard, with: .color(.white.opacity(0.75)), lineWidth: 1)
                    }
                }
            }
        }

        let fade = max(0, (age - 0.27) / (duration - 0.27))
        let lift = reduceMotion ? 0 : 0.55 * min(1, age / 0.23)
        var confirmation = context
        confirmation.opacity = 1 - fade
        let label = confirmation.resolve(Text("+25")
            .font(.system(size: max(28, radius * 1.62), weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 1, green: 0.96, blue: 0.62)))
        let labelSize = label.measure(in: CGSize(width: canvas.width, height: canvas.height))
        let badgeSize = CGSize(width: labelSize.width + 24, height: labelSize.height + 10)
        let settle = min(1, age / 0.16)
        let bounce = reduceMotion ? 1 : 1 + 0.18 * sin(.pi * settle)
        let halfWidth = badgeSize.width * bounce / 2 + 2
        let halfHeight = badgeSize.height * bounce / 2 + 2
        let x = min(canvas.width - halfWidth, max(halfWidth, center.x))
        let y = max(halfHeight, center.y - radius * (1.50 + lift))
        confirmation.translateBy(x: x, y: y)
        confirmation.scaleBy(x: bounce, y: bounce)
        let background = CGRect(x: -badgeSize.width / 2, y: -badgeSize.height / 2,
                                width: badgeSize.width, height: badgeSize.height)
        let badge = Path(roundedRect: background, cornerRadius: background.height / 2)
        confirmation.fill(badge, with: .linearGradient(
            Gradient(colors: [Color(red: 0.25, green: 0.16, blue: 0.66), Color(red: 0.65, green: 0.10, blue: 0.47)]),
            startPoint: CGPoint(x: background.minX, y: background.minY),
            endPoint: CGPoint(x: background.maxX, y: background.maxY)))
        confirmation.stroke(badge, with: .color(accent), lineWidth: 2)
        confirmation.draw(label, at: .zero)
    }
}
