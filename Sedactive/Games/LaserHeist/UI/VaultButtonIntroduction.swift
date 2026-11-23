import ImageIO
import SwiftUI

/// The supplied transparent GIF is decoded once. Rendering selects cached images at the
/// source cadence; view disappearance releases the decoded frames.
struct VaultButtonIntroduction: View {
    static let copy = "Press the buttons\nto open vault door"
    let posterOnly: Bool
    let completed: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: Playback?
    @State private var startedAt: Date?

    var body: some View {
        GeometryReader { proxy in
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            ZStack {
                Color.black.opacity(0.55)
                if let playback {
                    Group {
                        if posterOnly || reduceMotion || scenePhase != .active {
                            artwork(playback.frames[playback.frames.count / 2])
                        } else if let startedAt {
                            TimelineView(.periodic(from: startedAt, by: playback.interval)) { context in
                                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                                let index = Int(elapsed / playback.interval + 0.0001) % playback.frames.count
                                artwork(playback.frames[index])
                            }
                        }
                    }
                    .frame(width: 410 * k, height: 410 * k)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.37)
                    .accessibilityHidden(true)
                }
                Text(Self.copy)
                    .font(.system(size: 67 * k, weight: .bold, design: .rounded))
                    .foregroundStyle(LaserHeistDesign.cream)
                    .multilineTextAlignment(.center)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.63)
                    .accessibilityIdentifier("ftueVaultButtonTitle")
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if playback == nil { playback = Playback() }
            startedAt = .now
            do { try await Task.sleep(for: .seconds(ProgressTutorialPhase.duration)) } catch { return }
            guard !Task.isCancelled else { return }
            completed()
        }
    }

    private func artwork(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
    }

    private struct Playback {
        let frames: [CGImage]
        let interval: Double

        init?() {
            guard let url = Bundle.main.url(forResource: "press_button", withExtension: "gif"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                  let delay = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double,
                  delay > 0 else { return nil }
            let count = CGImageSourceGetCount(source)
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            let decoded = (0..<count).compactMap { CGImageSourceCreateImageAtIndex(source, $0, options) }
            guard count > 0, decoded.count == count else { return nil }
            frames = decoded
            // Every frame of this asset uses the same 220 ms source delay.
            interval = delay
        }
    }
}
