//
//  CalibrationView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

/// The two-player calibration step the screen hosts. PENDING Edo (camera
/// preview, per-player standing calibration) and Jevon (the session's
/// calibration step). Presentation only: this screen never decides that a
/// player is calibrated.
struct LaserHeistCalibrationStep {
    /// The live camera image shown behind the standing guides, as the camera
    /// delivers it (unmirrored), for example `CalibrationCameraPreview` on
    /// `CameraPipeline`'s session. This screen mirrors it for display.
    var cameraPreview: AnyView
    /// Calibrates both players and returns once both are done. Cancelled when
    /// the players leave the screen; an error keeps them on it.
    var run: @MainActor () async throws -> Void
}

/// "To start the game, stand here" (Sketch "Hi-Fi Revisi 6 NOV" › Game Set Up,
/// artboard "Home Copy 19"): the camera image with a dark fade from the top and
/// a dashed standing guide for each player, P1 left and P2 right.
struct CalibrationView: View {
    /// `nil` until the calibration producer exists: the guides show, and
    /// nothing moves on by itself.
    var step: LaserHeistCalibrationStep?
    let onBack: () -> Void
    let onCalibrated: () -> Void
    #if DEBUG
    /// DEBUG only, while no calibration step exists: go on to the replay round,
    /// which carries its own recorded calibration. Never shown in Release.
    var debugSkip: (() -> Void)?
    #endif

    var body: some View {
        SketchArtboard {
            ZStack {
                // Mirrored for display only (CP2 rule): players see themselves
                // as in a mirror, so P1 on the left stands in the left guide.
                step?.cameraPreview
                    .scaleEffect(x: -1, y: 1)
                // Sketch "Rectangle": a fade from the top at 74 % layer opacity,
                // so the camera image stays visible behind the titles.
                LinearGradient(colors: [Color(sketch: 0x0D0A26), Color(sketch: 0x1E1A41, opacity: 0)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.74)
            }
            .sketchBackdrop()
        } content: { k in
            if step == nil {
                cameraUnavailable(k)
            }
            standingGuide(k).offset(x: 183 * k, y: 225 * k)
                .accessibilityLabel("Player 1 standing area")
            standingGuide(k).offset(x: 661 * k, y: 225 * k)
                .accessibilityLabel("Player 2 standing area")

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

            SketchBackButton(k: k, action: onBack)
                .offset(x: 51 * k, y: 63 * k)

            #if DEBUG
            if step == nil, let debugSkip {
                Button("DEBUG · Skip calibration (replay round)", action: debugSkip)
                    .font(.system(size: 15 * k, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 14 * k)
                    .padding(.vertical, 8 * k)
                    .background(Color(sketch: 0xFFC83A), in: Capsule())
                    .foregroundStyle(Color(sketch: 0x16123A))
                    .buttonStyle(.plain)
                    .frame(width: 1210 * k)
                    .offset(y: 792 * k)
                    .accessibilityIdentifier("debugSkipCalibration")
            }
            #endif
        }
        .task {
            guard let step else { return }
            do {
                try await step.run()
                guard !Task.isCancelled else { return }
                onCalibrated()
            } catch {
                // Stay here: the players can try again or go back.
                print("CalibrationView: calibration did not complete: \(error)")
            }
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
    static let unavailableText = "Camera preview unavailable in Simulator"
    #else
    static let unavailableText = "Camera preview not connected yet"
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
    CalibrationView(step: nil, onBack: {}, onCalibrated: {})
}
