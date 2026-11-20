import Observation
import SwiftUI

/// A script for the tutorial presentation. It has no session, scoring or contact dependency.
@MainActor @Observable final class FTUEDiamondTimeDemo {
    static let duration = 5.8
    static let pickupTimes = [1.05, 2.25, 3.45, 4.65]

    private(set) var elapsed: Double = 0
    @ObservationIgnored private var previousTick: Double?

    var collectedCount: Int { Self.pickupTimes.filter { $0 <= elapsed }.count }

    func advance(at now: Double, active: Bool) -> Bool {
        guard active, now.isFinite else { pause(); return false }
        defer { previousTick = now }
        guard let previousTick, now > previousTick, now - previousTick <= 0.25 else { return false }
        elapsed = min(Self.duration, elapsed + now - previousTick)
        return elapsed == Self.duration
    }

    func pause() { previousTick = nil }

    func reset() {
        elapsed = 0
        pause()
    }
}

struct FTUEDiamondTimeDemoView: View {
    let demo: FTUEDiamondTimeDemo
    let solo: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The four pickups alternate between players. In Solo, both lanes use Lemon's paws.
    private let targets = [CGPoint(x: 0.37, y: 0.60), CGPoint(x: 0.79, y: 0.38),
                           CGPoint(x: 0.22, y: 0.34), CGPoint(x: 0.65, y: 0.55)]
    private let homes = [CGPoint(x: 0.25, y: 0.74), CGPoint(x: 0.79, y: 0.72),
                         CGPoint(x: 0.17, y: 0.61), CGPoint(x: 0.71, y: 0.77)]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let k = min(size.width / 1210, size.height / 834)
            let header = 175 * k
            ZStack(alignment: .top) {
                // The real LaserScene stays mounted. The reward room is an FTUE view layer
                // below the existing HUD, using the shipped interior artwork.
                Image("LaserHeistVault/final-vault-inside")
                    .resizable().scaledToFill()
                    .frame(width: size.width, height: size.height - header)
                    .clipped()
                    .position(x: size.width / 2, y: (size.height + header) / 2)
                    .accessibilityHidden(true)
                Text("Diamond Time")
                    .font(.system(size: 47 * k, weight: .heavy, design: .rounded))
                    .foregroundStyle(LaserHeistDesign.cream)
                    .shadow(color: .black.opacity(0.75), radius: 6 * k)
                    .position(x: size.width / 2, y: header - 27 * k)
                    .accessibilityLabel("FTUE Diamond Time demo")
                    .accessibilityValue("\(demo.collectedCount) tutorial diamonds collected")
                    .accessibilityIdentifier("ftueDiamondTimeDemo")
                ForEach(targets.indices, id: \.self) { index in
                    pickup(index, size: size, scale: k)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    private func pickup(_ index: Int, size: CGSize, scale k: CGFloat) -> some View {
        let age = demo.elapsed - FTUEDiamondTimeDemo.pickupTimes[index]
        let target = targets[index]
        let home = homes[index]
        let reach = max(0, 1 - abs(age + 0.05) / (age < -0.05 ? 0.58 : 0.42))
        let movement = reduceMotion ? (age >= 0 && age < 0.28 ? 1 : 0) : reach * reach * (3 - 2 * reach)
        let paw = CGPoint(x: home.x + (target.x - home.x) * movement,
                          y: home.y + (target.y - home.y) * movement)
        let color = index.isMultiple(of: 2) || solo ? "yellow" : "orange"
        let side = index < 2 ? "right" : "left"
        let burst = max(0, min(1, age / 0.65))
        return ZStack {
            if age < 0 {
                Image("LaserHeistUI/diamond").resizable().scaledToFit()
                    .frame(width: (index == 1 ? 91 : 75) * k)
                    .shadow(color: Color.blue.opacity(0.8), radius: 16 * k)
                    .position(x: target.x * size.width,
                              y: target.y * size.height + (reduceMotion ? 0 : sin(demo.elapsed * 3 + Double(index)) * 6 * k))
            }
            if age < 0.52 {
                Image("LaserHeistUI/paw-\(color)-\(side)").resizable().scaledToFit()
                    .frame(width: 85 * k)
                    .shadow(color: (color == "yellow" ? Color.yellow : Color.orange).opacity(0.55), radius: 14 * k)
                    .opacity(age < 0.23 ? 1 : (0.52 - age) / 0.29)
                    .position(x: paw.x * size.width, y: paw.y * size.height)
            }
            if age >= 0, age < 0.65 {
                ZStack {
                    Circle().strokeBorder(LaserHeistDesign.cream, lineWidth: 3 * k)
                    Image(systemName: "sparkle")
                        .font(.system(size: 34 * k, weight: .bold))
                        .foregroundStyle(LaserHeistDesign.cream)
                }
                .frame(width: (reduceMotion ? 75 : 60 + burst * 80) * k)
                .opacity(1 - burst)
                .position(x: target.x * size.width, y: target.y * size.height)
            }
        }
        .accessibilityHidden(true)
    }
}
