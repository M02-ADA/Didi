import SwiftUI

/// Presentation only. Continue is explicit acknowledgement, never a movement verdict.
struct LeanTutorialOverlay: View {
    let tutorial: LeanTutorial
    let solo: Bool
    let next: () -> Void
    let skip: () -> Void
    let leave: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            ZStack {
                if tutorial.stage == .introduction {
                    // System backdrop material exists only during the introduction, not practice.
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Color.black.opacity(0.48)
                    LeanIntroductionAnimation(solo: solo)
                        .frame(width: (solo ? 330 : 660) * k, height: 455 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.34)
                    Text("Lean your head\nto move left and right")
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream).multilineTextAlignment(.center)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.61)
                        .accessibilityIdentifier("leanTutorialTitle")
                } else {
                    Text(tutorial.stage == .practiceLeft ? "← LEAN LEFT" : "LEAN RIGHT →")
                        .font(.system(size: 48 * k, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white).shadow(color: .black, radius: 5)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.19)
                        .accessibilityIdentifier("leanTutorialTitle")
                }
                VStack { Spacer()
                    HStack(spacing: 24 * k) {
                        Button("Leave", action: leave).accessibilityIdentifier("leanTutorialLeave")
                        Button("Skip tutorial", action: skip).accessibilityIdentifier("leanTutorialSkip")
                        Button(tutorial.stage == .practiceRight ? "Start playing" : "Continue", action: next)
                            .buttonStyle(.borderedProminent).tint(Color(sketch: 0xE97333))
                            .accessibilityIdentifier("leanTutorialContinue")
                    }
                    .font(.system(size: max(17, 23 * k), weight: .bold, design: .rounded))
                    .buttonStyle(.bordered).controlSize(.large)
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 24 * k))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityIdentifier("leanTutorialOverlay")
    }
}
