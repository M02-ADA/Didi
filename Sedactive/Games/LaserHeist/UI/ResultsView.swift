//
//  ResultsView.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import SwiftUI

/// End Screen (Sketch "Hi-Fi Revisi 6 NOV" › End Screen). A completed round
/// first shows the celebration ("Home Copy 25": the mascot and three glowing
/// diamonds) and then the score ("Home Copy 35"); any other outcome goes
/// straight to the score with a title that says how the round ended. The score
/// is the session's `RoundSummary.teamScore`; nothing is computed here.
struct ResultsView: View {
    let summary: RoundSummary
    let onRetry: () -> Void
    /// Back to Home. `nil` where the host has no Home to return to, and then
    /// the button is left out instead of doing nothing.
    var onHome: (() -> Void)?

    @State private var celebrating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the celebration shows before the score. Presentation only;
    /// Sketch gives no duration. A tap skips it.
    static let celebrationDuration: Duration = .seconds(2)

    init(summary: RoundSummary, onRetry: @escaping () -> Void, onHome: (() -> Void)? = nil) {
        self.summary = summary
        self.onRetry = onRetry
        self.onHome = onHome
        _celebrating = State(initialValue: summary.outcome == .completed)
    }

    var body: some View {
        ZStack {
            if celebrating {
                ResultsCelebration()
                    .transition(.opacity)
                    .onTapGesture { finishCelebration() }
                    .accessibilityAction(named: "Show score") { finishCelebration() }
            } else {
                scoreCard
                    .transition(.opacity)
            }
        }
        .task {
            // The round's music fades; the outcome's sting lands with the
            // mascot's entrance (a completed round) or at once (a lost one).
            AudioService.shared.setMusic(nil, fade: 0.6)
            let lead: Duration = celebrating ? .seconds(ResultsCelebration.mascotDelay) : .zero
            if let sting = Self.sting(for: summary.outcome) {
                try? await Task.sleep(for: lead)
                guard !Task.isCancelled else { return }
                AudioService.shared.play(sting)
            }
            guard celebrating else { return }
            try? await Task.sleep(for: Self.celebrationDuration - (Self.sting(for: summary.outcome) == nil ? .zero : lead))
            finishCelebration()
        }
    }

    /// The session's outcome, heard: a fanfare for a completed round, a light
    /// "aww" for a lost one, nothing for one ended early or interrupted.
    static func sting(for outcome: LaserRoundOutcome) -> SoundCue? {
        switch outcome {
        case .completed: .roundSuccess
        case .healthDepleted, .vaultFailed: .roundFailure
        case .aborted, .technicalInterruption: nil
        }
    }

    private func finishCelebration() {
        guard celebrating else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { celebrating = false }
    }

    private var scoreCard: some View {
        SketchArtboard {
            Image("LaserHeistUI/home-frame")
                .resizable()
                .scaledToFill()
                .sketchBackdrop()
        } content: { k in
            Image("LaserHeistUI/results-mascot-lemon")
                .resizable()
                .shadow(color: .black.opacity(0.25), radius: 6 * k, x: 0, y: 5 * k)
                .sketchFrame(x: -12, y: 556, width: 281, height: 366, k: k)
                .accessibilityHidden(true)
            Image("LaserHeistUI/results-mascot-tangerine")
                .resizable()
                .sketchFrame(x: 949, y: 531, width: 318, height: 383, k: k)
                .accessibilityHidden(true)

            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 43 * k, weight: .bold))
                .foregroundStyle(LaserHeistDesign.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 1210 * k, height: 51 * k)
                .offset(y: 169 * k)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("resultsTitle")

            scorePanel(k)
                .sketchFrame(x: 307, y: 239, width: 597, height: 328, k: k)

            HStack(spacing: 33 * k) {
                if let onHome {
                    Button(action: onHome) {
                        Label("Back to Home", systemImage: "house.fill")
                            .font(.system(size: 25 * k, weight: .bold, design: .rounded))
                            .foregroundStyle(LaserHeistDesign.cream)
                    }
                    .buttonStyle(GradientCapsuleButtonStyle(top: Color(sketch: 0x6561A4), bottom: Color(sketch: 0x4D4778),
                                                            edgeTop: Color(sketch: 0x948ECA), edgeBottom: Color(sketch: 0x3B3765),
                                                            edgeWidth: 2 * k, k: k))
                    .frame(width: 282 * k, height: 60 * k)
                    .accessibilityIdentifier("backToHome")
                }
                Button {
                    AudioService.shared.play(.uiTap)
                    onRetry()
                } label: {
                    Label("Play Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 25 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                }
                .buttonStyle(GradientCapsuleButtonStyle(top: Color(sketch: 0xEAA752), bottom: Color(sketch: 0xE97131),
                                                        edgeTop: Color(sketch: 0xFFF0E0), edgeBottom: Color(sketch: 0xEA7936),
                                                        edgeWidth: 2 * k, k: k))
                .frame(width: 282 * k, height: 60 * k)
                .accessibilityIdentifier("retryRound")
            }
            .labelStyle(SketchButtonLabelStyle(spacing: 6 * k))
            .frame(width: 1210 * k, height: 60 * k)
            .offset(y: 594 * k)
        }
    }

    /// "YOUR SCORE" and the score in the angled-corner panel (Sketch "Group").
    private func scorePanel(_ k: CGFloat) -> some View {
        let panel = ChamferedRectangle(chamfer: 26 * k)
        return ZStack(alignment: .top) {
            panel.fill(LaserHeistDesign.panel)
            panel.strokeBorder(LinearGradient(colors: [LaserHeistDesign.panelEdge, LaserHeistDesign.panel],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 6 * k)
            Text("YOUR SCORE")
                .font(.system(size: 24.4 * k, weight: .medium, design: .monospaced))
                .tracking(8.78 * k)
                .foregroundStyle(LaserHeistDesign.cream)
                .frame(height: 29 * k)
                .offset(x: 4.4 * k, y: 30 * k)
            Text(summary.teamScore, format: .number.grouping(.never))
                .font(.system(size: 263.2 * k, weight: .bold))
                .foregroundStyle(LaserHeistDesign.cream)
                .shadow(color: .black.opacity(0.37), radius: 0, x: 8 * k, y: 12 * k)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(width: 560 * k, height: 273 * k)
                .offset(y: 27 * k)
                .accessibilityIdentifier("teamScore")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your score")
        .accessibilityValue("\(summary.teamScore)")
    }

    private var title: String {
        switch summary.outcome {
        case .completed: "Great Job Agents!"
        case .healthDepleted: "Team health depleted"
        case .vaultFailed: "Vault timed out"
        case .aborted: "Round ended early"
        case .technicalInterruption: "Round interrupted"
        }
    }
}

/// The celebration before the score of a completed round (Sketch "Home Copy
/// 25"), revealed in sequence: the sunburst first, then the mascot springs in,
/// then the three diamonds pop in one after another, then everything settles
/// into a gentle idle (the mascot bobs and sways, the diamonds float).
/// Cosmetic only; it runs on the display clock and decides nothing. Reduce
/// Motion: one fade-in, no idle motion. Each presentation starts from the beginning.
struct ResultsCelebration: View {
    /// Entrance timing, within the provisional `ResultsView.celebrationDuration`:
    /// the empty background, then the mascot rising from below the screen, then
    /// the diamonds once it has landed, then the idle.
    static let mascotDelay = 0.15
    static let mascotRise = 0.75
    static let diamondDelay = 0.8
    static let diamondStagger = 0.1
    /// When the idle motion starts, ramping in over `idleRamp`.
    static let idleStart = 1.4
    static let idleRamp = 0.3

    /// The mascot's Sketch frame (artboard points).
    static let mascotFrame = CGRect(x: 418, y: 192, width: 374, height: 451)

    /// How far below its Sketch place the mascot starts, in screen points, so
    /// that it is entirely below the bottom edge of a `screen`-sized view: from
    /// its top edge on screen (the artboard is scaled to fit and centred) to the
    /// screen's bottom, plus a small margin.
    static func entranceOffset(screen: CGSize) -> CGFloat {
        let k = min(screen.width / LaserHeistDesign.artboard.width, screen.height / LaserHeistDesign.artboard.height)
        let artboardTop = (screen.height - LaserHeistDesign.artboard.height * k) / 2
        return screen.height - (artboardTop + mascotFrame.minY * k) + 12
    }

    /// Sketch frames and rotations (anticlockwise, degrees) of the three diamonds.
    private static let diamonds: [(x: CGFloat, y: CGFloat, width: CGFloat, rotation: Double)] = [
        (242, 216, 112, 18), (883, 370, 112, -20), (253, 557, 140, 9),
    ]

    @State private var mascotIn = false
    @State private var diamondsIn = [false, false, false]
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { screen in
            let rise = Self.entranceOffset(screen: screen.size)
            SketchArtboard {
                SunburstBackground()
            } content: { k in
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSince(start)
                    // The idle eases in after the entrances, so it never fights them.
                    let ramp = reduceMotion ? 0 : min(1, max(0, (t - Self.idleStart) / Self.idleRamp))
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.diamonds.indices, id: \.self) { index in
                            diamond(index, t: t, idle: ramp, k: k)
                        }
                        mascot(t: t, idle: ramp, rise: rise, k: k)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: reveal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mission complete")
        .accessibilityIdentifier("resultsCelebration")
    }

    private func reveal() {
        start = .now
        mascotIn = false
        diamondsIn = [false, false, false]
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                mascotIn = true
                diamondsIn = [true, true, true]
            }
            return
        }
        // Rises the whole way from below the screen and settles with a small overshoot.
        withAnimation(.spring(duration: Self.mascotRise, bounce: 0.28).delay(Self.mascotDelay)) { mascotIn = true }
        for index in diamondsIn.indices {
            withAnimation(.spring(duration: 0.45, bounce: 0.5).delay(Self.diamondDelay + Double(index) * Self.diamondStagger)) {
                diamondsIn[index] = true
            }
        }
    }

    /// Starts entirely below the screen (`rise` points down), travels up to its
    /// Sketch place at full size and opacity, then bobs and sways a little.
    /// Reduce Motion: a fade in place.
    private func mascot(t: Double, idle: Double, rise: CGFloat, k: CGFloat) -> some View {
        let bob = -sin(t * 2 * .pi / 0.9) * 7 * idle
        let sway = sin(t * 2 * .pi / 1.8) * 3 * idle
        let f = Self.mascotFrame
        return Image("LaserHeistUI/celebration-mascot")
            .resizable()
            .rotationEffect(.degrees(sway), anchor: .bottom)
            .offset(y: mascotIn ? bob * k : (reduceMotion ? 0 : rise))
            .opacity(reduceMotion && !mascotIn ? 0 : 1)
            .sketchFrame(x: f.minX, y: f.minY, width: f.width, height: f.height, k: k)
    }

    /// Pops in with a quarter-turn twist, then floats and tilts slightly, each
    /// diamond out of phase with the others. Soft white glow as in Sketch.
    private func diamond(_ index: Int, t: Double, idle: Double, k: CGFloat) -> some View {
        let d = Self.diamonds[index]
        let shown = diamondsIn[index]
        let phase = Double(index) * 2.1
        let float = sin(t * 2 * .pi / 1.6 + phase) * 6 * idle
        let tilt = sin(t * 2 * .pi / 2.2 + phase) * 4 * idle
        let twist = shown || reduceMotion ? 0.0 : -25
        return Image("LaserHeistUI/diamond")
            .resizable()
            .shadow(color: .white.opacity(0.69), radius: 40 * k)
            .shadow(color: .white.opacity(0.35), radius: 20 * k)
            .scaleEffect(shown ? 1 : (reduceMotion ? 1 : 0.3))
            .rotationEffect(.degrees(-d.rotation + twist + tilt))
            .offset(y: float * k)
            .opacity(shown ? 1 : 0)
            .sketchFrame(x: d.x, y: d.y, width: d.width, height: d.width * 95 / 112, k: k)
    }
}

/// An SF Symbol and title side by side, as the Sketch button labels set them.
private struct SketchButtonLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
