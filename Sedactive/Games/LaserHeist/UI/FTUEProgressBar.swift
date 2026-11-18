import SwiftUI

/// Approved FTUE geometry, with a presentation-only journey supplied by its tutorial owner.
/// The existing HUD owns this slot; its normal gameplay renderer remains separate.
struct FTUEProgressBar: View {
    let k: CGFloat
    var journey: FTUEProgressJourney? = nil

    var body: some View {
        GeometryReader { track in
            let width = track.size.width
            let height = 65 * k
            let start = GameplayHUDModel.fillStart * width
            ZStack(alignment: .topLeading) {
                HUDSurface(shape: Capsule(), k: k).accessibilityHidden(true)
                Capsule()
                    .fill(LinearGradient(colors: [GameplayHUD.railTop, GameplayHUD.railBottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: GameplayHUDModel.diamondPosition * width - start, height: 8 * k)
                    .offset(x: start, y: height / 2 - 4 * k)
                    .accessibilityHidden(true)
                // Same initial 100-point accent; later endpoints come only from FTUE milestones.
                Capsule()
                    .fill(LinearGradient(colors: [GameplayHUD.fillTop, GameplayHUD.fillBottom], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 4 * k, y: 4 * k)
                    .frame(width: max(0, (journey?.fillEnd ?? FTUEProgressJourney.initial) * width - start), height: 32 * k)
                    .offset(x: start, y: height / 2 - 16 * k)
                    .accessibilityHidden(true)
                // Existing checkpoint artwork matches Asset 30's cream/dark-purple circular treatment.
                Image("LaserHeistHUD/checkpoint")
                    .resizable().frame(width: 24 * k, height: 24 * k * 130 / 123)
                    .position(x: width / 2, y: height / 2)
                    .accessibilityLabel("Static tutorial checkpoint")
                    .accessibilityIdentifier("ftueCenterCheckpoint")
                Image("LaserHeistHUD/progress-diamond")
                    .resizable().frame(width: 29 * k, height: 26 * k)
                    .position(x: GameplayHUDModel.diamondPosition * width, y: height / 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 65 * k)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial progress artwork")
        .accessibilityValue(String(format: "Tutorial fill endpoint %.3f", journey?.fillEnd ?? FTUEProgressJourney.initial))
        .accessibilityIdentifier("ftueProgressBar")
    }
}
