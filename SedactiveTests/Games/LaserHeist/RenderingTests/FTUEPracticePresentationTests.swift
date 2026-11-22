import Foundation
import AVFoundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct FTUEPracticePresentationTests {
    @Test func approvedAnimationHasFiniteSilentPlaybackAndCleanup() async throws {
        let url = try #require(Bundle.main.url(forResource: "jump-duck-introduction", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.01)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let playback = LeanIntroductionPlayback()
        playback.start(url: url)
        #expect(playback.isLooping && playback.player?.isMuted == true)
        playback.setActive(false)
        playback.stop()
        #expect(playback.player == nil && !playback.isLooping)
    }

    @Test func committedFeedbackOwnsRetryAndSingleHazardCueReset() async throws {
        let scene = LaserScene(), renderer = FTUEPracticePresentation(), callouts = LaserTeamCalloutModel()
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        var p = try FTUELaserPracticeTests.make()
        let variant = scene.timingVariant
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: false)
        let root = try #require(scene.root.children.first { $0.name.hasPrefix("ftue.practice.") })
        #expect(scene.timingPresentation?.attemptID == p.attemptID && callouts.shown == nil)
        try FTUELaserPracticeTests.run(&p, clear: [.player1])
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: false)
        let serial = try #require(callouts.shown?.serial)
        #expect(callouts.shown?.kind == .zapped && renderer.finishedAttempt(callouts) == nil)
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: true)
        callouts.finish(serial)
        #expect(renderer.finishedAttempt(callouts) == nil)
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: false)
        callouts.finish(serial)
        let old = try #require(renderer.finishedAttempt(callouts))
        try p.feedbackFinished(attempt: old, generation: p.generation)
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: false)
        #expect(root.parent == nil && scene.root.children.filter { $0.name.hasPrefix("ftue.practice.") }.count == 1)
        #expect(scene.timingPresentation?.attemptID == p.attemptID && scene.timingPresentation?.progress == 0)
        try FTUELaserPracticeTests.run(&p, clear: Set(p.roster), start: 1100)
        renderer.update(scene: scene, practice: p, callouts: callouts, suspended: false)
        #expect(callouts.shown?.kind == .perfect)
        renderer.stop(callouts: callouts)
        #expect(callouts.shown == nil && scene.timingPresentation == nil && scene.timingVariant == variant)
        #expect(scene.root.children.allSatisfy { !$0.name.hasPrefix("ftue.practice.") })
    }
    @Test func coopDuckUnavailableAndHitEachShowFeedbackBeforeFreshRetry() async throws {
        let scene = LaserScene(), renderer = FTUEPracticePresentation(), callouts = LaserTeamCalloutModel()
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        var practice = try FTUELaserPracticeTests.make()
        let roster = Set(practice.roster)
        try FTUELaserPracticeTests.run(&practice, clear: roster)
        try practice.feedbackFinished(attempt: practice.attemptID, generation: practice.generation)
        var attempts: Set<UUID> = []
        let failures: [(Double, Set<PlayerID>, FTUELaserPractice.Outcome)] = [
            (1100, [.player2], .unavailable), (1200, [], .hit)
        ]
        for (start, unavailable, expected) in failures {
            let attempt = practice.attemptID
            #expect(attempts.insert(attempt).inserted)
            try FTUELaserPracticeTests.run(&practice, clear: unavailable.isEmpty ? [.player2] : roster,
                                          unavailable: unavailable, start: start)
            renderer.update(scene: scene, practice: practice, callouts: callouts, suspended: false)
            #expect(practice.outcome == expected)
            let serial = try #require(callouts.shown?.serial)
            #expect(callouts.shown?.kind == .zapped && renderer.finishedAttempt(callouts) == nil)
            let root = try #require(scene.root.children.first { $0.name.hasPrefix("ftue.practice.") })
            try practice.update(at: start + 4, eligible: true, context: practice.context)
            renderer.update(scene: scene, practice: practice, callouts: callouts, suspended: false)
            #expect(callouts.shown?.serial == serial && practice.attemptID == attempt)
            callouts.finish(serial)
            let finished = try #require(renderer.finishedAttempt(callouts))
            try practice.feedbackFinished(attempt: finished, generation: practice.generation)
            renderer.update(scene: scene, practice: practice, callouts: callouts, suspended: false)
            #expect(root.parent == nil && callouts.shown == nil)
            #expect(scene.root.children.filter { $0.name.hasPrefix("ftue.practice.") }.count == 1)
        }
        let final = practice.attemptID
        #expect(attempts.insert(final).inserted)
        try FTUELaserPracticeTests.run(&practice, clear: roster, start: 1300)
        renderer.update(scene: scene, practice: practice, callouts: callouts, suspended: false)
        #expect(callouts.shown?.kind == .perfect)
        callouts.finish(try #require(callouts.shown?.serial))
        try practice.feedbackFinished(attempt: try #require(renderer.finishedAttempt(callouts)),
                                      generation: practice.generation)
        try practice.update(at: 1310, eligible: true, context: practice.context)
        #expect(practice.completed && practice.attemptID == final)
        renderer.stop(callouts: callouts)
        #expect(scene.root.children.allSatisfy { !$0.name.hasPrefix("ftue.practice.") })
    }

    @Test func missingModuleMigrationAndOldCompletionAreGenerationQualified() throws {
        let defaults = UserDefaults(suiteName: "JumpDuckMigration.\(UUID())")!
        defer { for key in [LeanTutorial.completionKey, LeanTutorial.heartCompletionKey, LeanTutorial.jumpDuckCompletionKey] { defaults.removeObject(forKey: key) } }
        defaults.set(true, forKey: LeanTutorial.completionKey)
        defaults.set(true, forKey: LeanTutorial.heartCompletionKey)
        let tutorial = LeanTutorial(defaults: defaults)
        var p = try FTUELaserPracticeTests.make(coop: false)
        tutorial.prepare(generation: p.generation, roster: p.roster)
        tutorial.beginIfEligible(generation: p.generation, eligible: true)
        #expect(tutorial.stage == .jumpDuckIntroduction)
        tutorial.setSuspended(true, generation: p.generation)
        tutorial.finishJumpDuckIntroduction(generation: p.generation)
        #expect(tutorial.stage == .jumpDuckIntroduction)
        tutorial.setSuspended(false, generation: p.generation)
        tutorial.finishJumpDuckIntroduction(generation: p.generation)
        for i in 0...1 {
            try FTUELaserPracticeTests.run(&p, clear: Set(p.roster), start: 1000 + Double(i) * 10)
            try p.feedbackFinished(attempt: p.attemptID, generation: p.generation)
            tutorial.synchronizePractice(p, generation: p.generation)
        }
        #expect(tutorial.stage == .progressExplanation(.bar) && !tutorial.isCompleted)
        LeanTutorialTests.Fixture().finishProgress(tutorial, generation: p.generation)
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        tutorial.prepare(generation: UUID(), roster: p.roster)
        #expect(tutorial.stage == .completed)
        tutorial.synchronizePractice(p, generation: p.generation)
        #expect(tutorial.stage == .completed)
        tutorial.prepare(generation: UUID(), roster: p.roster, replayRequested: true)
        tutorial.beginIfEligible(generation: tutorial.generation!, eligible: true)
        #expect(tutorial.stage == .introduction && tutorial.isCompleted)
        tutorial.resetForNextPlay()
    }
}
