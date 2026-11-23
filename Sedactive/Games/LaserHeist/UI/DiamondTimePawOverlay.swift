import SwiftUI

/// One flat playfield for the session's paw positions, targets, and confirmed pickups.
struct DiamondTimePawOverlay: View {
    let session: GameSessionCoordinator
    let presentation: PawBoardDiamondPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let time = session.state?.gameTime ?? 0
        let paws = session.diamondTimePaws
        let renderedIDs = presentation.renderedIDs
        let pickupLevels = presentation.pickupLevels
        let latestCrestID = presentation.latestCrestID
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
                    PerfSpans.measure("pawCanvas") {
                        draw(context, size: size, unit: unit, time: time, diamonds: diamonds, paws: paws, renderedIDs: renderedIDs,
                             pickupLevels: pickupLevels, latestCrestID: latestCrestID)
                    }
                }
                .frame(width: unit * LaserDiamondTimeBoard.width, height: unit * LaserDiamondTimeBoard.height)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: { presentation.boardFrame = $0 }
                .position(x: left + availableWidth / 2, y: top + availableHeight / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, unit: CGFloat, time: Double,
                      diamonds: [LaserDiamondState], paws: [LaserContactHand: LaserDiamondPosition], renderedIDs: Set<UUID>,
                      pickupLevels: [UUID: Int], latestCrestID: UUID?) {
        var pawPickups: [LaserContactHand: (age: Double, level: Int)] = [:]
        var pickups: [(center: CGPoint, radius: CGFloat, age: Double, player: PlayerID,
                       renderInCanvas: Bool, level: Int, crest: Bool)] = []
        for diamond in diamonds {
            let center = point(diamond.spawn.position, unit: unit)
            let radius = unit * LaserDiamondTimeBoard.diamondRadius
            if diamond.outcome == nil {
                if !renderedIDs.contains(diamond.spawn.id) { drawDiamond(context, at: center, radius: radius) }
            } else if case let .collected(hand, collectedAt) = diamond.outcome {
                let age = time - collectedAt
                if age >= 0, age < LaserDiamondTimeBoard.pickupEffectDuration {
                    let id = diamond.spawn.id
                    let level = pickupLevels[id] ?? 1
                    if age < (pawPickups[hand]?.age ?? .infinity) { pawPickups[hand] = (age, level) }
                    pickups.append((center, radius, age, hand.playerID, !renderedIDs.contains(id),
                                    level, id == latestCrestID))
                }
            }
        }
        for hand in LaserContactHand.ordered {
            guard let position = paws[hand] else { continue }
            drawPaw(context, at: point(position, unit: unit), radius: unit * LaserDiamondTimeBoard.pawRadius,
                    hand: hand, pickup: pawPickups[hand])
        }
        for pickup in pickups {
            if pickup.crest, !reduceMotion {
                drawChainAccent(context, at: pickup.center, radius: pickup.radius, age: pickup.age,
                                player: pickup.player, level: pickup.level)
            }
            drawPickup(context, at: pickup.center, radius: pickup.radius, age: pickup.age, player: pickup.player, canvas: size, renderInCanvas: pickup.renderInCanvas)
        }
    }

    private func point(_ position: LaserDiamondPosition, unit: CGFloat) -> CGPoint {
        CGPoint(x: position.x * unit, y: position.y * unit)
    }

    private func drawPaw(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat,
                         hand: LaserContactHand, pickup: (age: Double, level: Int)?) {
        let yellow = hand.playerID == .player1
        let color = yellow ? "yellow" : "orange"
        let side = hand.wrist == .left ? "left" : "right"
        let sprite = context.resolve(Image("LaserHeistUI/paw-\(color)-\(side)"))
        let scale = 2 * radius / max(sprite.size.width, sprite.size.height)
        let size = CGSize(width: sprite.size.width * scale, height: sprite.size.height * scale)
        let bounds = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                            width: size.width, height: size.height)
        let duration = reduceMotion ? 0.12 : 0.30 + 0.025 * Double((pickup?.level ?? 1) - 1)
        guard let pickup, pickup.age < duration else {
            context.draw(sprite, in: bounds)
            return
        }

        let strength = reduceMotion ? 1 : pow(max(0, 1 - pickup.age / duration), 1.5)
        let intensity = reduceMotion ? 1 : 1 + 0.17 * Double(pickup.level - 1)
        let glow = yellow ? Color(red: 1, green: 0.77, blue: 0.21) : Color(red: 1, green: 0.50, blue: 0.18)
        context.drawLayer { highlight in
            if !reduceMotion {
                highlight.addFilter(.shadow(color: glow.opacity(0.95 * strength), radius: radius * 0.24 * intensity))
            }
            highlight.addFilter(.brightness(0.25 * strength * intensity))
            highlight.draw(sprite, in: bounds)
        }
    }

    private func drawChainAccent(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat,
                                 age: Double, player: PlayerID, level: Int) {
        guard age < 0.28 else { return }
        let progress = age / 0.28
        let spread = 1 - pow(1 - progress, 3)
        let reach = radius * ((level >= 5 ? 3.6 : 3.0) * spread + 0.85)
        let accent: Color = player == .player1 ? .yellow : .orange
        var burst = context
        burst.opacity = pow(1 - progress, 2) * 0.82
        let ring = Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach,
                                         width: 2 * reach, height: 2 * reach))
        burst.stroke(ring, with: .color(accent), lineWidth: max(2, radius * 0.15))
        for index in 0..<6 {
            let angle = Double(index) * .pi / 3 + .pi / 6
            let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
            burst.draw(Text(Image(systemName: "sparkle")).font(.system(size: radius * 0.76, weight: .bold))
                .foregroundStyle(index.isMultiple(of: 2) ? .white : accent), at: point)
        }
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
                            player: PlayerID, canvas: CGSize, renderInCanvas: Bool) {
        let duration = LaserDiamondTimeBoard.pickupEffectDuration
        let accent = player == .player1
            ? Color(red: 1, green: 0.83, blue: 0.28)
            : Color(red: 1, green: 0.57, blue: 0.26)
        if !reduceMotion, renderInCanvas {
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
