import SwiftUI

/// Home Copy 27's help control, using the same lavender/navy surface as the HUD.
struct HomeTutorialHelpButton: View {
    let k: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HUDSurface(shape: Circle(), k: k)
                Text("?")
                    .font(.system(size: 48 * k, weight: .black, design: .rounded))
                    .foregroundStyle(LaserHeistDesign.iconCream)
            }
            .frame(width: 78 * k, height: 78 * k)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Replay tutorial")
        .accessibilityIdentifier("replayTutorial")
    }
}
