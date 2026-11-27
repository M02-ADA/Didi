import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// PERFECT! / ZAPPED! (17 November 2026): one team callout per LOGICAL encounter from the game's
/// own verdicts (`LaserTeamOutcomeTracker`), raised in the frame the completing verdict is shown,
/// plus its motion (`LaserTeamCalloutMotion`) and the cue stepping aside for it (`LaserFeedback`).
@MainActor
struct LaserTeamCalloutTests {
    // MARK: - Aggregation

    private static let generation = UUID()

    private static func encounter(_ id: UUID, players: [PlayerID] = PlayerID.allCases, crossing: Double = 10) throws -> LaserEncounter {
        try LaserEncounter(id: id, attemptID: UUID(), targets: players.map {
            try LaserTarget(playerID: $0, calibrationRevision: 1, requiredMove: .duck,
                            beam: .init(lowerY: 1, upperY: 1.1), warningTime: crossing - 3, crossingTime: crossing)
        }, roster: Set(players))
    }

    private static func state(_ items: [(LaserEncounter, [PlayerID: Judgement])], at time: Double = 10.3) -> LaserGameState {
        LaserGameState(sessionGeneration: generation, phase: .activity, gameTime: time, activityProgress: time,
                       teamHealth: 5, teamScore: 0,
                       encounters: items.map { LaserEncounterState(encounter: $0.0, judgements: $0.1, effectsCommitted: false) })
    }

    static let pending = Judgement.pending(.awaitingFinalization)
    static let hit = Judgement.hit(.insufficientClearance)
    static let unavailable = Judgement.unavailable(.stale)

    @Test("Both CLEAR → one PERFECT!; any HIT → one ZAPPED!; UNAVAILABLE without a HIT → nothing",
          arguments: [
            ([Judgement.clear, .clear], LaserTeamCalloutKind?.some(.perfect)),
            ([hit, .clear], .zapped), ([.clear, hit], .zapped), ([hit, hit], .zapped),
            ([unavailable, .clear], nil), ([unavailable, unavailable], nil), ([hit, unavailable], .zapped),
          ])
    func loneEncounterTable(verdicts: [Judgement], expected: LaserTeamCalloutKind?) throws {
        let e = try Self.encounter(UUID())
        var tracker = LaserTeamOutcomeTracker()
        let judged = [PlayerID.player1: verdicts[0], .player2: verdicts[1]]
        let first = tracker.verdictShown(encounterID: e.id, in: Self.state([(e, judged)]))
        #expect(first?.kind == expected)
        // The second player's verdict event for the same encounter never adds a second callout.
        #expect(tracker.verdictShown(encounterID: e.id, in: Self.state([(e, judged)])) == nil)
    }

    @Test func perfectWaitsForEveryPlayerButZappedIsImmediate() throws {
        let e = try Self.encounter(UUID())
        var tracker = LaserTeamOutcomeTracker()
        #expect(tracker.verdictShown(encounterID: e.id, in: Self.state([(e, [.player1: .clear, .player2: Self.pending])])) == nil)
        #expect(tracker.verdictShown(encounterID: e.id, in: Self.state([(e, [.player1: .clear])])) == nil)
        #expect(tracker.verdictShown(encounterID: e.id, in: Self.state([(e, [.player1: .clear, .player2: .clear])]))?.kind == .perfect)

        var zap = LaserTeamOutcomeTracker()
        let z = try Self.encounter(UUID())
        #expect(zap.verdictShown(encounterID: z.id, in: Self.state([(z, [.player1: Self.hit, .player2: Self.pending])]))?.kind == .zapped)
        #expect(zap.verdictShown(encounterID: z.id, in: Self.state([(z, [.player1: Self.hit, .player2: Self.hit])])) == nil)
    }

    /// A combined sequence (vertical layer, then its full-width DUCK) is one logical encounter.
    @Test func aCombinedSequenceGetsOneCalloutForBothLasers() throws {
        let (layerID, duckID) = try #require(LaserTeamOutcomeTracker.layerPartner.first)
        let layer = try Self.encounter(layerID, crossing: 10), duck = try Self.encounter(duckID, crossing: 11.75)
        let clear: [PlayerID: Judgement] = [.player1: .clear, .player2: .clear]
        let waiting: [PlayerID: Judgement] = [.player1: Self.pending, .player2: Self.pending]

        // Layer cleared, DUCK still to come: no PERFECT! yet. DUCK cleared too: exactly one.
        var tracker = LaserTeamOutcomeTracker()
        #expect(tracker.verdictShown(encounterID: layerID, in: Self.state([(layer, clear), (duck, waiting)])) == nil)
        let perfect = tracker.verdictShown(encounterID: duckID, in: Self.state([(layer, clear), (duck, clear)], at: 12))
        #expect(perfect?.kind == .perfect && perfect?.groupID == layerID)
        #expect(tracker.verdictShown(encounterID: duckID, in: Self.state([(layer, clear), (duck, clear)], at: 12)) == nil)

        // A HIT on the layer: ZAPPED! at once; the DUCK's verdicts add nothing, whatever they are.
        var zapped = LaserTeamOutcomeTracker()
        let hitLayer: [PlayerID: Judgement] = [.player1: Self.hit, .player2: .clear]
        #expect(zapped.verdictShown(encounterID: layerID, in: Self.state([(layer, hitLayer), (duck, waiting)]))?.kind == .zapped)
        #expect(zapped.verdictShown(encounterID: duckID, in: Self.state([(layer, hitLayer), (duck, clear)], at: 12)) == nil)

        // A one-player layer (`1LO>D`): its single target plus both DUCK targets.
        var solo = LaserTeamOutcomeTracker()
        let p1Layer = try Self.encounter(layerID, players: [.player1], crossing: 10)
        #expect(solo.verdictShown(encounterID: layerID, in: Self.state([(p1Layer, [.player1: .clear]), (duck, waiting)])) == nil)
        #expect(solo.verdictShown(encounterID: duckID, in: Self.state([(p1Layer, [.player1: .clear]), (duck, clear)]))?.kind == .perfect)
    }

    @Test func aWithdrawnAttemptDoesNotCountAndItsReplacementGetsItsOwnCallout() throws {
        let id = UUID()
        let old = try Self.encounter(id)
        var tracker = LaserTeamOutcomeTracker()
        #expect(tracker.verdictShown(encounterID: id, in: Self.state([(old, [.player1: .clear, .player2: .clear])]),
                                     withdrawn: [old.attemptID]) == nil)
        let retry = try Self.encounter(id, crossing: 20)
        #expect(tracker.verdictShown(encounterID: id, in: Self.state([(retry, [.player1: .clear, .player2: .clear])], at: 20.3),
                                     withdrawn: [old.attemptID])?.kind == .perfect)
    }

    // MARK: - Through the real runtime

    private struct Watched {
        var callouts: [(callout: LaserTeamCallout, cueShown: Bool)] = []
        var cueChanges: [(time: Double, shown: Bool)] = []
    }

    private func play(_ scenario: LaserReplayScript.Scenario) async throws -> (GameSessionCoordinator, Watched, Double) {
        let script = try LaserReplayScript.complete(seed: 1, scenario: scenario)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let presenter = GameplayScenePresenter(scene: LaserScene(), configuration: script.configuration, encounters: script.encounters)
        var watched = Watched()
        var now = 0.0
        presenter.onTeamCallout = { watched.callouts.append(($0, $1)) }
        presenter.onCueShownChanged = { watched.cueChanges.append((now, $0)) }
        let step = 1.0 / 30
        while now < script.duration, session.summary == nil {
            try await session.advance(to: now)
            if let state = session.state {
                now = state.gameTime
                presenter.apply(state: state, events: session.events, snapshot: nil)
            }
            now += step
        }
        if session.summary == nil { try await session.advance(to: script.duration) }
        #expect(presenter.teamCallouts == watched.callouts.map(\.callout))
        return (session, watched, step)
    }

    /// Each group's verdict times from the game's own events.
    private static func verdictTimes(_ session: GameSessionCoordinator) -> [UUID: [(time: Double, hit: Bool)]] {
        var times: [UUID: [(Double, Bool)]] = [:]
        for event in session.events {
            guard case .targetJudged(let id, _, let judgement) = event.kind else { continue }
            let group = LaserTeamOutcomeTracker.groupOf[id] ?? id
            times[group, default: []].append((event.gameTime, { if case .hit = judgement { true } else { false } }()))
        }
        return times
    }

    @Test func theCompleteReplayShowsOnePerfectPerLogicalEncounterInTheVerdictsFrame() async throws {
        let (session, watched, step) = try await play(.standard)
        #expect(session.summary?.vaultsOpened == 5)
        // 73 lasers, 19 of them the DUCKs of combined sequences: 54 logical encounters, all cleared.
        #expect(watched.callouts.count == 54 && watched.callouts.allSatisfy { $0.callout.kind == .perfect })
        #expect(Set(watched.callouts.map(\.callout.groupID)).count == 54, "one callout per logical encounter")
        let verdicts = Self.verdictTimes(session)
        for (callout, _) in watched.callouts {
            // PERFECT! in the frame its last verdict is shown (never before, never a frame late).
            let last = try #require(verdicts[callout.groupID]?.map(\.time).max())
            #expect(callout.gameTime >= last - 1e-9 && callout.gameTime - last <= step + 1e-6,
                    "\(callout.groupID): verdict \(last), callout \(callout.gameTime)")
        }
        // Where it sits: full size in the cue's place unless a cue is up. A full-size one is never
        // cut short by the next cue within its own length.
        let full = watched.callouts.filter { !$0.cueShown }
        let length = LaserTeamCalloutMotion.duration(.perfect, reduceMotion: false)
        let cut = full.filter { c in watched.cueChanges.contains { $0.shown && $0.time > c.callout.gameTime && $0.time < c.callout.gameTime + length } }
        print("[TeamCallout] replay: \(watched.callouts.count) PERFECT! · full size \(full.count) · compact \(watched.callouts.count - full.count) · cut short by a cue \(cut.count)")
        #expect(cut.isEmpty)
    }

    @Test func aRoundOfHitsShowsZappedOncePerLogicalEncounterWithTheHit() async throws {
        let (session, watched, step) = try await play(.healthDepleted)
        #expect(!watched.callouts.isEmpty && watched.callouts.allSatisfy { $0.callout.kind == .zapped })
        #expect(Set(watched.callouts.map(\.callout.groupID)).count == watched.callouts.count, "both players hit: one ZAPPED!")
        let verdicts = Self.verdictTimes(session)
        for (callout, _) in watched.callouts {
            // ZAPPED! with the first HIT shown (the players' own zaps start in that frame too).
            let firstHit = try #require(verdicts[callout.groupID]?.filter(\.hit).map(\.time).min())
            #expect(callout.gameTime >= firstHit - 1e-9 && callout.gameTime - firstHit <= step + 1e-6)
        }
        let hitGroups = Set(verdicts.filter { $0.value.contains { $0.hit } }.keys)
        #expect(Set(watched.callouts.map(\.callout.groupID)) == hitGroups)
    }

    // MARK: - The cue steps aside for the result

    @Test func theCircularCueGivesItsClearOrHitResultToTheCallout() throws {
        func timing(_ phase: LaserTimingPresentation.Phase, _ verdicts: [PlayerID: Judgement]) -> LaserTimingPresentation {
            LaserTimingPresentation(generation: UUID(), encounterID: UUID(), attemptID: UUID(), move: .duck, gameTime: 10,
                warningTime: 7, cueTime: 8.6, crossingTime: 10, evidenceWindow: 9.65...10.25, progress: 1, remaining: 0,
                phase: phase, verdicts: verdicts, successCommitted: false)
        }
        #expect(LaserFeedback.teamCalloutShowsResult(timing(.result, [.player1: .clear, .player2: .clear])))
        #expect(LaserFeedback.teamCalloutShowsResult(timing(.result, [.player1: Self.hit, .player2: .clear])))
        #expect(!LaserFeedback.teamCalloutShowsResult(timing(.result, [.player1: Self.unavailable, .player2: .clear])))
        #expect(!LaserFeedback.teamCalloutShowsResult(timing(.prepare, [:])))
    }

    // MARK: - Motion

    @Test(arguments: LaserTeamCalloutKind.allCases)
    func theCalloutIsVisibleInItsFirstFrameAndGoneWhenItEnds(kind: LaserTeamCalloutKind) {
        let frame = 1.0 / 60
        let count = LaserTeamCalloutMotion.text(kind).count
        #expect(LaserTeamCalloutMotion.word(kind, at: frame, reduceMotion: false).opacity > 0)
        #expect((0..<count).contains { LaserTeamCalloutMotion.letter(kind, index: $0, count: count, at: frame, reduceMotion: false).opacity > 0 })
        // The whole word reads from its first frame: no letter waits to appear.
        for i in 0..<count {
            #expect(LaserTeamCalloutMotion.letter(kind, index: i, count: count, at: frame, reduceMotion: false).opacity == 1)
        }
        // A big change within 100 ms (game feel), each word with its own motion.
        typealias M = LaserTeamCalloutMotion
        if kind == .perfect {
            // Launches stretched tall, overshoots high and big, lands squashed wide.
            let apex = M.word(kind, at: M.perfectApex, reduceMotion: false)
            #expect(apex.scale > 1.2 && apex.scaleY > apex.scaleX && apex.y < 0)
            let landing = M.word(kind, at: M.perfectLanding, reduceMotion: false)
            #expect(landing.scaleX > 1.15 && landing.scaleY < 0.85)
            #expect(M.perfectLanding <= 0.15)
        } else {
            // Bangs in oversized and flat from the left, slams small, recoils tall.
            let bang = M.word(kind, at: 0, reduceMotion: false)
            #expect(bang.scale > 1.5 && bang.scaleY < bang.scaleX && bang.x < 0)
            #expect(M.word(kind, at: M.zapImpact, reduceMotion: false).scale < 0.9)
            let recoil = M.word(kind, at: M.zapRecoil, reduceMotion: false)
            #expect(recoil.scale > 1.1 && recoil.scaleY > recoil.scaleX)
        }
        for reduce in [false, true] {
            let end = LaserTeamCalloutMotion.duration(kind, reduceMotion: reduce)
            #expect(end <= 1.05, "short enough for 4.5–6 s encounter spacing")
            #expect(LaserTeamCalloutMotion.word(kind, at: end, reduceMotion: reduce).opacity == 0)
            #expect(LaserTeamCalloutMotion.word(kind, at: end * 0.55, reduceMotion: reduce).opacity > 0.9, "readable mid-way")
        }
        // Settled before it leaves: every letter at rest by 0.79 s (after PERFECT!'s wave).
        for i in 0..<count {
            let pose = LaserTeamCalloutMotion.letter(kind, index: i, count: count, at: 0.79, reduceMotion: false)
            #expect(abs(pose.scale - 1) < 1e-9 && abs(pose.scaleX - 1) < 1e-9 && abs(pose.scaleY - 1) < 1e-9)
        }
        // A cue coming up makes a full-size callout leave within `yieldFade`.
        #expect(LaserTeamCalloutMotion.word(kind, at: 0.4 + LaserTeamCalloutMotion.yieldFade, reduceMotion: false, yield: 0.4).opacity == 0)
    }

    @Test(arguments: LaserTeamCalloutKind.allCases)
    func reduceMotionKeepsTheWordStill(kind: LaserTeamCalloutKind) {
        let count = LaserTeamCalloutMotion.text(kind).count
        for t in stride(from: 0.0, through: 0.95, by: 0.01) {
            let word = LaserTeamCalloutMotion.word(kind, at: t, reduceMotion: true)
            #expect(word.scale == 1 && word.scaleX == 1 && word.scaleY == 1 && word.x == 0 && word.y == 0 && word.rotation == 0)
            for i in 0..<count {
                let letter = LaserTeamCalloutMotion.letter(kind, index: i, count: count, at: t, reduceMotion: true)
                let still = LaserTeamCalloutMotion.letter(kind, index: i, count: count, at: 0, reduceMotion: true)
                #expect(letter == still, "no letter motion")
            }
            #expect(LaserTeamCalloutMotion.shine(at: t, reduceMotion: true) == nil)
            #expect(LaserTeamCalloutMotion.burst(kind, at: t, reduceMotion: true) == nil)
            #expect(LaserTeamCalloutMotion.seal(at: t, reduceMotion: true) == nil && LaserTeamCalloutMotion.crackle(at: t, reduceMotion: true) == nil)
            #expect(LaserTeamCalloutMotion.confetti(at: t, reduceMotion: true) == nil)
            #expect(LaserTeamCalloutMotion.rays(at: t, reduceMotion: true) == nil && LaserTeamCalloutMotion.plate(at: t, reduceMotion: true) == nil)
            #expect(LaserTeamCalloutMotion.singe(at: t, reduceMotion: true) == 0)
        }
    }

    @Test func zappedFlashesExactlyTwiceThenStaysCalm() {
        var peaks = 0, wasOn = false
        for t in stride(from: 0.0, through: 0.95, by: 0.005) {
            let on = LaserTeamCalloutMotion.flash(at: t) > 0.2
            if on && !wasOn { peaks += 1 }
            wasOn = on
            if t > 0.3 { #expect(!on) }
        }
        #expect(peaks == 2)
        // The aftermath crackle: one small arc at a time, a few short windows, done by 0.8 s.
        var lit = 0, wasLit = false
        for t in stride(from: 0.0, through: 0.95, by: 1.0 / 120) {
            let on = LaserTeamCalloutMotion.crackle(at: t, reduceMotion: false) != nil
            if on && !wasLit { lit += 1 }
            wasLit = on
            if t >= 0.8 { #expect(!on) }
        }
        #expect(lit == LaserTeamCalloutMotion.crackleWindows.count && lit <= 6)
        // The buzz and the bolts stop early too: no lingering flicker.
        #expect(!LaserTeamCalloutMotion.boltsOn(at: 0.3, reduceMotion: false))
        #expect(LaserTeamCalloutMotion.word(.zapped, at: 0.5, reduceMotion: false).x == 0)
    }

    /// ZAPPED! lands with the struck mascot (`LaserHitReaction`): its slam at the mascot's hit-stop,
    /// its first flash inside the mascot's white impact frame, its recoil at the mascot's recoil peak.
    @Test func zappedIsInStepWithTheStruckMascot() {
        typealias M = LaserTeamCalloutMotion
        #expect(M.zapImpact == LaserHitReaction.hitStop)
        #expect(M.flashCenters[0] < LaserHitReaction.hitStop + 0.05)
        let peak = stride(from: 0.0, through: 0.3, by: 0.001).max { LaserHitReaction.recoil($0) < LaserHitReaction.recoil($1) } ?? 0
        #expect(abs(M.zapRecoil - peak) <= 0.02, "recoil peak \(peak)")
    }

    /// Each word leaves its own way: PERFECT! zips up and shrinks, ZAPPED!'s letters drop off one by
    /// one; both are gone by their end.
    @Test func eachWordHasItsOwnExit() {
        typealias M = LaserTeamCalloutMotion
        let zip = M.word(.perfect, at: 0.92, reduceMotion: false)
        #expect(zip.scale < 0.7 && zip.y < -0.2)
        let first = M.letter(.zapped, index: 0, count: 7, at: 0.8, reduceMotion: false)
        let last = M.letter(.zapped, index: 6, count: 7, at: 0.8, reduceMotion: false)
        #expect(first.y > last.y && first.opacity < last.opacity, "the first letter falls first")
    }

    // MARK: - No ✓/✗ over the heads

    @Test func clearAndHitShowNoBadgeButAHitKeepsItsSparkAndUnavailableKeepsItsBadge() throws {
        let feedback = LaserFeedback()
        feedback.setImpactArt { Entity() }
        func entity(_ name: String) throws -> Entity { try #require(feedback.root.findEntity(named: name)) }
        feedback.showOutcome(.clear, for: .player1, badgeAt: .zero, impactAt: .zero)
        #expect(try !entity("laserFeedback.badge.player1").isEnabled)
        feedback.showOutcome(.hit, for: .player2, badgeAt: .zero, impactAt: .zero)
        #expect(try !entity("laserFeedback.badge.player2").isEnabled)
        #expect(try entity("laserFeedback.impact.player2").isEnabled, "the laser's own spark on a HIT")
        feedback.showOutcome(.unavailable, for: .player1, badgeAt: .zero, impactAt: .zero)
        #expect(try entity("laserFeedback.badge.player1").isEnabled, "tracking's neutral badge stays")
        #expect(LaserFeedback.showsBadge(.unavailable) && !LaserFeedback.showsBadge(.clear) && !LaserFeedback.showsBadge(.hit))
    }

    // MARK: - Model and placement

    @Test func aNewerCalloutReplacesTheOlderAndOnlyAFullSizeOneYieldsToACue() {
        let model = LaserTeamCalloutModel()
        let start = Date()
        model.show(.perfect, compact: false, at: start)
        let first = model.shown?.serial
        model.cueShownChanged(true, at: start.addingTimeInterval(0.3))
        #expect(model.shown?.yieldedAt == start.addingTimeInterval(0.3))
        model.show(.zapped, compact: true, at: start.addingTimeInterval(0.5))
        #expect(model.shown?.kind == .zapped && model.shown?.serial != first)
        model.cueShownChanged(true, at: start.addingTimeInterval(0.6))
        #expect(model.shown?.yieldedAt == nil, "a compact callout already keeps clear of the cue")
        model.finish(first ?? 0)
        #expect(model.shown != nil, "an older callout's end never removes a newer one")
        model.finish(model.shown?.serial ?? 0)
        #expect(model.shown == nil)
    }

    @Test(arguments: [CGSize(width: 1194, height: 834), CGSize(width: 1366, height: 1024), CGSize(width: 1210, height: 834),
                      CGSize(width: 1180, height: 820), CGSize(width: 1376, height: 1032)])
    func placementSitsBetweenTheHUDBarAndTheMascotsOnEveryLandscapeIPad(size: CGSize) {
        let k = LaserTeamCalloutLayout.scale(size)
        // GameplayHUD: the top bar ends at 58 + 66 = 124 pt (×k); the mascots' heads start about 255 pt.
        let full = LaserTeamCalloutLayout.center(compact: false, in: size), fullFont = LaserTeamCalloutLayout.fontSize(compact: false, k: k)
        #expect(full.y - fullFont * 0.6 > 124 * k && full.y + fullFont * 0.6 < 262 * k)
        let compact = LaserTeamCalloutLayout.center(compact: true, in: size), compactFont = LaserTeamCalloutLayout.fontSize(compact: true, k: k)
        #expect(compact.y - compactFont * 0.6 > 124 * k && compact.y + compactFont * 0.5 < 168 * k)
        #expect(full.x == size.width / 2)
    }
}
