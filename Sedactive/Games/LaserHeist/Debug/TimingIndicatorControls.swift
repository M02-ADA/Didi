#if DEBUG
import SwiftUI
import RealityKit

/// Renderer selection only; this view owns no gameplay timing or evidence.
struct TimingIndicatorControls: View {
    let session: GameSessionCoordinator?
    let scene: LaserScene
    let retry: () -> Void
    var viewport: CGSize = .zero
    @State private var clearance = ""
    @State private var selected: TimingIndicatorVariant = launchVariant ?? .circular
    @State private var busy = false
    @State private var error: String?
    static var isComparison: Bool { ProcessInfo.processInfo.arguments.contains("-timingComparison") }
    static var launchVariant: TimingIndicatorVariant? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-timingIndicator"), args.indices.contains(i + 1) else { return nil }
        return TimingIndicatorVariant(rawValue: args[i + 1])
    }
    static let steps: [(String, Double)] = [
        ("Duck early", 1.15), ("Duck prepare", 2.6), ("Duck near", 3.85), ("Duck immediately before", 3.99),
        ("Duck crossing", 4), ("Duck follow-through 60ms", 4.06), ("Duck follow-through 120ms", 4.12), ("Duck result", 4.4),
        ("Jump early", 7.15), ("Jump prepare", 8.6), ("Jump near", 9.85), ("Jump immediately before", 9.99),
        ("Jump crossing", 10), ("Jump follow-through 60ms", 10.06), ("Jump follow-through 120ms", 10.12), ("Jump result", 10.4)]
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if Self.isComparison {
                Text("SYNTHETIC REPLAY · same encounters / no camera")
                    .font(.caption2.bold())
                Text(String(format: "t %.2f · score %d", session?.state?.gameTime ?? 0, session?.state?.teamScore ?? 0))
                    .font(.caption.monospaced()).accessibilityIdentifier("timingSourceReadout")
                HStack {
                    Menu("Step fixture") {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                            Button(step.0) { advance(step.1) }.disabled(busy || (session?.state?.gameTime ?? 0) > step.1)
                                .accessibilityIdentifier("timingStep\(i)")
                        }
                    }.accessibilityIdentifier("timingSteps")
                    Button("Retry fixture", action: retry).accessibilityIdentifier("timingRetry")
                }
                Menu("Layout fixture") {
                    ForEach(0..<6) { i in
                        Button(["Solo center", "Solo left", "Solo right", "Co-op start", "Co-op shifted left", "Co-op shifted right"][i]) { inspect(i) }
                            .accessibilityIdentifier("timingLayout\(i)")
                    }
                }.accessibilityIdentifier("timingLayoutMenu")
                Text(clearance).font(.caption2.monospaced()).accessibilityIdentifier("timingClearance")
                if let error { Text(error).accessibilityIdentifier("timingError") }
            }
            Menu("Timing · \(selected.title)") {
                ForEach(TimingIndicatorVariant.allCases, id: \.self) { variant in
                    Button(variant.title) { selected = variant; scene.selectTimingVariant(variant) }
                        .accessibilityIdentifier("timingVariant_\(variant.rawValue)")
                }
            }
            .accessibilityIdentifier("timingSelector")
            .font(.caption.bold())
        }
        .buttonStyle(.bordered).tint(.cyan)
        .foregroundStyle(.white).padding(10)
        .background(.black.opacity(0.75), in: .rect(cornerRadius: 12))
        .padding(.trailing, 14).padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Held synthetic replay only: reuse actual avatar/board parents at allowed lateral
    /// positions, then project their world bounds with the scene's actual loaded camera.
    /// This is a requested snapshot, not a dynamic layout solver or gameplay input.
    private func inspect(_ index: Int) {
        guard Self.isComparison, session?.isReplay == true, let robots = scene.robotAvatars,
              let steering = robots.steering,
              let camera = scene.root.findEntity(named: "camera") as? PerspectiveCamera,
              let cue = scene.root.findEntity(named: "timing.circularCue"), viewport.height > 0 else { return }
        let bounds = steering.bounds
        let separation = steering.minimumSeparation
        let solo = index < 3
        let p1: Float = index == 0 ? 0 : index == 1 || index == 4 ? bounds.lowerBound
            : index == 2 ? bounds.upperBound : index == 5 ? bounds.upperBound-separation
            : scene.mapping.laneCenterX[.player1, default: -0.7]
        let p2: Float = index == 4 ? bounds.lowerBound+separation : index == 5 ? bounds.upperBound
            : scene.mapping.laneCenterX[.player2, default: 0.7]
        scene.players[.player2]?.isEnabled = !solo
        for (player, x) in [(PlayerID.player1,p1), (.player2,p2)] {
            if let robot = robots.robots[player] { scene.players[player]?.position.x = x - robot.container.position.x }
        }
        let t = camera.transformMatrix(relativeTo: nil)
        let origin = SIMD3(t.columns.3.x,t.columns.3.y,t.columns.3.z)
        let right = simd_normalize(SIMD3(t.columns.0.x,t.columns.0.y,t.columns.0.z))
        let up = simd_normalize(SIMD3(t.columns.1.x,t.columns.1.y,t.columns.1.z))
        let forward = -simd_normalize(SIMD3(t.columns.2.x,t.columns.2.y,t.columns.2.z))
        let half = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        func rect(_ entity: Entity) -> CGRect {
            let b = entity.visualBounds(relativeTo: nil)
            var result = CGRect.null
            for x in [b.min.x,b.max.x] { for y in [b.min.y,b.max.y] { for z in [b.min.z,b.max.z] {
                let d = SIMD3(x,y,z)-origin, depth = simd_dot(d,forward)
                guard depth > 0 else { continue }
                let px = (CGFloat(simd_dot(d,right)/depth/half) * viewport.height + viewport.width)/2
                let py = (1-CGFloat(simd_dot(d,up)/depth/half))*viewport.height/2
                result = result.union(CGRect(x:px,y:py,width:0.01,height:0.01))
            } } }
            return result
        }
        let c = rect(cue)
        let gaps = robots.robots.sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { player,robot -> String? in
            guard !solo || player == .player1 else { return nil }
            let a = rect(robot.container)
            let gap = a.minY-c.maxY
            return String(format:"%@ gap %.1f",player.rawValue,gap)
        }.joined(separator:" / ")
        clearance = String(format:"%d %.0fx%.0f cue y %.1f–%.1f · ",index,viewport.width,viewport.height,c.minY,c.maxY)+gaps
    }

    private func advance(_ time: Double) {
        guard Self.isComparison, let session, session.isReplay, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await session.advance(to: time) } catch { self.error = String(describing: error) }
        }
    }
}
#endif
