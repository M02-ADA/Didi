//
//  CalibrationStageView.swift
//  Sedactive
//

import SwiftUI

/// "To start the game, stand here" (Sketch "Hi-Fi Revisi 6 NOV" › Game Set Up,
/// artboard "Home Copy 19"): the camera image and a dashed standing guide for
/// each player, P1 left and P2 right.
///
/// The WHOLE camera frame is shown (aspect fit, never cropped), below a compact
/// instruction band, so what the players see is exactly what tracking sees, and
/// the guides are laid out as shares of that image: each covers most of its half.
/// The 11 November layout used aspect fill, which cut about a quarter of the 16:9
/// image's width off a 4:3 screen, and fixed 365 × 553 pt guides not tied to it.
///
/// Presentation only. Binding, calibration and readiness are the live
/// session's; its controls sit in `panel`. Nothing here decides that a player is
/// placed or calibrated, and the guides never change tracking coordinates.
struct CalibrationStageView<Panel: View>: View {
    /// The camera image as the camera delivers it (unmirrored), e.g.
    /// `CalibrationCameraPreview` on `CameraPipeline.previewSession`; mirrored
    /// here for display.
    var cameraPreview: AnyView?
    /// The capture's width ÷ height (1280 × 720 → 16:9).
    var cameraAspect: CGFloat = 16 / 9
    /// Automatic setup: each player's status, shown inside their standing guide.
    var playerStatus: [PlayerID: LaserSetupPlayerStatus] = [:]
    /// DEBUG Solo Test: one centred guide for P1 instead of two halves.
    var solo = false
    let onBack: () -> Void
    @ViewBuilder var panel: () -> Panel

    /// Guide size as shares of the camera image: each player's half, with a margin.
    static var guideWidthShare: CGFloat { 0.42 }
    static var guideHeightShare: CGFloat { 0.94 }

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width / LaserHeistDesign.artboard.width, geo.size.height / LaserHeistDesign.artboard.height)
            let band = Self.bandHeight(for: geo.size)
            let image = Self.imageRect(in: geo.size, band: band, aspect: cameraAspect)
            ZStack(alignment: .topLeading) {
                Color.black
                // Mirrored for display only (CP2 rule): players see themselves
                // as in a mirror, so P1 on the left stands in the left guide.
                if let cameraPreview {
                    cameraPreview
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: image.width, height: image.height)
                        .offset(x: image.minX, y: image.minY)
                } else {
                    cameraUnavailable(k)
                        .frame(width: image.width)
                        .offset(x: image.minX, y: image.maxY - 60 * k)
                }
                // Sketch "Rectangle": a fade from the top at 74 % layer opacity, over the band only.
                LinearGradient(colors: [Color(sketch: 0x0D0A26), Color(sketch: 0x1E1A41, opacity: 0)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.74)
                    .frame(width: geo.size.width, height: band * 1.4)
                    .allowsHitTesting(false)
                ForEach(solo ? [PlayerID.player1] : PlayerID.allCases, id: \.self) { player in
                    let guide = solo ? Self.soloGuideRect(in: image) : Self.guideRect(player, in: image)
                    standingGuide(player, k: k, corner: guide.width * 0.14)
                        .frame(width: guide.width, height: guide.height)
                        .offset(x: guide.minX, y: guide.minY)
                        .accessibilityLabel(player == .player1 ? "Player 1 standing area" : "Player 2 standing area")
                    // In the guide's outer top corner: never over the feet (the hints ask players
                    // to check them) or the head (centred).
                    if let status = playerStatus[player] {
                        statusChip(player, status, k)
                            .frame(width: guide.width - 2 * guide.width * 0.1,
                                   alignment: player == .player1 ? .leading : .trailing)
                            .offset(x: guide.minX + guide.width * 0.1, y: guide.minY + 18 * k)
                    }
                }
                HStack(alignment: .top, spacing: 16 * k) {
                    SketchBackButton(k: k, action: onBack)
                    if Panel.self == EmptyView.self {
                        Text("To start the game, stand here")
                            .font(.system(size: 34 * k, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        panel().frame(maxWidth: .infinity, maxHeight: band - 16 * k, alignment: .top)
                    }
                }
                .padding(.horizontal, 24 * k).padding(.top, 10 * k)
                .frame(width: geo.size.width, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
    }

    /// The instruction band above the image: room for a short title, one line and buttons.
    static func bandHeight(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.15, 110), 160)
    }

    /// The camera image, aspect fit (whole frame) and centred in the space below the band.
    static func imageRect(in size: CGSize, band: CGFloat, aspect: CGFloat) -> CGRect {
        let available = CGSize(width: size.width, height: max(1, size.height - band))
        let width = min(available.width, available.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: band + (available.height - height) / 2, width: width, height: height)
    }

    /// A player's guide: most of their half of the (mirrored) image, P1 left.
    static func guideRect(_ player: PlayerID, in image: CGRect) -> CGRect {
        let width = image.width * guideWidthShare, height = image.height * guideHeightShare
        let half = image.width / 2
        let x = image.minX + (player == .player1 ? 0 : half) + (half - width) / 2
        return CGRect(x: x, y: image.minY + (image.height - height) / 2, width: width, height: height)
    }

    /// The solo guide: the middle of the image, the size of one co-op guide.
    static func soloGuideRect(in image: CGRect) -> CGRect {
        let width = image.width * guideWidthShare, height = image.height * guideHeightShare
        return CGRect(x: image.midX - width / 2, y: image.minY + (image.height - height) / 2, width: width, height: height)
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
            .accessibilityIdentifier("cameraPreviewUnavailable")
    }

    #if targetEnvironment(simulator)
    static var unavailableText: String { "Camera preview unavailable in Simulator" }
    #else
    static var unavailableText: String { "Camera preview not connected yet" }
    #endif

    /// The Sketch dashed rounded rectangle, 5 pt border: dashed while searching,
    /// solid once the player is found, green when ready.
    private func standingGuide(_ player: PlayerID, k: CGFloat, corner: CGFloat) -> some View {
        let status = playerStatus[player]
        let found = status.map { $0 != .searching } ?? false
        let color: Color = status == .ready ? Color(sketch: 0x7BE38A) : .white
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 5 * k, lineCap: .butt,
                                                    dash: found ? [] : [28 * k, 14 * k]))
    }

    /// A readable status pill with a progress bar while measuring. No technical terms.
    private func statusChip(_ player: PlayerID, _ status: LaserSetupPlayerStatus, _ k: CGFloat) -> some View {
        VStack(spacing: 6 * k) {
            Label(LaserAutomaticSetupCopy.chip(player, status, solo: solo),
                  systemImage: status == .ready ? "checkmark.circle.fill" : status == .searching ? "person.fill.questionmark" : "figure.stand")
                .font(.system(size: 19 * k, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if case .calibrating(let progress, _) = status {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(player == .player1 ? Color(sketch: 0xF6CA58) : Color(sketch: 0xF78146))
                    .frame(width: 170 * k)
            }
        }
        .padding(.horizontal, 18 * k).padding(.vertical, 10 * k)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(player == .player1 ? "setupStatusP1" : "setupStatusP2")
    }
}

#Preview(traits: .landscapeLeft) {
    CalibrationStageView(onBack: {}) { EmptyView() }
}
