//
//  LiveAvatarLabView.swift
//  Sedactive
//

#if DEBUG
import RealityKit
import SwiftUI

/// Debug-only Live Avatar Lab screen. Opens from the Play screen's "Live
/// Avatar Lab" button or with the `-liveAvatarLab` launch argument; Close
/// stops the camera and returns to the game.
struct LiveAvatarLabView: View {
    let close: () -> Void
    @State private var model = LiveAvatarLabModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            await model.install(on: content)
        }
        .ignoresSafeArea()
        .background(.black)
        .overlay(alignment: .topLeading) { diagnostics }
        .overlay(alignment: .topTrailing) { controls }
        .overlay(alignment: .bottomLeading) { SkeletonPreview(people: model.people).padding() }
        .overlay(alignment: .bottom) { playerChips }
        .overlay(alignment: .bottomTrailing) { roundPanel }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            // The camera never runs in the background; a fresh capture starts on return.
            // `.inactive` (Control Center, a banner) keeps it running.
            switch phase {
            case .background: Task { await model.stop() }
            case .active: Task { await model.start() }
            default: break
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LIVE AVATAR LAB · front camera · Debug").font(.caption.bold())
            Text("Camera: \(model.cameraStatus)")
            Text("Vision \(String(format: "%.1f", model.visionFPS)) fps · people \(model.people.count) · frames \(model.framesProcessed)")
            Text("capture→pose p50 \(ms(model.captureToVision.percentile(0.5)))")
            Text("capture→avatar p50 \(ms(model.captureToAvatar.percentile(0.5))) · p95 \(ms(model.captureToAvatar.percentile(0.95)))")
            Text("avatar→next render p50 \(ms(model.avatarToRender.percentile(0.5))) (display latency not measured)")
            Text("drops: stale \(model.staleDrops) · order \(model.orderDrops) · camera \(model.cameraDrops) · superseded \(model.cameraSuperseded)")
            Text("feet: \(model.feet)")
            Text(model.calibrationText).font(.caption.bold()).foregroundStyle(.yellow)
            if model.calibrationProgress > 0, model.calibrationProgress < 1 {
                ProgressView(value: model.calibrationProgress).frame(width: 220)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
        .padding()
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button("Close lab") {
                Task {
                    await model.close()
                    close()
                }
            }
            .buttonStyle(.borderedProminent)
            Picker("Players", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("1 player").tag(LiveAvatarMode.single)
                Text("2 players").tag(LiveAvatarMode.two)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Picker("Jump", selection: Binding(get: { model.jumpTuning.name }, set: { model.setJumpTuning(.named($0)) })) {
                Text("Jump: tuned").tag(LiveJumpTuning.tuned.name)
                Text("original").tag(LiveJumpTuning.original.name)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Picker("Feet", selection: Binding(get: { model.footPlanting }, set: { model.setFootPlanting($0) })) {
                Text("Feet: planted").tag(true)
                Text("legacy").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Button("Recalibrate") { model.beginCalibration() }
                .buttonStyle(.bordered)
                .disabled(model.roundActive)
            if model.roundActive {
                Button("Stop round") { model.stopRound() }
                    .buttonStyle(.bordered)
            } else {
                Button(model.mode == .single ? "Start round (solo test)" : "Start co-op round") { model.startRound() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartRound)
            }
        }
        .padding()
    }

    private var playerChips: some View {
        HStack(spacing: 16) {
            ForEach(model.mode.players, id: \.self) { player in
                let s = model.players[player] ?? .init()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(player == .player1 ? "P1 (screen left)" : "P2 (screen right)") · \(s.calibrated ? (s.tracked ? "tracked" : "NOT TRACKED") : "not calibrated")")
                        .font(.caption.bold())
                        .foregroundStyle(s.tracked ? .green : .orange)
                    Text("\(s.move) · lift \(s.liftCM) cm · crouch \(s.crouchCM) cm")
                    Text("arms L \(s.leftArm)° R \(s.rightArm)° · lean \(s.lean)°")
                    if !s.jump.isEmpty { Text(s.jump).foregroundStyle(.cyan) }
                    if !s.feet.isEmpty { Text(s.feet).foregroundStyle(.mint) }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
            }
        }
        .padding(.bottom, 24)
    }

    /// The live round: status, the next laser's requirement, and the checker's
    /// last verdicts with their evidence (kept small, away from the robots).
    @ViewBuilder private var roundPanel: some View {
        if model.roundActive || !model.reportLines.isEmpty || !model.roundText.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.roundText).font(.caption.bold())
                if !model.nextTargetText.isEmpty { Text(model.nextTargetText).foregroundStyle(.yellow) }
                ForEach(Array(model.reportLines.suffix(4).enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(line.contains("CLEAR") ? .green : line.contains("HIT") ? .red : .orange)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(8)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
            .padding(.trailing)
            .padding(.bottom, 96)
        }
    }

    private func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "—" }
}

/// Detected joints as the players see them (mirrored once, like the avatar),
/// coloured by assigned player. Joint dots only: no camera image is shown or kept.
private struct SkeletonPreview: View {
    let people: [(player: PlayerID?, person: LivePerson)]
    private static let bones: [(LiveJoint, LiveJoint)] = [
        (.neck, .nose), (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.neck, .root), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        Canvas { context, size in
            for (player, person) in people {
                let color: Color = player == .player1 ? .cyan : player == .player2 ? .pink : .gray
                func at(_ p: LivePoint) -> CGPoint { CGPoint(x: (1 - p.x) * size.width, y: (1 - p.y) * size.height) }
                for (a, b) in Self.bones {
                    guard let pa = person.point(a), let pb = person.point(b) else { continue }
                    var path = Path()
                    path.move(to: at(pa)); path.addLine(to: at(pb))
                    context.stroke(path, with: .color(color), lineWidth: 2)
                }
                for (joint, p) in person.joints where p.confidence >= 0.3 {
                    let r: CGFloat = joint == .leftWrist || joint == .rightWrist ? 4 : 2.5
                    context.fill(Path(ellipseIn: CGRect(x: at(p).x - r, y: at(p).y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(joint.rawValue.hasPrefix("left") ? .yellow : color))
                }
            }
        }
        .frame(width: 256, height: 144)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("pose (mirrored view) · yellow = player's LEFT").font(.caption2).foregroundStyle(.white).padding(4)
        }
    }
}
#endif
