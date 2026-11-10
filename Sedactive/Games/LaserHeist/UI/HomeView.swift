//
//  HomeView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

/// Home (Sketch "Hi-Fi Revisi 6 NOV" › Home Screen, artboard "Home Copy 27"):
/// the vault frame, the DIDI logo, START MISSION! and the best score.
struct HomeView: View {
    /// The team's best score. PENDING: nothing records one yet (no owner or
    /// store); without it the line is left out rather than showing a made-up value.
    var bestScore: Int?
    let onStart: () -> Void

    var body: some View {
        SketchArtboard {
            Image("LaserHeistUI/home-frame")
                .resizable()
                .scaledToFill()
                .sketchBackdrop()
        } content: { k in
            Image("LaserHeistUI/didi-logo")
                .resizable()
                .shadow(color: .black.opacity(0.23), radius: 4.5 * k, x: 8 * k, y: 4 * k)
                .sketchFrame(x: 336, y: 184, width: 539, height: 260, k: k)
                .accessibilityLabel("DIDI")
                .accessibilityAddTraits(.isHeader)

            Button(action: onStart) {
                Text("START MISSION!")
                    .font(.system(size: 67 * k, weight: .heavy))
                    .foregroundStyle(LaserHeistDesign.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 40 * k)
            }
            .buttonStyle(StartMissionButtonStyle(k: k))
            .sketchFrame(x: 197.6, y: 482, width: 816.3, height: 121.7, k: k)
            .accessibilityIdentifier("startMission")

            if let bestScore {
                Text("BEST SCORE: \(bestScore)")
                    .font(.system(size: 24.4 * k, weight: .medium, design: .monospaced))
                    .tracking(8.78 * k)
                    .foregroundStyle(LaserHeistDesign.cream)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 1210 * k)
                    .offset(y: 621 * k)
                    .accessibilityIdentifier("bestScore")
            }
        }
    }
}

/// START MISSION! (Sketch "Frame 1"): an angled-corner orange plate with a
/// light-to-orange inside edge, on a dark plate 8 pt lower.
struct StartMissionButtonStyle: ButtonStyle {
    let k: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let plate = ChamferedRectangle(chamfer: 25.2 * k)
        let pressed = configuration.isPressed
        return ZStack(alignment: .top) {
            plate.fill(LaserHeistDesign.startBase)
                .frame(height: 113.7 * k)
                .offset(y: 8 * k)
            configuration.label
                .frame(maxWidth: .infinity)
                .frame(height: 113.6 * k)
                .background(LinearGradient(stops: [.init(color: LaserHeistDesign.startTop, location: 0),
                                                   .init(color: LaserHeistDesign.startBottom, location: 0.98)],
                                           startPoint: .top, endPoint: .bottom), in: plate)
                .overlay(plate.strokeBorder(LinearGradient(colors: [LaserHeistDesign.startEdgeTop, LaserHeistDesign.startEdgeBottom],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 5 * k))
                .brightness(pressed ? -0.05 : 0)
                .offset(y: pressed && !reduceMotion ? 5 * k : 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(plate)
        .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

#Preview(traits: .landscapeLeft) {
    HomeView(bestScore: 930, onStart: {})
}
