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
}
