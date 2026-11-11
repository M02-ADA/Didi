import Foundation
import Testing
@testable import Sedactive

/// A player that records what it was asked to do, instead of making sound.
@MainActor
final class FakeSoundPlayer: SoundPlaying {
    let name: String
    var volume: Float = 1
    var numberOfLoops = 0
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var deviceCurrentTime: TimeInterval = 100
    var duration: TimeInterval = 0.5
    var plays = 0
    var startedAt: TimeInterval?
    var fades: [(Float, TimeInterval)] = []

    init(_ name: String) { self.name = name }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { plays += 1; isPlaying = true; return true }
    func play(atTime time: TimeInterval) -> Bool { startedAt = time; return play() }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) { self.volume = volume; fades.append((volume, duration)) }
}

@MainActor
struct AudioServiceTests {
    final class Harness {
        var clock: TimeInterval = 0
        var made: [FakeSoundPlayer] = []
        var available: (String) -> Bool = { _ in true }
    }

    private func service(_ harness: Harness) -> AudioService {
        AudioService(makePlayer: { name in
            guard harness.available(name) else { return nil }
            let player = FakeSoundPlayer(name)
            harness.made.append(player)
            return player
        }, now: { harness.clock }, defaults: nil)
    }

    @Test func aCuePlaysOnceAndRepeatsWithinItsIntervalAreDropped() {
        let harness = Harness()
        let audio = service(harness)
        audio.play(.laserHit)
        audio.play(.laserHit)          // both players' HIT in the same frame
        #expect(audio.playCount[.laserHit] == 1 && audio.dropped == 1)
        harness.clock = SoundCue.laserHit.minimumInterval + 0.01
        audio.play(.laserHit)
        #expect(audio.playCount[.laserHit] == 2)
    }

    @Test func differentCuesDoNotBlockEachOther() {
        let audio = service(Harness())
        audio.play(.laserClear)
        audio.play(.laserHit)          // one player CLEAR, the other HIT
        #expect(audio.playCount[.laserClear] == 1 && audio.playCount[.laserHit] == 1)
    }

    @Test func rapidTapsMakeOneSound() {
        let harness = Harness()
        let audio = service(harness)
        for step in 0..<5 { harness.clock = Double(step) * 0.02; audio.play(.uiTap) }
        #expect(audio.playCount[.uiTap] == 1)
    }

    @Test func pickupsRotateThroughTheirVariants() {
        let harness = Harness()
        let audio = service(harness)
        for step in 0..<3 { harness.clock = Double(step); audio.play(.diamondCollect) }
        let pickups = harness.made.filter { $0.name.hasPrefix("lh-diamond-collect") }
        #expect(Set(pickups.map(\.name)).count == 3)
        #expect(pickups.allSatisfy { $0.plays == 1 })
    }

    @Test func aMissingFileIsSilentNotACrash() {
        let harness = Harness()
        harness.available = { $0 != "lh-vault-open" }
        let audio = service(harness)
        audio.play(.vaultOpen)
        audio.play(.uiTap)
        #expect(audio.playCount[.vaultOpen] == nil && audio.playCount[.uiTap] == 1)
    }

    @Test func mutingEffectsLeavesMusicAndMutingMusicLeavesEffects() {
        let harness = Harness()
        let audio = service(harness)
        audio.effectsEnabled = false
        audio.setMusic(.menu)
        audio.play(.uiTap)
        #expect(audio.playCount[.uiTap] == nil && audio.isMusicPlaying)

        let other = service(Harness())
        other.musicEnabled = false
        other.setMusic(.mission)
        other.play(.uiTap)
        #expect(!other.isMusicPlaying && other.playCount[.uiTap] == 1)
        other.musicEnabled = true
        #expect(other.isMusicPlaying, "turning music on resumes the wanted mood")
    }

    @Test func menuAndMissionSelectSeparateTracks() throws {
        let harness = Harness()
        let audio = service(harness)
        audio.setMusic(.menu)
        audio.setMusic(.menu)
        let menu = try #require(harness.made.first { $0.name == "lh-music-60s-special-agent" })
        #expect(harness.made.count == 1)
        #expect(menu.plays == 1 && menu.numberOfLoops == -1)
        #expect(menu.volume == audio.musicVolume)

        audio.setMusic(.mission)
        let mission = try #require(harness.made.first { $0.name == "lh-music-silky-spy" })
        #expect(mission.plays == 1 && mission.numberOfLoops == -1)
        #expect(menu.volume == 0 && mission.volume == audio.musicVolume * 0.5)
        #expect(mission.fades.last?.1 == 2.5)
        #expect(menu.fades.last?.1 == 0.8)

        audio.setMusic(.menu)
        #expect(harness.made.count == 2)
        #expect(menu.volume == audio.musicVolume && mission.volume == 0)

        audio.setMusic(nil)
        #expect(menu.volume == 0 && mission.volume == 0)
    }

    @Test(arguments: [SoundCue.diamondTime, .cueDuck, .cueJump, .vaultWarning])
    func priorityCuesDuckTheMusic(cue: SoundCue) throws {
        let harness = Harness()
        let audio = service(harness)
        audio.setMusic(.mission)
        audio.play(cue)
        let mission = try #require(harness.made.first { $0.name == "lh-music-silky-spy" })
        #expect(abs(mission.volume - audio.musicVolume * 0.5 * AudioService.duckedShare) < 1e-6)
    }

    @Test func stopEffectsSilencesEveryEffect() {
        let harness = Harness()
        let audio = service(harness)
        audio.play(.roundSuccess)
        audio.play(.uiTap)
        audio.stopEffects()
        #expect(harness.made.filter { !$0.name.hasPrefix("lh-music") }.allSatisfy { !$0.isPlaying })
    }

    /// Every cue's bundled files exist in the app.
    @Test(arguments: SoundCue.allCases)
    func everyCueIsBundled(cue: SoundCue) {
        for name in cue.resources {
            #expect(Bundle.main.url(forResource: name, withExtension: "caf") != nil, "missing \(name).caf")
        }
    }

    @Test func selectedMusicTracksAreBundled() {
        for name in ["lh-music-60s-special-agent", "lh-music-silky-spy"] {
            #expect(Bundle.main.url(forResource: name, withExtension: "mp3") != nil)
        }
    }

    @Test func resultsSoundFollowsTheSessionOutcome() {
        #expect(ResultsView.sting(for: .completed) == .roundSuccess)
        #expect(ResultsView.sting(for: .healthDepleted) == .roundFailure)
        #expect(ResultsView.sting(for: .vaultFailed) == .roundFailure)
        #expect(ResultsView.sting(for: .aborted) == nil && ResultsView.sting(for: .technicalInterruption) == nil)
    }
}
