import AVFoundation
import SwiftUI

/// One silent decoder. Its FIRST visible, complete playback ends the intro; no gameplay timer.
@MainActor @Observable
final class LeanIntroductionPlayback {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var finishTask: Task<Void, Never>?
    private var token = UUID()
    private var active = true
    private var presented = false
    private var finished = false
    private var completion: (() -> Void)?
    var isLooping: Bool { looper != nil }

    func start(url: URL? = Bundle.main.url(forResource: "lean-introduction", withExtension: "mov"),
               onCompleted: (() -> Void)? = nil) {
        guard player == nil, let url else { return }
        token = UUID(); finished = false; presented = false; completion = onCompleted
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(); queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        if active { queue.play() } // decode/preroll; the visible pass restarts at first displayed frame
    }
    func didPresentFirstFrame(for expected: AVQueuePlayer? = nil) {
        guard expected == nil || expected === player, !presented else { return }
        presented = true
        if active { playFullVisiblePass() }
    }
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        finishTask?.cancel(); finishTask = nil
        if !value { player?.pause() }
        else if presented { playFullVisiblePass() }
        else { player?.play() }
    }
    private func playFullVisiblePass() {
        guard !finished, let queue = player else { return }
        finishTask?.cancel(); queue.pause()
        let current = token
        finishTask = Task { @MainActor in
            await queue.seek(to: .zero)
            guard !Task.isCancelled, current == token, active, player === queue,
                  let item = queue.currentItem else { return }
            let endings = NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            queue.play()
            for await _ in endings {
                guard !Task.isCancelled, current == token, active, presented, !finished, player === queue else { return }
                finished = true; queue.pause()
                let done = completion; completion = nil; done?()
                return
            }
        }
    }
    func stop() {
        token = UUID(); finishTask?.cancel(); finishTask = nil
        player?.pause(); looper?.disableLooping(); looper = nil
        player?.removeAllItems(); player = nil
        completion = nil; presented = false
    }
}

struct LeanIntroductionAnimation: View {
    let solo: Bool
    let completed: () -> Void
    var posterOnly = false
    var resourceName = "lean-introduction"
    var demonstratesJumpDuck = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = LeanIntroductionPlayback()
    @State private var posterFallback = false

    var body: some View {
        GeometryReader { proxy in
            let fullWidth = solo ? proxy.size.width * 2 : proxy.size.width
            Group {
                if let player = playback.player, !reduceMotion, !posterOnly {
                    LeanPlayerLayer(player: player, ready: { playback.didPresentFirstFrame(for: player) })
                } else {
                    Image(resourceName + "-poster").resizable().scaledToFit()
                }
            }
            .frame(width: fullWidth, height: proxy.size.height)
            .mask(alignment: .leading) { Rectangle().frame(width: solo ? fullWidth / 2 : fullWidth) }
            .offset(x: solo ? -fullWidth * 0.08 : 0)
        }
        .clipped()
        .accessibilityLabel(demonstratesJumpDuck ? "Mascots demonstrating jumping and ducking" : (solo ? "One mascot demonstrating leaning left and right" : "Two mascots demonstrating leaning left and right"))
        .accessibilityIdentifier("leanIntroductionAnimation")
        .accessibilityValue(reduceMotion || posterOnly || posterFallback ? "Static poster" : "Silent video")
        .task(id: "\(reduceMotion || posterOnly)-\(scenePhase == .active)-\(posterFallback)") {
            let active = scenePhase == .active
            if reduceMotion || posterOnly || posterFallback {
                playback.stop()
                guard active else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                completed() // finite accessible poster presentation, not movement success
            } else {
                playback.start(url: Bundle.main.url(forResource: resourceName, withExtension: "mov"), onCompleted: completed)
                playback.setActive(active)
                if playback.player == nil { posterFallback = true }
            }
        }
        .onChange(of: scenePhase) { _, phase in playback.setActive(phase == .active) }
        .onDisappear { playback.stop() }
    }
}

private struct LeanPlayerLayer: UIViewRepresentable {
    let player: AVQueuePlayer
    let ready: @MainActor () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView(); view.isOpaque = false; view.backgroundColor = .clear
        view.playerLayer.isOpaque = false; view.playerLayer.backgroundColor = UIColor.clear.cgColor
        view.playerLayer.videoGravity = .resizeAspect; view.playerLayer.player = player
        let callback = ready
        context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            if layer.isReadyForDisplay { Task { @MainActor in callback() } }
        }
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: LayerView, coordinator: Coordinator) {
        coordinator.observation?.invalidate(); coordinator.observation = nil; view.playerLayer.player = nil
    }
    final class Coordinator { var observation: NSKeyValueObservation? }
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
