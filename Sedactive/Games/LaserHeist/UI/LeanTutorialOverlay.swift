import SwiftUI

/// Passive tutorial presentation. Progress observes admitted input; navigation belongs to the existing HUD.
struct LeanTutorialOverlay: View {
    let tutorial: LeanTutorial
    let solo: Bool
    var posterOnly = false

    var body: some View {
        GeometryReader { proxy in
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            ZStack {
                if tutorial.stage == .introduction || tutorial.stage == .jumpDuckIntroduction {
                    // The host applies a small blur only during this introduction. Darken
                    // without a second live backdrop filter, keeping the mascots recognizable.
                    Color.black.opacity(0.55)
                    LeanIntroductionAnimation(solo: solo, completed: {
                        if let generation = tutorial.generation {
                            if tutorial.stage == .jumpDuckIntroduction { tutorial.finishJumpDuckIntroduction(generation: generation) }
                            else { tutorial.finishIntroduction(generation: generation) }
                        }
                    }, posterOnly: posterOnly, resourceName: tutorial.stage == .jumpDuckIntroduction ? "jump-duck-introduction" : "lean-introduction", demonstratesJumpDuck: tutorial.stage == .jumpDuckIntroduction)
                    .onAppear { if let generation = tutorial.generation { tutorial.introductionVisible(true, generation: generation) } }
                    .onDisappear { if let generation = tutorial.generation { tutorial.introductionVisible(false, generation: generation) } }
                        .frame(width: (solo ? 330 : 660) * k, height: 455 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.34)
                    Text(tutorial.stage == .jumpDuckIntroduction ? "Jump or Duck\nto avoid the lasers" : "Lean your head\nto move left and right")
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream).multilineTextAlignment(.center)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.61)
                        .accessibilityIdentifier("leanTutorialTitle")
                } else if let phase = tutorial.heartPhase {
                    let heartGeneration = tutorial.generation
                    HeartTutorialOverlay(phase: phase, healthFrame: tutorial.healthHUDFrame,
                        onVisibilityChange: { visible in
                            if let heartGeneration { tutorial.heartVisible(phase, visible: visible, generation: heartGeneration) }
                        }, completed: {
                            if let heartGeneration { tutorial.finishHeart(phase, generation: heartGeneration) }
                        })
                        .id(phase)
                } else if let move = tutorial.practiceMove {
                    Color.clear.accessibilityElement().accessibilityLabel(move == .jump ? "JUMP practice" : "DUCK practice")
                        .accessibilityIdentifier("ftueLaserPractice")
                } else {
                    if let placement = LeanCuePlacement.make(viewport: proxy.size, headTopFraction: tutorial.headTopFraction) {
                        Image(uiImage: tutorial.stage == .practiceLeft ? LeanInstructionArtwork.left : LeanInstructionArtwork.right)
                            .resizable().frame(width: placement.frame.width, height: placement.frame.height)
                            .position(x: placement.frame.midX, y: placement.frame.midY)
                            .accessibilityLabel(tutorial.stage == .practiceLeft ? "← LEAN LEFT" : "LEAN RIGHT →")
                            .accessibilityIdentifier("leanTutorialTitle")
                            .task(id: tutorial.stage) {
                                if let generation = tutorial.generation {
                                    tutorial.practiceVisible(tutorial.stage, generation: generation, at: CameraHostClock.now())
                                }
                            }
                    } else {
                        ProgressView("Preparing movement guide…").tint(.white)
                    }
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Match the full-bleed RealityView projection space; the prior safe-area inset
        // added 24 points to otherwise correct projected positions on the iPad Simulator.
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .allowsHitTesting(false)
    }
}
