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
/// Layout measurements come from Sketch "Hi-Fi Revisi 6 NOV" (the game
/// artboards' HUD stack, 1210 × 834 pt) and the `hud gameplay` hand-off assets.
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

    // Track geometry, measured on the Sketch 6 NOV progress group (fractions of the 667 pt track).
    static let fillStart = 0.031
    static let fillFull = 0.955
    static let firstCheckpoint = 0.219
    static let lastCheckpoint = 0.862
    static let diamondPosition = 0.949

    /// The Sketch track always shows five checkpoints, one per vault of a full
    /// round (rules: five vaults, one after each activity minute).
    static let markerCount = 5

    enum MarkerState: Equatable {
        /// The fill has passed it.
        case completed
        /// The next checkpoint ahead of the fill (or the vault being attempted).
        case current
        case upcoming
    }

    /// The five track markers, read from the authoritative progress fill. With
    /// five vaults each marker is a vault; a round with another vault count
    /// (the one-vault replay slice) shows the same five as stages of its progress.
    var markerStates: [MarkerState] {
        var foundCurrent = false
        return Self.checkpointPositions(count: Self.markerCount).map { x in
            if diamondReached || x < fillEnd - 0.005 { return .completed }
            if foundCurrent { return .upcoming }
            foundCurrent = true
            return .current
        }
    }

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
    ///   - enteringFinalVault: the team is still entering the final vault (the session's
    ///     `finalVaultEntry`, on held game time): Diamond Time's title and seconds wait for it.
    init(state: LaserGameState?, events: [GameEvent], configuration: LaserRoundConfiguration,
         activityDuration: Double, diamondsCollected: Int? = nil, diamondsAreFixture: Bool = false,
         enteringFinalVault: Bool = false) {
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
        case .diamondTime: banner = enteringFinalVault ? .none : .retrieveDiamonds
        default: banner = .none
        }
        if inDiamondTime, !enteringFinalVault, let start = events.last(where: {
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
                    .padding(.top, 58 * k)
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

    /// The Sketch HUD stack: health, progress and pause at their artboard
    /// widths and gaps (268 · 34 · 667 · 36 · 85.5 pt), centred, so the three
    /// read as one row of the same parts.
    private func topBar(_ k: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10 * k) {
                hearts(k)
                scoreChip(k)
            }
            .frame(width: 268 * k, alignment: .leading)
            Spacer().frame(width: 33.9 * k)
            progress(k)
                .frame(width: 667 * k)
            Spacer().frame(width: 36 * k)
            // Without the session's pause (Jevon), pausing is not offered: the button
            // keeps its Sketch place and shape, and its bars dim, so nobody expects
            // the round to stop while lasers keep coming.
            Button {
                actions.pause?()
                menuShown = true
            } label: {
                ZStack {
                    HUDSurface(shape: RoundedRectangle(cornerRadius: 31 * k, style: .continuous), k: k)
                    HStack(spacing: 7 * k) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3 * k, style: .continuous)
                                .fill(Self.cream)
                                .frame(width: 9 * k, height: 30 * k)
                        }
                    }
                    .opacity(actions.canPause ? 1 : 0.4)
                }
                .frame(width: 85.5 * k, height: 66 * k)
            }
            .buttonStyle(.plain)
            .disabled(!actions.canPause)
            .accessibilityLabel(actions.canPause ? "Pause" : "Pause unavailable")
            .accessibilityIdentifier("pauseMenu")
        }
        .frame(maxWidth: .infinity)
    }

    /// Five heart sockets in the Sketch pill: a lost heart leaves a dark socket,
    /// so the team sees how much health is gone, not only what is left.
    private func hearts(_ k: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HUDSurface(shape: Capsule(), k: k)
            ForEach(0..<model.maxHealth, id: \.self) { index in
                // Sketch heart sockets: 41 pt apart from x 53, centred at y 33.
                let center = CGPoint(x: (53 + 41 * CGFloat(index)) * k, y: 33 * k)
                Image("LaserHeistHUD/heart")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(Self.socket)
                    .frame(width: 29 * k, height: 27 * k)
                    .position(center)
                if index < model.health {
                    Image("LaserHeistHUD/heart")
                        .resizable()
                        .frame(width: 29 * k, height: 27 * k)
                        .position(center)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                }
            }
        }
        .frame(width: 268 * k, height: 64 * k)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.3), value: model.health)
        .accessibilityElement()
        .accessibilityLabel("Team health \(model.health) of \(model.maxHealth)")
    }

    /// The team score in the same surface as the other HUD parts.
    private func scoreChip(_ k: CGFloat) -> some View {
        HStack(spacing: 8 * k) {
            Image(systemName: "star.fill")
                .foregroundStyle(Self.sun)
            Text(model.score, format: .number)
                .contentTransition(.numericText(value: Double(model.score)))
                .monospacedDigit()
        }
        .font(.system(size: 22 * k, weight: .black, design: .rounded))
        .foregroundStyle(Self.cream)
        .padding(.horizontal, 20 * k)
        .frame(height: 48 * k)
        .background(HUDSurface(shape: Capsule(), k: k))
        .animation(reduceMotion ? nil : .snappy, value: model.score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Team score \(model.score)")
    }

    /// The Sketch track: the shared surface, an 8 pt lavender rail from the
    /// fill to the diamond, the orange fill pill, five identical cream
    /// checkpoints (the fill shows what is done) and the diamond.
    private func progress(_ k: CGFloat) -> some View {
        let height = 65 * k
        return GeometryReader { track in
            let width = track.size.width
            let dot = 24 * k
            ZStack(alignment: .topLeading) {
                HUDSurface(shape: Capsule(), k: k)
                let start = GameplayHUDModel.fillStart * width
                let rail = GameplayHUDModel.diamondPosition * width
                Capsule()
                    .fill(LinearGradient(colors: [Self.railTop, Self.railBottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: rail - start, height: 8 * k)
                    .offset(x: start, y: height / 2 - 4 * k)
                let end = max(model.fillEnd * width, start + 32 * k)
                Capsule()
                    .fill(LinearGradient(colors: [Self.fillTop, Self.fillBottom], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 4 * k, y: 4 * k)
                    .frame(width: end - start, height: 32 * k)
                    .offset(x: start, y: height / 2 - 16 * k)
                let markers = GameplayHUDModel.checkpointPositions(count: GameplayHUDModel.markerCount)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, x in
                    Image("LaserHeistHUD/checkpoint")
                        .resizable()
                        .frame(width: dot, height: dot * 130 / 123)
                        .position(x: x * width, y: height / 2)
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
                // How a live press works (wrist zones on each player's outer side,
                // `LaserLiveRoundGeometryV1`). Not Sketch copy; pending Theo.
                Text("Reach toward your wall: high, middle, low")
                    .font(.system(size: 16 * k, weight: .bold, design: .rounded))
                    .padding(.top, 4 * k)
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
        .foregroundStyle(Self.cream)
        .padding(.horizontal, 22 * k)
        .frame(height: 50 * k)
        .background(HUDSurface(shape: Capsule(), k: k))
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
            VStack(spacing: 34 * k) {
                if !actions.canPause {
                    Text("PREVIEW · the round keeps running (session pause pending)")
                        .font(.system(size: 16 * k, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10 * k)
                        .padding(.vertical, 4 * k)
                        .background(Self.sun, in: Capsule())
                        .foregroundStyle(Self.ink)
                }
                menuButton("Resume", text: Color(sketch: 0x321605), k: k,
                           style: LayeredPillButtonStyle(top: Color(sketch: 0xEAA551), bottom: Color(sketch: 0xE97434),
                                                         rim: Color(sketch: 0xFFC73A), base: Color(sketch: 0xD75C41),
                                                         rimHeight: 3 * k, baseHeight: 2 * k)) {
                    actions.resume?()
                    menuShown = false
                }
                .accessibilityIdentifier("resume")
                if let leave = actions.leave {
                    menuButton("Leave Game", text: Color(sketch: 0xBEAB8D), k: k,
                               style: LayeredPillButtonStyle(top: Color(sketch: 0x3E3A5E), bottom: Color(sketch: 0x4E4A7A),
                                                             rim: Color(sketch: 0x3E3A5E), base: Color(sketch: 0x302D4F),
                                                             rimHeight: 3 * k, baseHeight: 2 * k)) {
                        menuShown = false
                        leave()
                    }
                    .accessibilityIdentifier("leaveGame")
                }
            }
        }
        .transition(.opacity)
    }

    /// Sketch "Hi-Fi Revisi 6 NOV" pause menu button ("Home Copy 29"): 620 × 86 pt.
    private func menuButton(_ title: String, text: Color, k: CGFloat, style: LayeredPillButtonStyle,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 44.8 * k, weight: .bold, design: .rounded))
                .foregroundStyle(text)
        }
        .buttonStyle(style)
        .frame(width: 620 * k, height: 86 * k)
    }

    // MARK: - Palette (Sketch)

    static let navy = Color(red: 0x1E / 255, green: 0x1A / 255, blue: 0x47 / 255)
    static let rim = Color(red: 0x5B / 255, green: 0x51 / 255, blue: 0x90 / 255)
    static let sun = Color(red: 0xFF / 255, green: 0xC8 / 255, blue: 0x3A / 255)
    static let ink = Color(red: 0x16 / 255, green: 0x12 / 255, blue: 0x3A / 255)
    static let fillTop = Color(red: 0xEA / 255, green: 0xA8 / 255, blue: 0x52 / 255)
    static let fillBottom = Color(red: 0xE9 / 255, green: 0x6D / 255, blue: 0x2F / 255)
    /// Sketch 6 NOV HUD: checkpoint/pause cream, the rail, and an empty heart socket.
    static let cream = Color(sketch: 0xFEF7C0)
    static let railTop = Color(sketch: 0x60568C)
    static let railBottom = Color(sketch: 0x534C80)
    static let socket = Color(sketch: 0x14122C)
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


/// The one Sketch HUD surface (6 NOV), shared by the health pill, score chip,
/// progress track and pause button: an 8 pt lavender ring (lighter at the top)
/// around a navy well (lighter at the top), a thin dark inner edge, and a soft
/// lift off the corridor. Measured from the Sketch export, 1 pt per pixel.
struct HUDSurface<S: InsettableShape>: View {
    let shape: S
    let k: CGFloat

    static var ringTop: Color { Color(sketch: 0x6A638C) }
    static var ringBottom: Color { Color(sketch: 0x514B7D) }
    static var wellTop: Color { Color(sketch: 0x26234F) }
    static var wellBottom: Color { Color(sketch: 0x1A1A3B) }
    static var wellEdge: Color { Color(sketch: 0x17152F) }

    var body: some View {
        shape
            .fill(LinearGradient(colors: [Self.ringTop, Self.ringBottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.inset(by: 8 * k)
                .fill(LinearGradient(colors: [Self.wellTop, Self.wellBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.inset(by: 8 * k).strokeBorder(Self.wellEdge, lineWidth: 1.5 * k))
            // One shadow for the finished surface: without the group, SwiftUI shadows
            // each layer and the well darkens its own ring.
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 6 * k, y: 3 * k)
    }
}
