import SwiftUI

/// Presentation only. There is no timer, movement inference, or physical success threshold.
struct LeanTutorialOverlay: View {
    let tutorial: LeanTutorial
    let solo: Bool
    let next: () -> Void
    let skip: () -> Void
    let leave: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.system(size: 42, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center).foregroundStyle(LaserHeistDesign.cream)
                .accessibilityIdentifier("leanTutorialTitle")
            Spacer()
            HStack(spacing: 24) {
                Button("Leave", action: leave).accessibilityIdentifier("leanTutorialLeave")
                Button("Skip tutorial", action: skip).accessibilityIdentifier("leanTutorialSkip")
                Button(tutorial.stage == .practiceRight ? "Start playing" : "Continue", action: next)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("leanTutorialContinue")
            }.buttonStyle(.bordered).controlSize(.large)
        }
        .padding(40).padding(.top, 90)
        .background { if tutorial.stage == .introduction { Color.black.opacity(0.65) } }
        .accessibilityIdentifier("leanTutorialOverlay")
    }

    private var title: String {
        switch tutorial.stage {
        case .introduction: "Lean your head\nto move left and right"
        case .practiceLeft: "← LEAN LEFT"
        case .practiceRight: "LEAN RIGHT →"
        default: ""
        }
    }
}
