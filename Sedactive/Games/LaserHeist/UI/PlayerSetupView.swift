//
//  PlayerSetupView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

/// Game Set Up (Sketch "Hi-Fi Revisi 6 NOV" › Game Set Up): "Put your iPad on
/// the Floor", in the two artboards' order: the iPad held in both hands
/// ("Home Copy 15"), then the mascot standing it on the floor ("Home Copy 23").
/// Back returns one step; the check button goes on.
struct PlayerSetupView: View {
    enum Step: Int, CaseIterable {
        case holdIPad, standIPadOnFloor
    }

    let step: Step
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        SketchArtboard {
            SunburstBackground()
        } content: { k in
            switch step {
            case .holdIPad:
                Image("LaserHeistUI/setup-hands")
                    .resizable()
                    .sketchFrame(x: 83, y: 263, width: 1075, height: 655, k: k)
                    .accessibilityLabel("Two hands holding an iPad")
            case .standIPadOnFloor:
                Image("LaserHeistUI/setup-mascot")
                    .resizable()
                    .sketchFrame(x: 419, y: 224, width: 371, height: 474, k: k)
                    .accessibilityLabel("The mascot standing an iPad up on the floor")
            }

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

            SetupNextButton(k: k, action: onNext)
                .sketchFrame(x: 1005, y: 663, width: 143, height: 110, k: k)
        }
    }
}

/// The orange check button (Sketch "Group 3"): Next on the Set Up screens.
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
        .accessibilityLabel("Next")
        .accessibilityIdentifier("setupNext")
    }
}

#Preview("Hold the iPad", traits: .landscapeLeft) {
    PlayerSetupView(step: .holdIPad, onBack: {}, onNext: {})
}

#Preview("Stand it on the floor", traits: .landscapeLeft) {
    PlayerSetupView(step: .standIPadOnFloor, onBack: {}, onNext: {})
}
