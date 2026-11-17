import AVFoundation
import SwiftUI

/// One silent decoder and AVPlayerLooper, owned only while the intro is visible.
@MainActor @Observable
final class LeanIntroductionPlayback {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    var isLooping: Bool { looper != nil }

    func start(url: URL? = Bundle.main.url(forResource: "lean-introduction", withExtension: "mov")) {
        guard player == nil, let url else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        queue.play()
    }

    func setActive(_ active: Bool) {
        if active { player?.play() } else { player?.pause() }
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
    }
}

struct LeanIntroductionAnimation: View {
    let solo: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = LeanIntroductionPlayback()

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = solo ? proxy.size.width * 2 : proxy.size.width
            Group {
                if let player = playback.player {
                    LeanPlayerLayer(player: player)
                } else {
                    Image("lean-introduction-poster").resizable().scaledToFit()
                }
            }
            .frame(width: fullWidth, height: proxy.size.height)
            // Solo shows the original left silhouette only, at the same individual scale.
            .offset(x: solo ? -fullWidth * 0.08 : 0)
        }
        .clipped()
        .accessibilityLabel(solo ? "One mascot demonstrating leaning left and right" : "Two mascots demonstrating leaning left and right")
        .accessibilityIdentifier("leanIntroductionAnimation")
        .task { if !reduceMotion { playback.start(); playback.setActive(scenePhase == .active) } }
        .onChange(of: scenePhase) { _, phase in playback.setActive(phase == .active) }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { playback.stop() } else { playback.start() }
        }
        .onDisappear { playback.stop() }
    }
}

private struct LeanPlayerLayer: UIViewRepresentable {
    let player: AVQueuePlayer
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.playerLayer.isOpaque = false
        view.playerLayer.backgroundColor = UIColor.clear.cgColor
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: LayerView, coordinator: ()) { view.playerLayer.player = nil }
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
