import AVFoundation
import Testing
@testable import Sedactive

@MainActor struct LeanIntroductionTests {
    @Test func suppliedMotionIsBundledSilentAndThreeSeconds() async throws {
        let url = try #require(Bundle.main.url(forResource: "lean-introduction", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.001)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 1210, height: 834))
        #expect(try await track.load(.nominalFrameRate) == 60)
    }

    @Test func singleLooperStopsAndReleasesItemsOnExit() throws {
        let playback = LeanIntroductionPlayback()
        playback.start()
        let queue = try #require(playback.player)
        #expect(queue.isMuted && playback.isLooping)
        playback.start()
        #expect(playback.player === queue, "re-entry cannot create a second decoder")
        playback.setActive(false)
        #expect(queue.rate == 0)
        playback.setActive(true)
        playback.stop()
        #expect(playback.player == nil && !playback.isLooping && queue.items().isEmpty)
        playback.stop()
        playback.start(url: nil)
        #expect(playback.player == nil)
    }

    @Test func inactiveAndStoppedPlaybackCannotDeliverAStaleCompletion() async throws {
        let playback = LeanIntroductionPlayback()
        var completions = 0
        playback.start(onCompleted: { completions += 1 })
        let queue = try #require(playback.player)
        playback.didPresentFirstFrame()
        try await Task.sleep(for: .milliseconds(100))
        playback.setActive(false)
        if let item = queue.currentItem {
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(completions == 0)
        playback.setActive(true)
        try await Task.sleep(for: .milliseconds(3500))
        #expect(completions == 1)
        playback.stop()
        #expect(playback.player == nil && queue.items().isEmpty)
    }
}
