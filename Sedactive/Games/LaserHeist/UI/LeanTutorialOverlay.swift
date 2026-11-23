import SwiftUI

/// Passive tutorial presentation. Progress observes admitted input; navigation belongs to the existing HUD.
struct LeanTutorialOverlay: View {
    let tutorial: LeanTutorial
    let solo: Bool
    var posterOnly = false
    @Environment(\.scenePhase) private var scenePhase

    private struct Presentation: Equatable {
        let generation: UUID
        let phase: ScenePhase
    }

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
                } else if tutorial.stage == .vaultButtonIntroduction, let generation = tutorial.generation {
                    VaultButtonIntroduction(posterOnly: posterOnly) {
                        tutorial.finishVaultButtonIntroduction(generation: generation)
                    }
                    .id(generation)
                } else if tutorial.stage == .diamondCollectionIntroduction, let generation = tutorial.generation {
                    Color.black.opacity(0.55)
                    Image("LaserHeistUI/ftue-diamond-collection")
                        .resizable().scaledToFit()
                        .frame(width: 255 * k)
                        .shadow(color: LaserHeistDesign.cream.opacity(0.16), radius: 18 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.375)
                        .accessibilityHidden(true)
                    Text("Collect as many diamonds as you can!")
                        .font(.system(size: 67 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                        .multilineTextAlignment(.center)
                        .frame(width: 710 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.59)
                        .accessibilityIdentifier("ftueDiamondCollectionTitle")
                        .task(id: Presentation(generation: generation, phase: scenePhase)) {
                            guard scenePhase == .active else { return }
                            do { try await Task.sleep(for: .seconds(4)) } catch { return }
                            guard !Task.isCancelled else { return }
                            tutorial.finishDiamondCollectionIntroduction(generation: generation)
                        }
                } else if let phase = tutorial.progressPhase {
                    ProgressTutorialOverlay(tutorial: tutorial, phase: phase).id(phase)
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
                } else if tutorial.stage == .collectiblesIntroduction {
                    Color.black.opacity(0.55)
                    Image("LaserHeistUI/ftue-collectibles")
                        .resizable().scaledToFit()
                        .frame(width: 250 * k)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.39)
                        .accessibilityHidden(true)
                    Text("Collect some collectibles\nalong the way")
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                        .multilineTextAlignment(.center)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.59)
                        .accessibilityIdentifier("ftueCollectiblesTitle")
                        .task(id: scenePhase) {
                            guard scenePhase == .active, let generation = tutorial.generation else { return }
                            do { try await Task.sleep(for: .seconds(4)) } catch { return }
                            guard !Task.isCancelled else { return }
                            tutorial.finishCollectiblesIntroduction(generation: generation)
                        }
                } else if let kind = tutorial.collection {
                    Color.clear.accessibilityElement().accessibilityLabel("Collect " + kind.rawValue)
                        .accessibilityIdentifier("ftueCollection-" + kind.rawValue)
                } else if tutorial.isPractising {
                    Color.clear.accessibilityElement().accessibilityLabel("Free lean practice")
                        .accessibilityIdentifier("ftueFreeLean")
                        .onAppear {
                            if let generation = tutorial.generation {
                                tutorial.practiceVisible(.freeLean, generation: generation, at: CameraHostClock.now())
                            }
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
