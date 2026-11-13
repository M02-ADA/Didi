//
//  IntroVideoView.swift
//  Sedactive
//

import AVFoundation
import SwiftUI

/// The story intro (owner request, 13 November 2026): the stolen-diamond video
/// between START MISSION! and Game Set Up, with "Tap to skip video" under it.
/// It plays once with its own sound. A tap anywhere, the end of the video or a
/// missing file continues. Presentation only: no flow, session or camera state.
struct IntroVideoView: View {
    static let resource = "lh-intro-story"

    let onFinish: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var finished = false

    var body: some View {
        // The whole screen is one Button, so a tap anywhere and VoiceOver share the same skip action.
        Button(action: finish) {
            SketchArtboard {
                if let player { PlayerLayerView(player: player) }
            } content: { k in
                // Size and position are not in the Sketch artboards; pending Theo.
                Text("Tap to skip video")
                    .font(.system(size: 30 * k, weight: .bold, design: .rounded))
                    .foregroundStyle(LaserHeistDesign.cream)
                    .shadow(color: .black.opacity(0.6), radius: 6 * k)
                    .frame(width: 1210 * k)
                    .offset(y: 760 * k)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip video")
        .accessibilityIdentifier("skipIntroVideo")
        .task { await play() }
        // iOS pauses video when the app goes to the background; continue where it stopped on return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !finished { player?.play() }
        }
        .onDisappear { player?.pause() }
    }

    private func play() async {
        guard let url = Bundle.main.url(forResource: Self.resource, withExtension: "mp4") else { return finish() }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
        for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item) { break }
        // A skip already left this screen and cancelled the task; nothing more to do.
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        player?.pause()
        onFinish()
    }
}

/// An `AVPlayerLayer` with no playback controls (SwiftUI's `VideoPlayer` always offers them).
/// Aspect fill, like the Sketch backdrops: the 1210 × 834 video crops only at other iPad ratios.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) { view.playerLayer.player = player }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

#Preview("Intro video", traits: .landscapeLeft) {
    IntroVideoView(onFinish: {})
}
