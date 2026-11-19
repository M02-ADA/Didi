import SwiftUI
import UIKit
import Testing
@testable import Sedactive

@MainActor struct FTUEProgressBarTests {
    @Test(arguments: [CGSize(width: 1376, height: 1032), CGSize(width: 1210, height: 834)])
    func spotlightTracksTheHUDWithRoomForCopy(viewport: CGSize) {
        let k = viewport.width / 1210
        let bar = CGRect(x: 360 * k, y: 58 * k, width: 667 * k, height: 65 * k)
        let full = ProgressTutorialSpotlightLayout(bar: bar, viewport: viewport, phase: .bar)
        let checkpoint = ProgressTutorialSpotlightLayout(bar: bar, viewport: viewport, phase: .vault)
        #expect(full.highlight.insetBy(dx: full.stroke, dy: full.stroke).contains(bar))
        #expect(checkpoint.highlight.width == checkpoint.highlight.height)
        #expect(checkpoint.highlight.width < bar.width)
        for layout in [full, checkpoint] {
            #expect(abs(layout.highlight.midX - bar.midX) < 0.001)
            #expect(abs(layout.highlight.midY - bar.midY) < 0.001)
            #expect(abs(layout.connector.midX - bar.midX) < 0.001)
            #expect(abs(layout.connector.minY - (layout.highlight.maxY - layout.stroke / 2)) < 0.001)
            #expect(layout.connector.height > 0)
            #expect(layout.connector.maxY < layout.textTop)
        }
        #expect(full.textTop == checkpoint.textTop)
    }

    @Test(arguments: [CGFloat(1), CGFloat(1376.0 / 1210)])
    func artworkContainsOnlyOneCenteredCreamCheckpoint(k: CGFloat) throws {
        let renderer = ImageRenderer(content: FTUEProgressBar(k: k).frame(width: 667 * k, height: 65 * k))
        renderer.scale = 2
        let image = try #require(renderer.uiImage?.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func rgb(_ x: Int) -> (Int, Int, Int) {
            let offset = (height / 2 * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
        let cream = (0..<width).filter { x in
            let (r,g,b) = rgb(x); return r > 225 && g > 220 && b > 150 && b < 225
        }
        let first = try #require(cream.first), last = try #require(cream.last)
        // All cream pixels belong to ONE small central checkpoint, not five gate markers.
        #expect(abs(Double(first + last) / 2 - Double(width) / 2) <= 2)
        #expect(Double(last - first) <= 26 * k * renderer.scale)
        let (r,g,b) = rgb(width / 2)
        #expect(r > 225 && g > 220 && b > 150)
        // The orange accent is the same static visual in either viewport, independent of Lean progress.
        let (red,green,blue) = rgb(Int(60 * k * renderer.scale))
        #expect(red > 200 && green > 75 && blue < 150)
        let (railRed,_,_) = rgb(Int(160 * k * renderer.scale))
        #expect(railRed < 180)
    }
}
