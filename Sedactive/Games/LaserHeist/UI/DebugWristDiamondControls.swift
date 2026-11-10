#if DEBUG
import SwiftUI
import Observation

/// Read-only counts from the REAL K06 presenters after apply; not UI-owned target/score state.
@MainActor @Observable final class DebugDiamondVisualReadout {
    private(set) var normalIDs: Set<UUID> = []
    private(set) var bonusIDs: Set<Int> = []
    private(set) var collections = 0
    private(set) var generation: UUID?
    func record(normal: Set<UUID>, bonus: Set<Int>, collections: Int, generation: UUID?) {
        if normalIDs != normal { normalIDs = normal }
        if bonusIDs != bonus { bonusIDs = bonus }
        if self.collections != collections { self.collections = collections }
        if self.generation != generation { self.generation = generation }
    }
    func clear() { record(normal:[],bonus:[],collections:0,generation:nil) }
    var line: String { "Scene normal \(normalIDs.count) · bonus \(bonusIDs.count) · pickup effects \(collections)" }
}

/// Controls SOURCE delivery time only. All evidence, entry, target and score changes run
/// through ReplayBodyInput → the sole coordinator → J07 → the existing diamond domain.
struct DebugWristDiamondControls: View {
    let session: GameSessionCoordinator
    let readout: DebugDiamondVisualReadout
    @State private var busy = false
    @State private var error: String?
    static func requested(_ arguments: [String]) -> Bool {
        arguments.contains("--synthetic-gameplay-preview") && arguments.contains("--wrist-diamond-preview")
    }
    private var next: (title:String,time:Double,id:String) {
        let t = session.state?.gameTime ?? 0
        if t < 0.875 { return ("Send OUTSIDE",0.875,"wristOutside") }
        if t < 1 { return ("Send INSIDE",1,"wristInside") }
        if t < 1.0625 { return ("Replay same frame",1.0625,"wristDuplicate") }
        if t < 1.5 { return ("Finish pickup effect",1.5,"wristRetireEffect") }
        if t < 2.25 { return ("Open Diamond Time",2.25,"wristBonusStart") }
        if t < 2.5 { return ("Bonus OUTSIDE",2.5,"wristBonusOutside") }
        if t < 2.625 { return ("Bonus INSIDE",2.625,"wristBonusInside") }
        return ("Finish phase at deadline",DebugWristDiamondFixture.deadline,"wristDeadline")
    }
    var body: some View {
        VStack(spacing:6) {
            Text("DEBUG · SYNTHETIC E08 → J07 · NO CAMERA")
                .font(.caption.monospaced().bold()).accessibilityIdentifier("wristFixtureTitle")
            Text(readout.line).font(.caption.monospaced()).accessibilityIdentifier("wristFixtureMeshes")
            Text(session.inputConfiguration.sessionGeneration.uuidString)
                .font(.caption2.monospaced()).accessibilityIdentifier("wristFixtureGeneration")
            HStack {
                Button(next.title) {
                    let time = next.time
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        do { try await session.advance(to:time) } catch { self.error = String(describing:error) }
                    }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier(next.id)
                Button("Stop fixture") {
                    busy = true
                    Task { @MainActor in await session.stop();busy = false }
                }.buttonStyle(.bordered).accessibilityIdentifier("wristFixtureStop")
            }.disabled(busy || session.phase != .running || readout.generation == nil)
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("wristFixtureError") }
        }
        .padding(10).foregroundStyle(.white).background(.black.opacity(0.8),in:.rect(cornerRadius:10))
    }
}
#endif
