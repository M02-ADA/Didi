//
//  GameplayHUD.swift
//  Sedactive
//

import SwiftUI

/// What the gameplay HUD shows, read from Jevon's authoritative game state,
/// events and round configuration (TEAM_ALIGNMENT §B). Kevin owns this
/// presentation (`PlayView`'s HUD); it keeps no clock, score or health of its
/// own and decides nothing.
///
/// Layout measurements come from Sketch "Hi-Fi Revisi 30 OCT" (Game 1,
/// Opening the Door, Diamond Time; 1210 × 834 pt artboards) and the
/// `hud gameplay` hand-off assets.
struct GameplayHUDModel: Equatable {
    enum Banner: Equatable {
        case none
        /// Opening the Door: a vault is waiting for both players' buttons.
        case pressButtons
        /// Diamond Time.
        case retrieveDiamonds
    }

    var health: Int
    var maxHealth: Int
    var score: Int
    /// Vaults in the round (`missionTarget`) and opened so far (`missionProgress`).
    var checkpoints: Int
    var vaultsOpened: Int
    /// Right edge of the progress fill, as a fraction of the track image's width.
    var fillEnd: Double
    /// Whether the round has reached its diamond (Diamond Time or after it).
    var diamondReached: Bool
    var banner: Banner
    /// Whole seconds of Diamond Time left: the authoritative phase-change time
    /// plus the configured duration, against game time. `nil` outside Diamond Time.
    var diamondSecondsLeft: Int?
    /// Diamonds collected, or `nil` with no source (production until J05).
    var diamondsCollected: Int?
    /// The diamond count comes from the Debug fixture (labelled on screen).
    var diamondsAreFixture: Bool

    // Track geometry, measured on the Sketch progress group (fractions of the 675 pt track).
    static let fillStart = 0.049
    static let fillFull = 0.96
    static let firstCheckpoint = 0.197
    static let lastCheckpoint = 0.837
    static let diamondPosition = 0.928

    /// Checkpoint centres along the track: Sketch spacing for five vaults,
    /// spread evenly over the same span for any other count.
    static func checkpointPositions(count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [(firstCheckpoint + lastCheckpoint) / 2] : [] }
        return (0..<count).map { firstCheckpoint + (lastCheckpoint - firstCheckpoint) * Double($0) / Double(count - 1) }
    }

    /// - Parameters:
    ///   - activityDuration: the round's planned activity length (seconds of game
    ///     time), for the continuous part of the progress fill.
    ///   - diamondsCollected: J05's committed count when it exists; until then `nil`.
    init(state: LaserGameState?, events: [GameEvent], configuration: LaserRoundConfiguration,
         activityDuration: Double, diamondsCollected: Int? = nil, diamondsAreFixture: Bool = false) {
        maxHealth = configuration.initialTeamHealth
        health = state?.teamHealth ?? configuration.initialTeamHealth
        score = state?.teamScore ?? 0
        checkpoints = max(0, state?.missionTarget ?? configuration.missionGateTarget)
        vaultsOpened = min(checkpoints, state?.missionProgress ?? 0)
        self.diamondsCollected = diamondsCollected
        self.diamondsAreFixture = diamondsAreFixture
        guard let state else {
            fillEnd = Self.fillStart
            diamondReached = false
            banner = .none
            diamondSecondsLeft = nil
            return
        }
        let dots = Self.checkpointPositions(count: checkpoints)
        let inDiamondTime = state.phase == .diamondTime
        let reachedDiamond = inDiamondTime || (checkpoints > 0 && vaultsOpened == checkpoints)
        diamondReached = reachedDiamond
        // The fill moves with activity time but never passes a vault not yet
        // opened, and sits on the vault being attempted while its door is shut.
        if reachedDiamond {
            fillEnd = Self.fillFull
        } else if state.phase == .vault, state.vault?.opened != true, vaultsOpened < dots.count {
            fillEnd = dots[vaultsOpened]
        } else {
            let share = activityDuration > 0 ? min(1, max(0, state.activityProgress / activityDuration)) : 0
            let continuous = Self.fillStart + share * (Self.fillFull - Self.fillStart)
            let floor = vaultsOpened > 0 ? dots[vaultsOpened - 1] : Self.fillStart
            let ceiling = vaultsOpened < dots.count ? dots[vaultsOpened] - 0.02 : Self.fillFull
            fillEnd = min(max(continuous, floor), max(floor, ceiling))
        }
        switch state.phase {
        case .vault where state.vault?.opened != true: banner = .pressButtons
        case .diamondTime: banner = .retrieveDiamonds
        default: banner = .none
        }
        if inDiamondTime, let start = events.last(where: {
            $0.sessionGeneration == state.sessionGeneration && $0.kind == .phaseChanged(.diamondTime)
        })?.gameTime {
            let left = start + configuration.diamondTimeDuration - state.gameTime
            diamondSecondsLeft = max(0, Int(left.rounded(.up)))
        } else {
            diamondSecondsLeft = nil
        }
    }
}

/// The in-round HUD (Sketch "Hi-Fi Revisi 30 OCT"): team hearts, round
/// progress with a checkpoint per vault and the diamond, and pause, along the
/// top; the phase title below it. Adapted for the 3D mascots: everything sits
/// above their heads (the mascots stand from about 28 % of the screen height
/// down), the team score sits under the hearts instead of over the corridor,
/// and the DUCK/JUMP cue stays the 3D one (`LaserFeedback`), so there is one cue.
struct GameplayHUD: View {
    let model: GameplayHUDModel
    /// The session's player intents; the HUD offers only those it is given.
    let actions: GameplayHUDActions
    #if DEBUG
    /// `-hudPauseMenu` opens the menu at launch, for reviewing its layout (Debug
    /// only). Without a session pause it is a labelled preview: the round runs on.
    @State private var menuShown = GameplayHUDActions.previewsPauseMenu
    #else
    @State private var menuShown = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // Sketch artboard: 1210 × 834 pt (11-inch iPad landscape).
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            ZStack(alignment: .top) {
                LinearGradient(colors: [Self.navy.opacity(0.75), Self.navy.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 159 * k)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                topBar(k)
                    .padding(.horizontal, 33 * k)
                    .padding(.top, 57 * k)
                // The Sketch title line (y 159 pt), raised slightly so the title and
                // its chip end above the mascots' heads (about y 255 pt).
                banner(k)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 136 * k)
                if menuShown { pauseMenu(k) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.banner)
    }

    // MARK: - Top bar

    private func topBar(_ k: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 55 * k) {
            VStack(alignment: .leading, spacing: 10 * k) {
                hearts(k)
                scoreChip(k)
            }
            progress(k)
            // Without the session's pause (Jevon), pausing is not offered: the button
            // keeps its Sketch place but reads as unavailable, so nobody expects the
            // round to stop while lasers keep coming.
            Button {
                actions.pause?()
                menuShown = true
            } label: {
                Image("LaserHeistHUD/pause").resizable().frame(width: 82 * k, height: 63 * k)
                    .saturation(actions.canPause ? 1 : 0)
                    .opacity(actions.canPause ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!actions.canPause)
            .accessibilityLabel(actions.canPause ? "Pause" : "Pause unavailable")
            .accessibilityIdentifier("pauseMenu")
        }
    }

    private func hearts(_ k: CGFloat) -> some View {
        let size = CGSize(width: 267 * k, height: 64 * k)
        return Image("LaserHeistHUD/health-panel")
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                ForEach(0..<model.maxHealth, id: \.self) { index in
                    if index < model.health {
                        Image("LaserHeistHUD/heart")
                            .resizable()
                            .frame(width: 27 * k, height: 26 * k)
                            // Sketch heart sockets: 41 pt apart from x 51.5, centred at y 33.
                            .position(x: (51.5 + 41 * CGFloat(index)) * k, y: 33 * k)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                    }
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: model.health)
            .accessibilityElement()
            .accessibilityLabel("Team health \(model.health) of \(model.maxHealth)")
    }

    private func scoreChip(_ k: CGFloat) -> some View {
        HStack(spacing: 8 * k) {
            Image(systemName: "star.fill")
                .foregroundStyle(Self.sun)
            Text(model.score, format: .number)
                .contentTransition(.numericText(value: Double(model.score)))
                .monospacedDigit()
        }
        .font(.system(size: 24 * k, weight: .black, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 16 * k)
        .frame(height: 40 * k)
        .background(Self.navy, in: Capsule())
        .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 4 * k))
        .animation(reduceMotion ? nil : .snappy, value: model.score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Team score \(model.score)")
    }

    private func progress(_ k: CGFloat) -> some View {
        let height = 63 * k
        return GeometryReader { track in
            let width = track.size.width
            let dot = 24.5 * k
            ZStack(alignment: .topLeading) {
                Image("LaserHeistHUD/progress-track")
                    .resizable(capInsets: EdgeInsets(top: 0, leading: 98, bottom: 0, trailing: 98), resizingMode: .stretch)
                let start = GameplayHUDModel.fillStart * width
                let end = max(model.fillEnd * width, start + 32 * k)
                Capsule()
                    .fill(LinearGradient(colors: [Self.fillTop, Self.fillBottom], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 4 * k, y: 4 * k)
                    .frame(width: end - start, height: 32 * k)
                    .offset(x: start, y: 15 * k)
                ForEach(Array(GameplayHUDModel.checkpointPositions(count: model.checkpoints).enumerated()), id: \.offset) { index, x in
                    Image("LaserHeistHUD/checkpoint")
                        .resizable()
                        .frame(width: dot, height: dot * 130 / 123)
                        .position(x: x * width, y: height / 2)
                        .opacity(index < model.vaultsOpened || x <= model.fillEnd ? 1 : 0.85)
                }
                Image("LaserHeistHUD/progress-diamond")
                    .resizable()
                    .frame(width: 29 * k, height: 26 * k)
                    .scaleEffect(model.diamondReached && !reduceMotion ? 1.15 : 1)
                    .position(x: GameplayHUDModel.diamondPosition * width, y: height / 2)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.fillEnd)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.4), value: model.diamondReached)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Vaults opened \(model.vaultsOpened) of \(model.checkpoints)")
        .accessibilityValue(model.diamondReached ? "Diamond reached" : "")
    }

    // MARK: - Phase title

    @ViewBuilder
    private func banner(_ k: CGFloat) -> some View {
        switch model.banner {
        case .none:
            EmptyView()
        case .pressButtons:
            VStack(spacing: 2 * k) {
                Text("PRESS THE BUTTONS").font(.system(size: 52.7 * k, weight: .black, design: .rounded))
                Text("TO OPEN THE DOOR").font(.system(size: 18.7 * k, weight: .black, design: .rounded))
            }
            .modifier(SketchTitle(k: k))
            .transition(titleTransition)
            .accessibilityElement(children: .combine)
        case .retrieveDiamonds:
            VStack(spacing: 8 * k) {
                // One line (the Sketch wraps to two), so the title stays above the mascots' heads.
                Text("RETRIEVE THE DIAMONDS").font(.system(size: 44 * k, weight: .black, design: .rounded))
                    .modifier(SketchTitle(k: k))
                diamondChip(k)
            }
            .transition(titleTransition)
            .accessibilityElement(children: .combine)
        }
    }

    private func diamondChip(_ k: CGFloat) -> some View {
        HStack(spacing: 12 * k) {
            if let collected = model.diamondsCollected {
                HStack(spacing: 6 * k) {
                    Image("LaserHeistHUD/progress-diamond").resizable().frame(width: 29 * k, height: 26 * k)
                    Text("\(collected)").monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(collected) diamonds")
            }
            if let seconds = model.diamondSecondsLeft {
                HStack(spacing: 6 * k) {
                    Image(systemName: "timer")
                    Text("\(seconds)s").monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(seconds) seconds left")
            }
            if model.diamondsAreFixture {
                Text("FIXTURE")
                    .font(.system(size: 13 * k, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 6 * k)
                    .padding(.vertical, 2 * k)
                    .background(Self.sun, in: Capsule())
                    .foregroundStyle(Self.ink)
                    .accessibilityLabel("Synthetic diamond fixture")
            }
        }
        .font(.system(size: 24 * k, weight: .black, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 16 * k)
        .frame(height: 40 * k)
        .background(Self.navy, in: Capsule())
        .overlay(Capsule().strokeBorder(Self.rim, lineWidth: 4 * k))
        .animation(reduceMotion ? nil : .snappy, value: model.diamondSecondsLeft)
    }

    private var titleTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity)
    }

    // MARK: - Pause menu

    /// Sketch Game 1 pause state, shown only once the session has paused the
    /// round (`actions.pause`); Resume asks the session to resume and Leave Game
    /// ends the round. A Debug preview without a session pause says so.
    private func pauseMenu(_ k: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.66).ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 38 * k) {
                if !actions.canPause {
                    Text("PREVIEW · the round keeps running (session pause pending)")
                        .font(.system(size: 16 * k, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10 * k)
                        .padding(.vertical, 4 * k)
                        .background(Self.sun, in: Capsule())
                        .foregroundStyle(Self.ink)
                }
                menuButton("Resume", fill: Self.sun, k: k) {
                    actions.resume?()
                    menuShown = false
                }
                .accessibilityIdentifier("resume")
                if let leave = actions.leave {
                    menuButton("Leave Game", fill: Color(white: 0.933), k: k) {
                        menuShown = false
                        leave()
                    }
                    .accessibilityIdentifier("leaveGame")
                }
            }
        }
        .transition(.opacity)
    }

    private func menuButton(_ title: String, fill: Color, k: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 44.8 * k, weight: .bold, design: .rounded))
                .foregroundStyle(Self.ink)
                .frame(width: 564 * k, height: 92 * k)
                .background(fill, in: Capsule())
                .background(Self.buttonShadow, in: Capsule().offset(y: 12 * k))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Palette (Sketch)

    static let navy = Color(red: 0x1E / 255, green: 0x1A / 255, blue: 0x47 / 255)
    static let rim = Color(red: 0x5B / 255, green: 0x51 / 255, blue: 0x90 / 255)
    static let sun = Color(red: 0xFF / 255, green: 0xC8 / 255, blue: 0x3A / 255)
    static let ink = Color(red: 0x16 / 255, green: 0x12 / 255, blue: 0x3A / 255)
    static let buttonShadow = Color(red: 0xB9 / 255, green: 0x84 / 255, blue: 0x00 / 255)
    static let fillTop = Color(red: 0xEA / 255, green: 0xA8 / 255, blue: 0x52 / 255)
    static let fillBottom = Color(red: 0xE9 / 255, green: 0x6D / 255, blue: 0x2F / 255)
}

/// The player intents the HUD may emit, supplied by the host from Jevon's
/// session. `nil` means the session has no such action yet, and the HUD does
/// not offer it: no second clock, pause state or timer lives here.
struct GameplayHUDActions {
    /// Pause and resume the round through the session (its `GameClock`).
    /// PENDING Jevon: the session exposes neither yet.
    var pause: (() -> Void)?
    var resume: (() -> Void)?
    /// End the round (the session's existing stop).
    var leave: (() -> Void)?

    /// Pausing is offered only when the session can both pause and resume.
    var canPause: Bool { pause != nil && resume != nil }

    #if DEBUG
    static var previewsPauseMenu: Bool { ProcessInfo.processInfo.arguments.contains("-hudPauseMenu") }
    #endif
}

/// Sketch title type: white SF Pro Rounded Black with a hard drop shadow
/// (3, 5) at 91 % black and a soft one (0, 4, blur 8) at 25 %.
private struct SketchTitle: ViewModifier {
    let k: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.91), radius: 0, x: 3 * k, y: 5 * k)
            .shadow(color: .black.opacity(0.25), radius: 4 * k, x: 0, y: 4 * k)
    }
}
