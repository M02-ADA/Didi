//
//  TeamDefeatGate.swift
//  Sedactive
//

import Foundation
import Observation

/// Holds the Results screen back while the team defeat plays (`MascotDefeat`, Kevin, 23 November
/// 2026), and keeps the gameplay HUD on screen meanwhile. Presentation only: the round has already
/// ended in the game (its outcome, summary, score and health are final, no laser, scoring or
/// Diamond Time runs), so only WHEN Results appears changes, never what it shows.
///
/// - Held from the first terminal frame (24 November 2026): a `.healthDepleted` summary never shows
///   Results until this gate releases that round (`showsResults`), so no frame shows Results before
///   the defeat. (Holding only once `roundEnded` ran, from SwiftUI's `onChange`, let the first frame
///   with the summary draw Results, which then faded out for the defeat: seen on the iPad.)
/// - At the round's end (`roundEnded`): the team defeat starts (if the presenter has not already, in
///   the fatal HIT's frame; starting is idempotent). Nothing to play (no mascots): released at once.
/// - Every rendered frame (`tick`, host clock): released `MascotDefeat.resultsFade` before the
///   defeat's finishing pose, so Results fades in to be fully shown at `resultsTime`.
/// - Never stuck: released anyway once `holdLimit` has passed, or as soon as no defeat plays
///   (avatars removed, no mascots). Any other outcome shows Results at once, as before.
/// - The HUD (`hud(_:roundEnded:)`): while Results waits, the HUD stays as last shown in play, with
///   the final health (zero hearts) and score from the game; it leaves with Results' fade.
/// One gate per round view (`RoundObjects`): Retry and Home build a fresh one.
@MainActor @Observable
final class TeamDefeatGate {
    /// The round whose Results may show now that its defeat has played (observed: Results fades in
    /// and the HUD out when it changes).
    private(set) var released: UUID?
    /// The longest Results ever waits after the round's end (seconds).
    static let holdLimit = MascotDefeat.resultsAt + 0.75

    @ObservationIgnored private var held: UUID?
    @ObservationIgnored private var deadline = 0.0
    /// The HUD as last shown while the round played.
    @ObservationIgnored private var lastPlayingHUD: GameplayHUDModel?

    /// Whether Results may show for this round's summary. A depleted round waits for its defeat
    /// from the very first frame its summary exists, before `roundEnded` has run.
    func showsResults(_ summary: RoundSummary) -> Bool {
        summary.outcome != .healthDepleted || released == summary.sessionGeneration
    }

    /// Whether the gameplay HUD shows: during play, and while Results waits for the defeat.
    func showsHUD(_ summary: RoundSummary?) -> Bool {
        summary.map { !showsResults($0) } ?? true
    }

    /// Whether Results is waiting for the defeat (after `roundEnded`).
    var holdsResults: Bool { held != nil && released != held }

    /// The round has ended (its summary exists): starts the team defeat for a `.healthDepleted`
    /// round, which holds Results while it plays. Once per round.
    func roundEnded(_ summary: RoundSummary, events: [GameEvent], avatars: RobotAvatarLayer?, now: Double) {
        let generation = summary.sessionGeneration
        guard summary.outcome == .healthDepleted, held != generation else { return }
        held = generation
        if let avatars, let cast = TeamDefeatCast(events: events, generation: generation) {
            avatars.startTeamDefeat(cast)
        }
        deadline = now + Self.holdLimit
        if avatars?.isPlayingDefeat != true { release(generation, now: now) }
    }

    /// Once per rendered frame (host clock), after the avatars have rendered.
    func tick(now: Double, avatars: RobotAvatarLayer?) {
        guard let held, released != held else { return }
        // The defeat's own progress (whatever clock the mascots run on: live host time or a replay's).
        let finishing = avatars?.defeatAge.map { $0 >= MascotDefeat.resultsAt - MascotDefeat.resultsFade - 1e-9 }
        if finishing ?? (avatars?.isPlayingDefeat != true) || now >= deadline { release(held, now: now) }
    }

    /// The HUD to show: `model` (from the session's state) during play; once the round has ended,
    /// the HUD as last shown in play (its progress fill and markers, no banner or Diamond Time
    /// countdown), carrying the game's final health and score from `model`.
    func hud(_ model: GameplayHUDModel?, roundEnded: Bool) -> GameplayHUDModel? {
        guard roundEnded else {
            if let model { lastPlayingHUD = model }
            return model
        }
        guard var frozen = lastPlayingHUD else { return model }
        if let model {
            frozen.health = model.health
            frozen.maxHealth = model.maxHealth
            frozen.score = model.score
        }
        frozen.banner = .none
        frozen.diamondTimeRemaining = nil
        return frozen
    }

    private func release(_ generation: UUID, now: Double) {
        released = generation
        #if DEBUG
        print(String(format: "[TeamDefeat] Results shown %.2f s after the round's end · host %.3f",
                     now - (deadline - Self.holdLimit), now))
        #endif
    }
}
