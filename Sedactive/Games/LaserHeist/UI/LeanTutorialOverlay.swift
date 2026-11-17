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
                    // The host applies a small blur only during this introduction. Darken
                    // without a second live backdrop filter, keeping the mascots recognizable.
                    Color.black.opacity(0.55)
                    LeanIntroductionAnimation(solo: solo)
                        .frame(width: (solo ? 330 : 660) * k, height: 455 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.34)
                    Text("Lean your head\nto move left and right")
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream).multilineTextAlignment(.center)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.61)
                        .accessibilityIdentifier("leanTutorialTitle")
                } else {
                    if let placement = LeanCuePlacement.make(viewport: proxy.size, headTopFraction: tutorial.headTopFraction) {
                        Image(uiImage: tutorial.stage == .practiceLeft ? LeanInstructionArtwork.left : LeanInstructionArtwork.right)
                            .resizable().frame(width: placement.frame.width, height: placement.frame.height)
                            .position(x: placement.frame.midX, y: placement.frame.midY)
                            .accessibilityLabel(tutorial.stage == .practiceLeft ? "← LEAN LEFT" : "LEAN RIGHT →")
                            .accessibilityIdentifier("leanTutorialTitle")
                    } else {
                        ProgressView("Preparing movement guide…").tint(.white)
                    }
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
                    .foregroundStyle(LaserHeistDesign.cream)
                    .padding(10 * k).background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 24 * k))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Match the full-bleed RealityView projection space; the prior safe-area inset
        // added 24 points to otherwise correct projected positions on the iPad Simulator.
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
    }
}
