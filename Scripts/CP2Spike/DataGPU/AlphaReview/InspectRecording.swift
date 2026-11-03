import AVFoundation
import AppKit
import Foundation

@main struct InspectRecording {
  static func main() async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .video)
    print("duration", duration, "seconds")
    for t in tracks {
      print("track", try await t.load(.naturalSize), "fps", try await t.load(.nominalFrameRate))
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    for (index, t) in [0.5, duration / 2, max(0, duration - 0.5)].enumerated() {
      let result = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
      let rep = NSBitmapImageRep(cgImage: result.image)
      try rep.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: "/private/tmp/cp2-alpha/recording-\(index).png"))
      print(index, "requested", t, "actual", result.actualTime.seconds)
    }
  }
}
