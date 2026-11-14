//
//  MaskBenchmarkOverlay.swift
//  Sedactive
//

#if DEBUG
import CoreGraphics
import SwiftUI

/// DEBUG mask feasibility spike (Kevin, 14 November 2026): the solo test script prompt and an
/// optional inspection panel. Read-only: it shows what `MaskBenchmarkRecorder` measured and never
/// feeds tracking, calibration, judging or the mascots. Shown only with `-maskBenchScript` or
/// `-maskBenchOverlay`; leave `-maskBenchOverlay` off for performance runs.
struct MaskBenchmarkOverlay: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let snapshot = MaskBenchmark.recorder.overlay(now: CameraHostClock.now()) {
                VStack(alignment: .leading, spacing: 8) {
                    if let script = snapshot.script { prompt(script) }
                    if MaskBenchmark.configuration?.overlay == true { panel(snapshot) }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.lines, id: \.self) { Text($0) }
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.65), in: .rect(cornerRadius: 6))
                }
                .padding(12)
                .allowsHitTesting(false)
            }
        }
    }

    /// Big enough to read from 2–3 m.
    private func prompt(_ position: MaskBenchScript.Position) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(position.instruction)
                .font(.system(size: 34, weight: .bold))
            Text(position.prompting ? (position.remaining > 0 ? String(format: "starts in %.0f s", position.remaining.rounded(.up)) : "")
                 : position.name == "free" ? "" : String(format: "%@ · %.0f s left", position.name, position.remaining.rounded(.up)))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(position.prompting ? .yellow : .white)
        .padding(12)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
    }

    /// Camera view (NOT mirrored): the followed person's mask in white, anyone else grey, pose
    /// landmarks in green (confidence ≥ 0.5) or red, and the mask's top and bottom as lines.
    private func panel(_ s: MaskBenchmarkRecorder.Overlay) -> some View {
        let size = CGSize(width: 384, height: 216)
        return VStack(alignment: .leading, spacing: 2) {
            Canvas { context, canvas in
                context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(.black.opacity(0.75)))
                if let thumbnail = s.thumbnail, let image = Self.image(thumbnail, size: s.thumbnailSize) {
                    var inner = context
                    inner.opacity = 0.7
                    inner.draw(Image(decorative: image, scale: 1).interpolation(.none), in: CGRect(origin: .zero, size: canvas))
                }
                for (y, color) in [(s.top, Color.cyan), (s.bottom, Color.orange)] {
                    guard let y else { continue }
                    var line = Path()
                    let py = (1 - y) * canvas.height
                    line.move(to: CGPoint(x: 0, y: py)); line.addLine(to: CGPoint(x: canvas.width, y: py))
                    context.stroke(line, with: .color(color), lineWidth: 2)
                }
                for (_, joint) in s.joints {
                    let point = CGPoint(x: joint.x * canvas.width, y: (1 - joint.y) * canvas.height)
                    let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(joint.confidence >= 0.5 ? .green : .red))
                }
            }
            .frame(width: size.width, height: size.height)
            Text(timing(s))
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
        }
        .padding(6)
        .background(.black.opacity(0.65), in: .rect(cornerRadius: 6))
    }

    private func timing(_ s: MaskBenchmarkRecorder.Overlay) -> String {
        let pose = s.poseCapturedAt, mask = s.maskCapturedAt
        let sameFrame = pose != nil && pose == mask
        let lag = pose.flatMap { p in mask.map { (p - $0) * 1000 } }
        return "camera view, not mirrored · pose: \(s.poseSource.rawValue) · "
            + (mask == nil ? "no mask yet" : sameFrame ? "mask = pose frame" : String(format: "mask %.0f ms older than pose", lag ?? 0))
            + " · cyan top, orange bottom"
    }

    private static func image(_ pixels: [UInt8], size: (w: Int, h: Int)) -> CGImage? {
        guard pixels.count == size.w * size.h,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size.w, height: size.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size.w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
