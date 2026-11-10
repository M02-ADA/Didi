//
//  LaserHeistDesign.swift
//  Sedactive
//

import SwiftUI

/// Shared look of the LaserHeist screens (Sketch "Hi-Fi Revisi 6 NOV"): the
/// palette, the 1210 × 834 pt artboard every screen is laid out in, and the
/// Sketch buttons. Values are read from the Sketch layers, not estimated.
enum LaserHeistDesign {
    /// The Sketch artboard: an 11-inch iPad in landscape.
    static let artboard = CGSize(width: 1210, height: 834)

    /// Artboard background behind every screen.
    static let night = Color(sketch: 0x161436)
    /// Cream text on the Home and End screens.
    static let cream = Color(sketch: 0xFEE3BB)
    /// Icon colour on the orange buttons.
    static let iconCream = Color(sketch: 0xFCE7CC)
    /// The score panel.
    static let panel = Color(sketch: 0x1D1B3C)
    static let panelEdge = Color(sketch: 0x161432)

    /// Orange action buttons (body gradient, top rim, bottom base).
    static let orangeTop = Color(sketch: 0xEAA752)
    static let orangeBottom = Color(sketch: 0xE97132)
    static let orangeRim = Color(sketch: 0xFFDFBF)
    static let orangeBase = Color(sketch: 0xD75C41)

    /// The START MISSION! button.
    static let startTop = Color(sketch: 0xEAA551)
    static let startBottom = Color(sketch: 0xE97333)
    static let startEdgeTop = Color(sketch: 0xE2DDD9)
    static let startEdgeBottom = Color(sketch: 0xEA7937)
    static let startBase = Color(sketch: 0x221F4A)
}

extension Color {
    /// An sRGB colour from a Sketch hex value, such as `0x161436`.
    init(sketch hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Lays a screen out in Sketch artboard points. The artboard is scaled to fit
/// the screen and centred; `k` converts Sketch points to screen points. The
/// background fills the whole screen, beyond the artboard on other iPad sizes.
struct SketchArtboard<Background: View, Content: View>: View {
    /// The artboard's night blue under the background; off for overlays.
    var opaque = true
    @ViewBuilder var background: () -> Background
    @ViewBuilder var content: (_ k: CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let k = min(proxy.size.width / LaserHeistDesign.artboard.width,
                        proxy.size.height / LaserHeistDesign.artboard.height)
            ZStack {
                if opaque { LaserHeistDesign.night }
                background()
                ZStack(alignment: .topLeading) {
                    Color.clear
                    content(k)
                }
                .frame(width: LaserHeistDesign.artboard.width * k, height: LaserHeistDesign.artboard.height * k)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Places a layer at its Sketch frame inside a `SketchArtboard`.
    func sketchFrame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, k: CGFloat) -> some View {
        frame(width: width * k, height: height * k).offset(x: x * k, y: y * k)
    }

    /// Full-screen artwork, scaled to fill and centred, as Sketch crops it.
    func sketchBackdrop() -> some View {
        modifier(SketchBackdrop())
    }
}

private struct SketchBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The background shared by the Set Up and End screens: the sunburst over night blue.
struct SunburstBackground: View {
    var body: some View {
        Image("LaserHeistUI/sunburst")
            .resizable()
            .scaledToFill()
            .sketchBackdrop()
    }
}

/// A rectangle with its corners cut at 45°, the Sketch "angled" corner style.
nonisolated struct ChamferedRectangle: InsettableShape {
    var chamfer: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(chamfer - inset * 0.414, min(r.width, r.height) / 2))
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> ChamferedRectangle {
        ChamferedRectangle(chamfer: chamfer, inset: inset + amount)
    }
}

/// The Sketch three-layer pill button: a light rim shows above the gradient
/// body and a darker base below it. Pressing sinks the body onto its base.
struct LayeredPillButtonStyle: ButtonStyle {
    var top: Color
    var bottom: Color
    var rim: Color
    var base: Color
    /// Sketch points of rim above and base below the body, at artboard scale.
    var rimHeight: CGFloat
    var baseHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.top, rimHeight)
            .padding(.bottom, baseHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    VStack(spacing: 0) {
                        rim
                        base
                    }
                    .clipShape(Capsule())
                    // The body covers the rim and base except for their visible edges.
                    LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                        .clipShape(Capsule())
                        .padding(.top, rimHeight)
                        .padding(.bottom, baseHeight)
                }
            }
            .compositingGroup()
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The Sketch two-tone capsule (End screen buttons): a gradient body with a
/// gradient inside border and a soft drop shadow.
struct GradientCapsuleButtonStyle: ButtonStyle {
    var top: Color
    var bottom: Color
    var edgeTop: Color
    var edgeBottom: Color
    var edgeWidth: CGFloat
    var k: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [edgeTop, edgeBottom], startPoint: .top, endPoint: .bottom),
                                            lineWidth: edgeWidth))
            .shadow(color: .black.opacity(0.25), radius: 4 * k, x: 0, y: 4 * k)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// The circular back control in the top-left corner of the Set Up screens
/// (Sketch "Stack 4": a glass capsule around an SF Symbol arrow).
struct SketchBackButton: View {
    let k: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 31.1 * k, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 69 * k, height: 61 * k)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Back")
        .accessibilityIdentifier("navigationBack")
    }
}
