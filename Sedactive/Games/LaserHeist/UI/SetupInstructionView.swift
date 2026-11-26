//
//  SetupInstructionView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

/// Alternates the two iPad placement illustrations while waiting for confirmation.
struct SetupInstructionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsMascot = false

    let onBack: () -> Void
    var heldIllustration: Bool? = nil
    let onNext: (Bool) -> Void

    var body: some View {
        let showsMascot = heldIllustration ?? self.showsMascot
        SketchArtboard {
            SunburstBackground()
        } content: { k in
            ZStack(alignment: .topLeading) {
                Image("LaserHeistUI/setup-hands")
                    .resizable()
                    .sketchFrame(x: 83, y: 263, width: 1075, height: 655, k: k)
                    .opacity(showsMascot ? 0 : 1)
                    .accessibilityLabel("Two hands holding an iPad")
                    .accessibilityHidden(showsMascot)

                Image("LaserHeistUI/setup-mascot")
                    .resizable()
                    .sketchFrame(x: 419, y: 224, width: 371, height: 474, k: k)
                    .opacity(showsMascot ? 1 : 0)
                    .accessibilityLabel("The mascot standing an iPad up on the floor")
                    .accessibilityHidden(!showsMascot)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: showsMascot)

            Text("Put your iPad on the Floor")
                .font(.system(size: 58.3 * k, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 1210 * k, height: 69 * k)
                .offset(y: 103 * k)
                .accessibilityAddTraits(.isHeader)

            SketchBackButton(k: k, action: onBack)
                .offset(x: 51 * k, y: 63 * k)

            SetupNextButton(k: k) { onNext(showsMascot) }
                .disabled(heldIllustration != nil)
                .sketchFrame(x: 1005, y: 663, width: 143, height: 110, k: k)
        }
        .task(id: scenePhase) {
            guard heldIllustration == nil, scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.showsMascot.toggle()
            }
        }
    }
}

/// The orange check button confirms placement and opens calibration.
struct SetupNextButton: View {
    let k: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 50.9 * k, weight: .heavy))
                .foregroundStyle(LaserHeistDesign.iconCream)
        }
        .buttonStyle(LayeredPillButtonStyle(top: LaserHeistDesign.orangeTop, bottom: LaserHeistDesign.orangeBottom,
                                            rim: LaserHeistDesign.orangeRim, base: LaserHeistDesign.orangeBase,
                                            rimHeight: 4 * k, baseHeight: 2 * k))
        .accessibilityLabel("Continue to calibration")
        .accessibilityIdentifier("setupNext")
    }
}

#Preview("iPad placement", traits: .landscapeLeft) {
    SetupInstructionView(onBack: {}, onNext: { _ in })
}
