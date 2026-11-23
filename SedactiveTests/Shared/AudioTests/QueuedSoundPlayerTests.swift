import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import Sedactive

/// Performance (Kevin, 22 November 2026): the app's sounds start on a serial audio queue
/// (`QueuedSoundPlayer`), because `AVAudioPlayer.play()` blocks its caller on a round trip to the audio
/// server (21–81 ms per Diamond Time pickup on the iPad). These tests use a real bundled cue.
@MainActor
struct QueuedSoundPlayerTests {
    private static func player() throws -> QueuedSoundPlayer {
        let url = try #require(Bundle.main.url(forResource: "lh-diamond-collect-1", withExtension: "caf"),
                               "the app bundles the Diamond Time pickup cue")
        let player = QueuedSoundPlayer(try AVAudioPlayer(contentsOf: url))
        player.prepareToPlay()
        return player
    }

    /// Waits until `condition` holds (the audio queue has run), up to `timeout`.
    /// (Generous: a parallel test run can keep the main actor busy for seconds.)
    private static func eventually(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aStartReturnsAtOnceAndReadsAsPlayingRightAway() async throws {
        let player = try Self.player()
        player.volume = 0 // silent test
        let begin = CACurrentMediaTime()
        let started = player.play()
        let mainThreadMS = (CACurrentMediaTime() - begin) * 1000
        #expect(started)
        #expect(player.isPlaying, "playing from the moment the start is asked for (the sting/music and ducking checks)")
        #expect(mainThreadMS < 5, "the caller does not wait for the audio server (\(mainThreadMS) ms)")
        player.stop()
        #expect(await Self.eventually { !player.isPlaying }, "the queued stop ends it")
    }

    @Test func callsRunInOrderSoAStopRightAfterAStartLeavesItSilent() async throws {
        let player = try Self.player()
        player.volume = 0
        for _ in 0..<5 {
            player.currentTime = 0
            player.play()
            player.stop()
        }
        #expect(await Self.eventually { !player.isPlaying }, "every stop follows its start")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!player.isPlaying, "and nothing starts after it")
    }

    /// The app's own wiring with real queued players: a burst of Diamond Time pickups, then the round
    /// ends (`stopEffects`, as PlayView does). Every queued start is stopped and none plays afterwards,
    /// and the Diamond Time sting still counts as playing at once, so its music still waits for it.
    @Test func aRoundsEndStopsEveryQueuedPickupAndNothingStartsLater() async throws {
        var made: [QueuedSoundPlayer] = []
        var clock = 0.0
        let audio = AudioService(makePlayer: { name in
            let ext = name.hasPrefix("lh-music-") ? "mp3" : "caf"
            guard let url = Bundle.main.url(forResource: name, withExtension: ext),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            let queued = QueuedSoundPlayer(player)
            made.append(queued)
            return queued
        }, now: { clock }, defaults: nil)
        audio.effectsVolume = 0
        audio.musicVolume = 0
        audio.preloadEffects()
        for index in 0..<24 {
            clock += 0.07
            audio.play(SoundCue.diamondPickupCues[index % SoundCue.diamondPickupCues.count])
        }
        #expect(audio.playCount.values.reduce(0, +) == 24, "every pickup asked for its sound")
        audio.stopEffects()
        #expect(await Self.eventually { made.allSatisfy { !$0.isPlaying } }, "the round's end stops every queued start")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(made.allSatisfy { !$0.isPlaying }, "and no queued sound plays after it")

        audio.setMusic(.mission, fade: 0)
        clock += 1
        audio.play(.diamondTime)
        audio.startDiamondTimeMusicIfReady(isInside: true)
        #expect(audio.mood == .diamondTimeEntry, "the sting reads as playing at once, so the music waits for it")
        audio.stopEffects()
        audio.setMusic(nil, fade: 0)
    }

    @Test func aFadeKeepsItsTargetInsteadOfJumping() throws {
        let player = try Self.player()
        player.volume = 0
        player.setVolume(0.6, fadeDuration: 1)
        #expect(player.volume == 0.6, "reports the fade's target, as AVAudioPlayer does")
        #expect(player.duration > 0)
        player.stop()
    }
}
