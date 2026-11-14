//
//  CalibrationStageView.swift
//  Sedactive
//

import SwiftUI

/// The calibration stage (Sketch "Hi-Fi Revisi 6 NOV" › Stack 5 Game Set Up: Home Copy 19
/// "stand inside the box to start", Home Copy 42 "stand still, don’t move"): the camera image and
/// one standing box per player, P1 left and P2 right, laid out on the 1210 × 834 artboard.
///
/// - The camera underlays the header. Landscape fill preserves the full source height;
///   other viewports fall back to the whole frame. The boxes are Sketch's exact
///   rectangles (422 × 601 pt at x 149 and 668, y 177, radius 59) scaled with the artboard; on every
///   supported landscape iPad they lie inside the camera image, each within its player's half, so
///   standing inside a box always means standing where the tracker looks for that player.
/// - Each box is a white dashed outline until its player is calibrated; a yellow stroke traces it
///   clockwise from the top centre as that player's REAL calibration evidence grows
///   (`CalibrationGuideBox`), and closes when calibration is accepted.
///
/// Presentation only. Binding, calibration and readiness are the live session's; its controls
/// sit in `panel`. Nothing here decides that a player is placed or calibrated, and the boxes never
/// change tracking coordinates.
struct CalibrationStageView<Panel: View>: View {
    /// The camera image as the camera delivers it (unmirrored), e.g.
    /// `CalibrationCameraPreview` on `CameraPipeline.previewSession`; mirrored
    /// here for display.
    var cameraPreview: AnyView?
    /// The capture's width ÷ height (1280 × 720 → 16:9).
    var cameraAspect: CGFloat = 16 / 9
    /// Automatic setup: each player's status, shown by their box.
    var playerStatus: [PlayerID: LaserSetupPlayerStatus] = [:]
    /// DEBUG Solo Test: one centred box for P1 instead of two.
    var solo = false
    let onBack: () -> Void
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        GeometryReader { geo in
            let k = CalibrationStageLayout.scale(for: geo.size)
            let image = CalibrationStageLayout.previewRect(in: geo.size, aspect: cameraAspect)
            let fills = CalibrationStageLayout.canFill(in: geo.size, aspect: cameraAspect)
            let origin = CalibrationStageLayout.artboardOrigin(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Non-camera fallback for viewports that would crop vertically. Never add
                // another preview layer/session merely to fill a decorative background.
                LinearGradient(colors: [Color(sketch: 0x39334F), Color(sketch: 0x161436)],
                               startPoint: .top, endPoint: .bottom)
                // Mirrored for display only (CP2 rule): players see themselves
                // as in a mirror, so P1 on the left stands in the left box.
                if let cameraPreview {
                    cameraPreview
                        .environment(\.calibrationPreviewFill, fills)
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: image.width, height: image.height)
                        .clipped()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Camera preview")
                        .accessibilityIdentifier("calibrationCameraSurface")
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
                    .frame(width: geo.size.width, height: geo.size.height * 0.32)
                    .allowsHitTesting(false)
                ForEach(solo ? [PlayerID.player1] : PlayerID.allCases, id: \.self) { player in
                    let box = CalibrationStageLayout.boxRect(player, solo: solo, in: geo.size)
                    CalibrationGuideBox(player: player, status: playerStatus[player], k: k,
                                        sweepOffset: player == .player2 ? 0.45 : 0)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                }
                // The title band: the headline centred on the screen, as in Sketch.
                Group {
                    if Panel.self == EmptyView.self {
                        CalibrationStageHeadline(text: LaserAutomaticSetupCopy.placementHeadline, detail: nil)
                    } else {
                        panel()
                    }
                }
                .environment(\.calibrationStageScale, k)
                // From the Sketch title's top to just above the boxes (y 55 → 173 on the artboard).
                .frame(width: max(0, geo.size.width - 2 * (CalibrationStageLayout.backButtonOrigin.x + 80) * k),
                       height: CalibrationStageLayout.panelHeight * k, alignment: .top)
                .offset(x: (CalibrationStageLayout.backButtonOrigin.x + 80) * k, y: origin.y + CalibrationStageLayout.titleTop * k)
                SketchBackButton(k: k, action: onBack)
                    .offset(x: origin.x + CalibrationStageLayout.backButtonOrigin.x * k, y: origin.y + CalibrationStageLayout.backButtonOrigin.y * k)
            }
        }
        .ignoresSafeArea()
    }

    /// Said plainly when there is no camera image, so the empty boxes are not
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
}

/// The calibration stage's geometry (Sketch Home Copy 19/42, artboard points → screen).
enum CalibrationStageLayout {
    /// Sketch Home Copy 19/42, artboard points.
    static let boxSize = CGSize(width: 422, height: 601)
    static let boxTop: CGFloat = 177
    static let boxX: [PlayerID: CGFloat] = [.player1: 149, .player2: 668]
    static let backButtonOrigin = CGPoint(x: 51, y: 63)
    static let titleTop: CGFloat = 55
    static let panelHeight: CGFloat = 118

    /// The artboard's scale on this screen (aspect fit) and its top-left corner.
    static func scale(for size: CGSize) -> CGFloat {
        min(size.width / LaserHeistDesign.artboard.width, size.height / LaserHeistDesign.artboard.height)
    }

    static func artboardOrigin(in size: CGSize) -> CGPoint {
        let k = scale(for: size)
        return CGPoint(x: (size.width - LaserHeistDesign.artboard.width * k) / 2,
                       y: (size.height - LaserHeistDesign.artboard.height * k) / 2)
    }

    /// A player's box on screen: the Sketch rectangle scaled with the artboard (Solo: centred).
    static func boxRect(_ player: PlayerID, solo: Bool, in size: CGSize) -> CGRect {
        let k = scale(for: size), origin = artboardOrigin(in: size)
        let x = solo ? (LaserHeistDesign.artboard.width - boxSize.width) / 2 : boxX[player, default: 149]
        return CGRect(x: origin.x + x * k, y: origin.y + boxTop * k, width: boxSize.width * k, height: boxSize.height * k)
    }

    /// Aspect-fill only when it preserves the full source height and both guide areas
    /// remain representable. Otherwise show the whole source over a decorative background.
    static func canFill(in size: CGSize, aspect: CGFloat) -> Bool {
        guard size.width > 0, size.height > 0, aspect.isFinite, aspect > 0,
              aspect >= size.width / size.height else { return false }
        let viewport = CGRect(origin: .zero, size: size)
        return PlayerID.allCases.allSatisfy { player in
            let box = boxRect(player, solo: false, in: size)
            let source = sourceRect(for: box, in: size, aspect: aspect, fill: true)
            return viewport.contains(box) && CGRect(x: 0, y: 0, width: 1, height: 1).contains(source)
                && (player == .player1 ? source.minX >= 0.5 : source.maxX <= 0.5)
        }
    }

    static func contentRect(in size: CGSize, aspect: CGFloat, fill: Bool) -> CGRect {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        let width = fill ? max(size.width, size.height * aspect) : min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func previewRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        canFill(in: size, aspect: aspect) ? CGRect(origin: .zero, size: size)
            : contentRect(in: size, aspect: aspect, fill: false)
    }

    /// Inverse display transform, normalized to the original UNMIRRORED source.
    /// The preview is mirrored exactly once by CalibrationStageView.
    static func sourceRect(for rect: CGRect, in size: CGSize, aspect: CGFloat, fill: Bool) -> CGRect {
        let content = contentRect(in: size, aspect: aspect, fill: fill)
        return CGRect(x: 1 - (rect.maxX - content.minX) / content.width,
                      y: (rect.minY - content.minY) / content.height,
                      width: rect.width / content.width, height: rect.height / content.height)
    }

}

/// The calibration stage's artboard scale, for the panel's Sketch-sized title.
extension EnvironmentValues {
    @Entry var calibrationStageScale: CGFloat = 1
    @Entry var calibrationPreviewFill = false
}

/// Sketch title: SF Pro Rounded Bold 57 pt, white, centred (Home Copy 19 and 42; measured against
/// the Sketch render: both strings' widths and ink coverage match). The change between the two
/// headlines crossfades; an optional short line sits underneath.
struct CalibrationStageHeadline: View {
    let text: String
    let detail: String?
    @Environment(\.calibrationStageScale) private var k
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6 * k) {
            Text(text)
                .font(.system(size: 57 * k, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.25), radius: 6 * k, y: 2 * k)
                .id(text)
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("setupPhase")
            if let detail {
                Text(detail)
                    .font(.system(size: 21 * k, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .transition(.opacity)
                    .accessibilityIdentifier("setupInstruction")
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.35), value: text)
        .animation(.easeInOut(duration: 0.25), value: detail)
    }
}

/// One player's standing box (Sketch Home Copy 19/42), driven by the player's REAL calibration
/// status only:
/// - white dashed outline (5 pt, dashes 30/10, radius 59) until calibrated;
/// - a yellow stroke (#F1C03A, 11 pt, round caps, soft drop shadow) traced clockwise from the
///   top centre, `borderProgress` of the way round, eased between the 0.25 s samples so it grows
///   smoothly; it closes only when calibration is accepted;
/// - the Sketch scan band (#6A6CC1, fading in toward a #BDCAFF glowing edge) sweeping down while
///   the box is in use and not complete (none under Reduce Motion).
struct CalibrationGuideBox: View {
    let player: PlayerID
    let status: LaserSetupPlayerStatus?
    let k: CGFloat
    /// Offsets the two boxes' sweeps (Sketch shows them at different heights).
    var sweepOffset: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let yellow = Color(sketch: 0xF1C03A)
    static let cornerRadius: CGFloat = 59
    static let dashedWidth: CGFloat = 5
    static let progressWidth: CGFloat = 11
    /// A full window of stable samples is not yet an accepted calibration (both players are
    /// accepted together, then checked): it traces to here, and only acceptance closes the box.
    static let evidenceShare = 0.92

    /// How much of the outline is yellow for this status (0…1).
    static func borderProgress(_ status: LaserSetupPlayerStatus?) -> Double {
        switch status {
        case .ready: 1
        case .calibrating(let progress, _): evidenceShare * min(1, max(0, progress.isFinite ? progress : 0))
        case .searching, .linked, nil: 0
        }
    }

    /// Whether the scan band sweeps: the player is being found or measured, not done.
    static func scans(_ status: LaserSetupPlayerStatus?) -> Bool {
        switch status {
        case .searching, .linked, .calibrating: true
        case .ready, nil: false
        }
    }

    var body: some View {
        let radius = Self.cornerRadius * k
        let progress = Self.borderProgress(status)
        let done = status == .ready
        ZStack {
            if Self.scans(status), !reduceMotion {
                CalibrationScanSweep(k: k, offset: sweepOffset)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                    .transition(.opacity)
            }
            RoundedRectangle(cornerRadius: radius, style: .circular)
                .strokeBorder(.white, style: StrokeStyle(lineWidth: Self.dashedWidth * k, lineCap: .butt,
                                                         dash: [30 * k, 10 * k]))
                .opacity(done ? 0 : 1)
            // The progress stroke sits inside the box like the completed border, so 100 % is the
            // finished look exactly.
            let inset = Self.progressWidth * k / 2
            CalibrationTracePath(cornerRadius: max(0, radius - inset))
                .inset(by: inset)
                .trim(from: 0, to: progress)
                .stroke(Self.yellow, style: StrokeStyle(lineWidth: Self.progressWidth * k, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.25), radius: 4 * k, y: 4 * k)
                .opacity(progress > 0.001 ? 1 : 0)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
        .transaction { if progress == 0 { $0.animation = nil; $0.disablesAnimations = true } }
        .animation(.easeInOut(duration: 0.3), value: done)
        .animation(.easeInOut(duration: 0.3), value: Self.scans(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player == .player1 ? "Player 1 standing area" : "Player 2 standing area")
        .accessibilityValue(Self.accessibilityValue(status))
        .accessibilityIdentifier(player == .player1 ? "setupStatusP1" : "setupStatusP2")
    }

    static func accessibilityValue(_ status: LaserSetupPlayerStatus?) -> String {
        switch status {
        case .ready: "Calibrated"
        case .calibrating(let progress, _): "Measuring, \(Int((min(1, max(0, progress)) * 100).rounded())) percent"
        case .linked: "In place"
        case .searching, nil: "Waiting for a player"
        }
    }
}

/// A rounded rectangle traced clockwise from the middle of its top edge, so `trim(from: 0, to:)`
/// grows like a progress ring around the box (Sketch Home Copy 42: P1's yellow begins top centre).
struct CalibrationTracePath: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(cornerRadius, r.width / 2, r.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addArc(center: CGPoint(x: r.maxX - c, y: r.minY + c), radius: c, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addArc(center: CGPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addArc(center: CGPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.addArc(center: CGPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> CalibrationTracePath {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The Sketch scan band: from the box top down to a glowing edge (#6A6CC1 rising from about 10 %
/// to 90 % opacity, measured on the Sketch render; edge #BDCAFF, 5 pt, white glow), sweeping down
/// the box and starting again. Cosmetic: it says "looking", never how far calibration is.
struct CalibrationScanSweep: View {
    let k: CGFloat
    var offset: Double = 0
    static let period = 2.6

    /// The band's share of the box height at `time` (eased down, then a quick fade at the bottom).
    static func sweep(at time: TimeInterval, offset: Double) -> (height: Double, opacity: Double) {
        let phase = ((time / period + offset).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let eased = phase * phase * (3 - 2 * phase)
        let opacity = phase < 0.85 ? 1 : max(0, 1 - (phase - 0.85) / 0.15)
        return (eased, opacity)
    }

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let s = Self.sweep(at: context.date.timeIntervalSinceReferenceDate, offset: offset)
                let height = geo.size.height * s.height
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color(sketch: 0x6A6CC1, opacity: 0.08), Color(sketch: 0x6A6CC1, opacity: 0.88)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: height)
                    Rectangle()
                        .fill(Color(sketch: 0xBDCAFF))
                        .frame(height: 5 * k)
                        .shadow(color: .white, radius: 8 * k)
                    Spacer(minLength: 0)
                }
                .opacity(s.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview(traits: .landscapeLeft) {
    CalibrationStageView(playerStatus: [.player1: .calibrating(progress: 0.5, issue: nil), .player2: .ready], onBack: {}) { EmptyView() }
}
