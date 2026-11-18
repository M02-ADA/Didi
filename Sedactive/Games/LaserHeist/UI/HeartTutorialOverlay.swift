import SwiftUI

/// Finite explanation/demo phases, not gameplay time, damage or collision state.
enum HeartTutorialPhase: String, CaseIterable {
    case introduction, hurt, warning
    var duration: Double { self == .hurt ? 2 : 4 }
    var usesOverlay: Bool { self != .hurt }
    var next: Self? { self == .introduction ? .hurt : self == .hurt ? .warning : nil }
    var copy: String {
        switch self {
        case .introduction: "This is your shared health,\navoid lasers to protect it"
        case .hurt: ""
        case .warning: "Your health will be deducted\nif you get hit by lasers"
        }
    }
}

struct HeartTutorialOverlay: View {
    let phase: HeartTutorialPhase
    /// Actual HUD bounds in global SwiftUI space, supplied by its existing host.
    var healthFrame: CGRect?
    var onVisibilityChange: (Bool) -> Void = { _ in }
    var completed: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    private struct Visibility: Equatable { let phase: HeartTutorialPhase; let active: Bool }

    var body: some View {
        GeometryReader { proxy in
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            let origin = proxy.frame(in: .global).origin
            let health = healthFrame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ZStack {
                if phase.usesOverlay {
                    if let health {
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: proxy.size))
                            p.addRoundedRect(in: health.insetBy(dx: -4 * k, dy: -4 * k), cornerSize: CGSize(width: 36 * k, height: 36 * k))
                        }
                        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        RoundedRectangle(cornerRadius: 34 * k)
                            .stroke(LaserHeistDesign.cream.opacity(0.8), lineWidth: 2 * k)
                            .frame(width: health.width + 4 * k, height: health.height + 4 * k)
                            .position(x: health.midX, y: health.midY)
                    } else {
                        // Until actual geometry arrives, leave the whole top HUD readable.
                        Color.black.opacity(0.55).padding(.top, 150 * k)
                    }
                    Image("LaserHeistUI/ftue-hearts")
                        .resizable().scaledToFit()
                        .frame(width: 280 * k, height: 280 * k * 588 / 1240)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.38)
                        .accessibilityHidden(true)
                    Text(phase.copy)
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(width: proxy.size.width * 0.9)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.59)
                        .accessibilityIdentifier("heartTutorialTitle")

                } else {
                    Color.clear.accessibilityElement()
                        .accessibilityLabel("Instructional laser encounter; scripted training damage")
                        .accessibilityIdentifier("heartTrainingEncounter")
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea().allowsHitTesting(false)
        .task(id: Visibility(phase: phase, active: scenePhase == .active)) {
            let active = scenePhase == .active
            onVisibilityChange(active)
            guard active, phase.usesOverlay else { return }
            do { try await Task.sleep(for: .seconds(phase.duration)) } catch { return }
            guard !Task.isCancelled else { return }
            completed()
        }
        .onDisappear { onVisibilityChange(false) }
    }
}
