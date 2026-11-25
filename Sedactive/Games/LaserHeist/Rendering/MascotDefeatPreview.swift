//
//  MascotDefeatPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of the cartoon team defeat (`MascotDefeat`) in the game's own corridor, camera
/// and lanes, without a camera feed or a round: launch with
/// `-replay -defeatPreview [solo|p1|p2|both|shared] [reduce] [clean] [seconds]`.
/// - `solo`: Lemon alone (Tangerine's lane hidden, as in Solo). `p1` (default): Lemon's HIT
///   empties the shared health; Lemon reacts first, the failure spreads to Tangerine's board,
///   both boards explode together, both mascots fall. `p2`: the same, Tangerine struck. `both`:
///   both HITs fatal (both react, no spread, one shared boom). `shared`: no single struck player
///   (ambiguous): no beam reaction, every board fails together.
/// - `reduce`: Reduce Motion. `seconds`: hold that moment (0 is the fatal HIT; negative is the
///   idle ride before it). `clean`: no controls, only the time label (screenshots).
/// The strike goes through the scene's own `presentOutcome(.hit)` (the production HIT), then
/// `RobotAvatarLayer.startDefeat`. Every seek replays from the idle ride frame by frame on one
/// clock, so a held moment is deterministic. Presentation review only: no session, verdict,
/// health, score or game time; the Results card here is a stand-in for its timing.
@MainActor @Observable
final class MascotDefeatPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-defeatPreview") }

    enum Mode: String, CaseIterable { case solo, p1, p2, both, shared }

    struct Request {
        var mode = Mode.p1
        var reduceMotion = false
        var heldAt: Double?
        var showsControls = true
    }

    static var requested: Request {
        let arguments = ProcessInfo.processInfo.arguments
        var request = Request()
        guard let index = arguments.firstIndex(of: "-defeatPreview") else { return request }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") || Double($0) != nil }
        request.mode = Mode.allCases.first { rest.contains($0.rawValue) } ?? .p1
        request.reduceMotion = rest.contains("reduce")
        request.heldAt = rest.compactMap(Double.init).first
        request.showsControls = !rest.contains("clean")
        return request
    }

    /// Where the timeline starts: a moment of the idle ride before the fatal HIT.
    static let idleLead = 0.5
    /// How long Results shows before the loop starts over.
    static let resultsHold = 0.8

    /// Seconds since the fatal HIT (negative: the idle ride before it).
    private(set) var time = -idleLead
    var isPlaying = true
    private(set) var request = Request()

    @ObservationIgnored private weak var scene: LaserScene?
    @ObservationIgnored private weak var robots: RobotAvatarLayer?
    @ObservationIgnored private var subscription: EventSubscription?
    /// The mascots' own render clock (one clock for the body, the board and the pop).
    @ObservationIgnored private var clock = 0.0

    /// The timeline of the mascot whose defeat leads (for the labels and Results timing).
    var lead: MascotDefeat {
        MascotDefeat(role: request.mode == .shared ? .teammate : .struck, side: request.mode == .p2 ? 1 : -1,
                     reduceMotion: request.reduceMotion, spreads: request.mode != .shared)
    }
    var resultsTime: Double { lead.resultsTime }
    var end: Double { resultsTime + Self.resultsHold }

    /// The Results stand-in: fades in over `MascotDefeat.resultsFade`, fully shown at `resultsTime`.
    var resultsOpacity: Double { MascotDefeat.smooth(resultsTime - MascotDefeat.resultsFade, resultsTime, time) }

    var phase: String {
        let t = time
        if t < 0 { return "idle" }
        if t < MascotDefeat.overloadStart { return request.mode == .shared ? "round lost" : "1 · fatal HIT" }
        if t < MascotDefeat.windUp {
            return t >= MascotDefeat.spreadStart && (request.mode == .p1 || request.mode == .p2) ? "2 · shared overload (spreads)" : "2 · overload"
        }
        if t < MascotDefeat.popTime { return "2 · wind-up" }
        if t < MascotDefeat.popTime + 0.03 { return "3 · BOOM (explosion peak)" }
        if t < MascotDefeat.vanishTime { return "4 · boards vanish" }
        if t < lead.landTime - 0.02 { return request.reduceMotion ? "5 · sinking" : "5 · mid-air" }
        if t < lead.settledTime { return "6 · landing" }
        if t < resultsTime - MascotDefeat.resultsFade { return "7 · defeat pose" }
        return "results"
    }

    func start(on content: RealityViewCameraContent, scene: LaserScene, robots: RobotAvatarLayer, request: Request) {
        self.request = request
        self.scene = scene
        self.robots = robots
        RobotAvatarLayer.forcesReducedMotionForHits = request.reduceMotion
        RobotAvatarLayer.previewShowsTracked = true
        robots.smoothing = 0.03
        robots.drivesDefeatOnItsOwn = false // this preview renders every frame on its own clock
        if request.mode == .solo { scene.players[.player2]?.isEnabled = false }
        // The fatal beam: a high one (a missed DUCK) at the mascots' plane, as in the HIT preview.
        scene.setLaserBand(lowerEdge: 1.239, upperEdge: 1.261)
        scene.setLaserDepth(scene.mapping.interactionPlaneZ)
        scene.setLaserDangerSide(.above)
        scene.setLaserVisualState(.active)
        seek(to: request.heldAt ?? -Self.idleLead)
        isPlaying = request.heldAt == nil
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(event.deltaTime)
        }
    }

    func togglePlaying() {
        if !isPlaying, time >= end { seek(to: -Self.idleLead) }
        isPlaying.toggle()
    }

    /// Replays from the idle ride up to `target`, frame by frame (deterministic).
    func seek(to target: Double) {
        guard let robots else { return }
        robots.cancelDefeats()
        robots.cancelHitReactions()
        clock = 0
        for _ in 0..<30 { render(1.0 / 60) } // settle the rest pose and boards
        time = -Self.idleLead
        scene?.isLaserVisible = true
        let step = 1.0 / 60
        while time + step <= target { advance(step) }
        if target > time { advance(target - time) }
    }

    private func tick(_ dt: Double) {
        guard isPlaying else { robots?.render(now: clock); return } // the held moment, every frame
        if time + dt > end { seek(to: -Self.idleLead); return }
        advance(dt)
    }

    private func advance(_ dt: Double) {
        let before = time
        if before < 0, before + dt >= 0 {
            // Land the strike exactly on t = 0, so the defeat's own clock and `time` agree.
            time = 0
            render(-before)
            strike()
            robots?.render(now: clock)
            if dt + before > 0 { advance(dt + before) }
            return
        }
        time += dt
        // The beam passes: it is gone shortly after the strike.
        scene?.isLaserVisible = time < 0.3
        render(dt)
    }

    private func render(_ dt: Double) {
        clock += dt
        robots?.render(now: clock)
    }

    /// The fatal HIT through the production path (only for a player actually struck), then each
    /// mascot's part in the team defeat, all in this one frame (one shared boom).
    private func strike() {
        guard let scene, let robots else { return }
        let struck: [PlayerID] = switch request.mode {
        case .solo, .p1: [.player1]
        case .p2: [.player2]
        case .both: [.player1, .player2]
        case .shared: []
        }
        for player in struck { scene.presentOutcome(.hit, for: player) }
        let team: [PlayerID] = request.mode == .solo ? [.player1] : PlayerID.allCases
        for player in team {
            robots.startDefeat(player, as: struck.contains(player) ? .struck : .teammate, spreads: !struck.isEmpty)
        }
    }
}

/// The preview's controls and its Results stand-in (DEBUG only).
struct MascotDefeatPreviewControls: View {
    let preview: MascotDefeatPreview

    var body: some View {
        ZStack(alignment: .bottom) {
            // Stand-in for the Results screen's arrival (timing only; not the real card).
            Color.black.opacity(0.55 * preview.resultsOpacity)
                .overlay {
                    Text("RESULTS")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .opacity(preview.resultsOpacity)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                Text(String(format: "t = %+.2f s · %@%@", preview.time, preview.phase,
                            preview.request.reduceMotion ? " · Reduce Motion" : ""))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                if preview.request.showsControls {
                    HStack(spacing: 12) {
                        Button(preview.isPlaying ? "Pause" : "Play") { preview.togglePlaying() }
                            .buttonStyle(.borderedProminent)
                        Slider(value: Binding(get: { preview.time }, set: { preview.isPlaying = false; preview.seek(to: $0) }),
                               in: -MascotDefeatPreview.idleLead...preview.end)
                    }
                    .padding(12)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 640)
                }
            }
            .padding(.bottom, 24)
            .padding(.horizontal, 16)
        }
    }
}
#endif
