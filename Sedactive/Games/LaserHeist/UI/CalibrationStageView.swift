//
//  CalibrationStageView.swift
//  Sedactive
//

import SwiftUI

/// "To start the game, stand here" (Sketch "Hi-Fi Revisi 6 NOV" › Game Set Up,
/// artboard "Home Copy 19"): the camera image with a fade from the top and a
/// dashed standing guide for each player, P1 left and P2 right.
///
/// Presentation only. Binding, calibration and readiness are the live
/// session's (`LaserSessionSetup`, Jevon); its controls sit in `panel`. Nothing
/// here decides that a player is placed or calibrated.
struct CalibrationStageView<Panel: View>: View {
    /// The camera image as the camera delivers it (unmirrored), e.g.
    /// `CalibrationCameraPreview` on `CameraPipeline`'s session; mirrored here
    /// for display. PENDING Edo: no preview is exposed yet.
    var cameraPreview: AnyView?
    let onBack: () -> Void
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        SketchArtboard {
            ZStack {
                // Mirrored for display only (CP2 rule): players see themselves
                // as in a mirror, so P1 on the left stands in the left guide.
                cameraPreview
                    .scaleEffect(x: -1, y: 1)
                // Sketch "Rectangle": a fade from the top at 74 % layer opacity.
                LinearGradient(colors: [Color(sketch: 0x0D0A26), Color(sketch: 0x1E1A41, opacity: 0)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.74)
            }
            .sketchBackdrop()
        } content: { k in
            if cameraPreview == nil {
                cameraUnavailable(k)
                    .offset(y: Panel.self == EmptyView.self ? 0 : 604 * k)
            }
            standingGuide(k).offset(x: 183 * k, y: 225 * k)
                .accessibilityLabel("Player 1 standing area")
            standingGuide(k).offset(x: 661 * k, y: 225 * k)
                .accessibilityLabel("Player 2 standing area")

            // With the session's setup card the card's own phase titles take this
            // place, so nothing covers the standing guides.
            if Panel.self == EmptyView.self {
            VStack(spacing: 0) {
                Text("To start the game,")
                    .font(.system(size: 25.9 * k, weight: .bold, design: .rounded))
                    .frame(height: 31 * k)
                Text("stand here")
                    .font(.system(size: 66 * k, weight: .bold, design: .rounded))
                    .frame(height: 79 * k)
                    .offset(y: -6 * k)
            }
            .foregroundStyle(.white)
            .frame(width: 1210 * k)
            .offset(y: 73 * k)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            }

            SketchBackButton(k: k, action: onBack)
                .offset(x: 51 * k, y: 63 * k)

            // The session's card in the title band, artboard y 14–220: it ends
            // above the guides (225) on every iPad size.
            panel()
                .frame(width: 1210 * k, height: 206 * k, alignment: .top)
                .offset(y: 14 * k)
        }
    }

    /// Said plainly when there is no camera image, so the empty guides are not
    /// mistaken for a camera that sees nobody. Not a Sketch element.
    private func cameraUnavailable(_ k: CGFloat) -> some View {
        Label(Self.unavailableText, systemImage: "video.slash.fill")
            .font(.system(size: 17 * k, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16 * k)
            .padding(.vertical, 8 * k)
            .background(.white.opacity(0.12), in: Capsule())
            .frame(width: 1210 * k)
            .offset(y: 183 * k)
            .accessibilityIdentifier("cameraPreviewUnavailable")
    }

    #if targetEnvironment(simulator)
    static var unavailableText: String { "Camera preview unavailable in Simulator" }
    #else
    static var unavailableText: String { "Camera preview not connected yet" }
    #endif

    /// A white dashed rounded rectangle, 365 × 553 pt, corner radius 59, 5 pt
    /// inside border (Sketch "Rectangle").
    private func standingGuide(_ k: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 59 * k, style: .continuous)
            .strokeBorder(.white, style: StrokeStyle(lineWidth: 5 * k, lineCap: .butt, dash: [28 * k, 14 * k]))
            .frame(width: 365 * k, height: 553 * k)
    }
}

#Preview(traits: .landscapeLeft) {
    CalibrationStageView(onBack: {}) { EmptyView() }
}
