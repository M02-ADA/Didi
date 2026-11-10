//
//  LaserHeistFlowView.swift
//  Sedactive
//

import SwiftUI

/// The screens of the LaserHeist journey, in the order of the Sketch
/// "Hi-Fi Revisi 6 NOV" rows: Home, Game Set Up (two "Put your iPad on the
/// Floor" steps, then "stand here"), then the round. The round's countdown,
/// results and Play Again live inside `PlayView`, with the session.
enum LaserHeistRoute: Equatable {
    case home
    case setup(PlayerSetupView.Step)
    case calibration
    /// A round; a new identity each time the players arrive from calibration.
    case play(round: UUID)
}

/// Navigation state only: no session, clock, score or calibration state lives
/// here. Each transition applies only from the screen it belongs to, so a late
/// or repeated action (a double tap, a calibration finishing after Back) can't
/// move the players somewhere else.
struct LaserHeistNavigation: Equatable {
    private(set) var route: LaserHeistRoute = .home

    /// Home › START MISSION!
    mutating func startMission() {
        guard route == .home else { return }
        route = .setup(.holdIPad)
    }

    /// The check button on a Set Up step.
    mutating func next() {
        guard case .setup(let step) = route else { return }
        switch step {
        case .holdIPad: route = .setup(.standIPadOnFloor)
        case .standIPadOnFloor: route = .calibration
        }
    }

    /// The back arrow on the Set Up and calibration screens. A round has no
    /// back: it ends through Results or the pause menu.
    mutating func back() {
        switch route {
        case .setup(.holdIPad): route = .home
        case .setup(.standIPadOnFloor): route = .setup(.holdIPad)
        case .calibration: route = .setup(.standIPadOnFloor)
        case .home, .play: break
        }
    }

    /// Calibration is complete (the calibration step's own result): start a round.
    mutating func startRound() {
        guard route == .calibration else { return }
        route = .play(round: UUID())
    }

    /// Back to Home or Leave Game, from a round.
    mutating func returnHome() {
        guard case .play = route else { return }
        route = .home
    }
}

/// Hosts the LaserHeist journey; the app's entry point (`RootView`). Live
/// sources reach the round through `play`, for example
/// `LaserHeistFlowView { exit in PlayView(avatarSource: …, onExit: exit) }`.
struct LaserHeistFlowView<Play: View>: View {
    /// PENDING Edo + Jevon: without it the calibration screen waits (Debug
    /// offers a labelled skip to the replay round).
    var calibration: LaserHeistCalibrationStep?
    /// PENDING: no best score is recorded yet; Home leaves the line out.
    var bestScore: Int?
    /// Builds the round; its argument returns the players to Home.
    @ViewBuilder var play: (_ returnHome: @escaping () -> Void) -> Play

    @State private var navigation = LaserHeistNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch navigation.route {
            case .home:
                HomeView(bestScore: bestScore) { navigation.startMission() }
                    .transition(.opacity)
            case .setup(let step):
                PlayerSetupView(step: step, onBack: { navigation.back() }, onNext: { navigation.next() })
                    .id(step)
                    .transition(.opacity)
            case .calibration:
                calibrationView
                    .transition(.opacity)
            case .play(let round):
                play { navigation.returnHome() }
                    .id(round)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: navigation.route)
        // One quiet tap per screen change; the menus share the music's base
        // layer, and a round adds its drive layer when it starts.
        .onAppear { AudioService.shared.setMusic(.menu) }
        .onChange(of: navigation.route) { _, route in
            AudioService.shared.play(.uiTap)
            if case .play = route { return }
            AudioService.shared.setMusic(.menu)
        }
        .background(LaserHeistDesign.night)
        .preferredColorScheme(.dark)
    }

    private var calibrationView: some View {
        #if DEBUG
        CalibrationView(step: calibration, onBack: { navigation.back() }, onCalibrated: { navigation.startRound() },
                        debugSkip: { navigation.startRound() })
        #else
        CalibrationView(step: calibration, onBack: { navigation.back() }, onCalibrated: { navigation.startRound() })
        #endif
    }
}

extension LaserHeistFlowView where Play == PlayView {
    /// The journey around the current `PlayView` round.
    init(calibration: LaserHeistCalibrationStep? = nil, bestScore: Int? = nil) {
        self.init(calibration: calibration, bestScore: bestScore) { returnHome in
            PlayView(onExit: returnHome)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    LaserHeistFlowView()
}
