import SwiftUI
import Testing
@testable import Sedactive

@MainActor struct HomeTutorialHelpTests {
    @Test(arguments: [CGFloat(1), CGFloat(1376.0 / 1210)])
    func controlHasReadableCircularTouchTargetAtBothIPadScales(k: CGFloat) throws {
        let renderer = ImageRenderer(content: HomeTutorialHelpButton(k: k, action: {}))
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        #expect(abs(image.size.width - 78 * k) < 1)
        #expect(abs(image.size.height - image.size.width) < 1)
        #expect(image.size.width >= 44 && image.size.height >= 44)
    }
}
