import SwiftUI
import RealityKit
import Observation

struct DiamondScoreAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Numeric, presentation-only endpoints, both in the named overlay space.
struct DiamondFlightLayout: Equatable {
    var viewport: CGRect
    var score: CGRect?
}

@MainActor @Observable final class DiamondHUDFlightModel {
    static let space = "laserheist.diamondHUD"
    static let duration = 0.55
    enum Target: Hashable { case normal(UUID), bonus(Int) }
    struct Flight: Identifiable {
        let id = UUID()
        let generation: UUID
        let target: Target
        let start: CGPoint
        let end: CGPoint
    }
    private(set) var generation: UUID?
    private(set) var flights: [Flight] = []
    private(set) var arrivalSerial = 0
    private(set) var started = 0
    private(set) var arrivals = 0
    private var running = false
    private var layout: DiamondFlightLayout?
    // Upstream presenters emit once; this bounded fence also rejects duplicate callbacks.
    private var seen: Set<Target> = []
    private var order: [Target] = []
    func session(_ generation: UUID, running: Bool) {
        if self.generation != generation {
            clear(); self.generation = generation; seen = []; order = []; started = 0; arrivals = 0
        }
        self.running = running
        if !running { flights = [] }
    }
    func geometry(_ layout: DiamondFlightLayout) {
        if self.layout != layout { flights = [] }
        self.layout = layout
    }
    func collect(_ target: Target, generation: UUID, world: SIMD3<Float>, reduceMotion: Bool,
                 project: (SIMD3<Float>) -> CGPoint?) {
        guard running, self.generation == generation, seen.insert(target).inserted else { return }
        order.append(target)
        if order.count > 128 { seen.remove(order.removeFirst()) }
        guard let layout, let score = layout.score, Self.valid(score), Self.valid(layout.viewport),
              layout.viewport.intersects(score) else { return }
        if reduceMotion { arrivalSerial += 1; arrivals += 1; return }
        guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
              let point = project(world), point.x.isFinite, point.y.isFinite,
              layout.viewport.contains(point) else { return }
        // Bounded cosmetic work; dropping the oldest visual never changes a domain outcome.
        if flights.count == 16 { flights.removeFirst() }
        flights.append(Flight(generation: generation, target: target, start: point,
                              end: CGPoint(x: score.midX, y: score.midY)))
        started += 1
    }
    func arrived(_ flight: Flight) {
        guard running, generation == flight.generation,
              flights.contains(where: { $0.id == flight.id }) else { return }
        flights.removeAll { $0.id == flight.id }
        arrivalSerial += 1; arrivals += 1
    }
    func clear() { flights = []; running = false }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
    static func point(from start: CGPoint, to end: CGPoint, progress: Double) -> CGPoint {
        let t = min(1, max(0, progress)), u = 1 - t
        let control = CGPoint(x: start.x + (end.x - start.x) * 0.3,
                              y: min(start.y, end.y) - min(70, abs(start.y - end.y) * 0.18))
        return CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                       y: u*u*start.y + 2*u*t*control.y + t*t*end.y)
    }
}

private struct DiamondFlightMotion: AnimatableModifier {
    var progress: Double
    let flight: DiamondHUDFlightModel.Flight
    let origin: CGPoint
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let point = DiamondHUDFlightModel.point(from: flight.start, to: flight.end, progress: progress)
        content.scaleEffect(1 - 0.7 * progress)
            .opacity(progress < 0.85 ? 1 : (1 - progress) / 0.15)
            .position(x: point.x - origin.x, y: point.y - origin.y)
    }
}
private struct FlyingDiamondToken: View {
    let flight: DiamondHUDFlightModel.Flight
    let origin: CGPoint
    let arrived: () -> Void
    @State private var progress = 0.0
    var body: some View {
        Image("LaserHeistUI/diamond").resizable().aspectRatio(contentMode: .fit)
            .frame(width: 26, height: 26).shadow(color: .cyan.opacity(0.85), radius: 6)
            .modifier(DiamondFlightMotion(progress: progress, flight: flight, origin: origin))
            .onAppear {
                withAnimation(.easeInOut(duration: DiamondHUDFlightModel.duration),
                              completionCriteria: .logicallyComplete) { progress = 1 } completion: { arrived() }
            }
    }
}

struct DiamondHUDFlightOverlay: View {
    let model: DiamondHUDFlightModel
    let scoreAnchor: Anchor<CGRect>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.frame(in: .named(DiamondHUDFlightModel.space))
            let score = scoreAnchor.map { proxy[$0].offsetBy(dx: viewport.minX, dy: viewport.minY) }
            let layout = DiamondFlightLayout(viewport: viewport, score: score)
            ZStack {
                if let score {
                    Capsule().stroke(.cyan, lineWidth: 2).shadow(color: .cyan, radius: 6)
                        .frame(width: score.width, height: score.height)
                        .phaseAnimator([0.0, 1.0, 0.0], trigger: model.arrivalSerial) { view, value in
                            view.opacity(value).scaleEffect(reduceMotion ? 1 : 1 + value * 0.04)
                        } animation: { _ in .easeOut(duration: 0.14) }
                        .position(x: score.midX - viewport.minX, y: score.midY - viewport.minY)
                }
                if !reduceMotion {
                    ForEach(model.flights) { flight in
                        FlyingDiamondToken(flight: flight, origin: viewport.origin) { model.arrived(flight) }
                    }
                }
                #if DEBUG
                Text("Flights \(model.started) · arrivals \(model.arrivals) · active \(model.flights.count)")
                    .font(.caption2.monospaced()).foregroundStyle(.cyan).frame(maxHeight: .infinity, alignment: .bottom)
                    .accessibilityIdentifier("diamondFlightDiagnostics")
                #endif
            }
            .onAppear { model.geometry(layout) }
            .onChange(of: layout) { _, value in model.geometry(value) }
            .onChange(of: reduceMotion) { _, _ in model.clear() }
        }
        .allowsHitTesting(false).accessibilityHidden(false)
        .onDisappear { model.clear() }
    }
}
