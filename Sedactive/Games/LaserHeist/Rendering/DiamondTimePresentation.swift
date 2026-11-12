//
//  DiamondTimePresentation.swift
//  Sedactive
//

import Foundation
import RealityKit

/// One diamond as Diamond Time presents it: where it floats beside a player
/// and whether it has been collected. The production source is J05's
/// committed diamond events (Jevon), which do not exist yet; until then only
/// the labelled Debug fixture (`DiamondTimeFixture`) supplies diamonds. A
/// diamond's collection is never inferred here from what overlaps on screen.
struct DiamondTimeDiamond: Equatable, Identifiable {
    let id: Int
    /// The lane the diamond floats in.
    let lane: PlayerID
    /// Sideways from the lane centre, in game units (+ = screen right).
    let offsetX: Float
    /// Height above the calibrated floor, in game units.
    let heightAboveFloor: Float
    var collected: Bool
}

/// Presents Diamond Time's diamonds in the corridor (Sketch Hi-Fi 30 OCT
/// "Diamond Time"), from a list it is given at each update. Kevin owns this;
/// spawning, collection, scoring and the Diamond Time clock are Jevon's (J05).
/// It keeps no clock: the list is a function of game time since the
/// authoritative `phaseChanged(.diamondTime)` event.
@MainActor
final class DiamondTimePresentation {
    /// The diamonds for a time (seconds of Diamond Time elapsed). `nil`: no
    /// source, nothing shown (production until J05 lands).
    var source: ((Double) -> [DiamondTimeDiamond])?
    /// Whether the diamonds shown come from the Debug fixture (labelled in the HUD).
    private(set) var isFixture = false
    /// Diamonds shown being collected so far (for the pickup sound).
    private(set) var collections = 0

    private let scene: LaserScene
    private var shown: [Int: (diamond: Diamond, collected: Bool, until: Double?)] = [:]
    /// Collected diamonds still playing their pickup; removed once it has played.
    private var leaving: [(diamond: Diamond, until: Double)] = []

    init(scene: LaserScene) {
        self.scene = scene
        #if DEBUG
        if DiamondTimeFixture.isRequested {
            source = DiamondTimeFixture.diamonds(elapsed:)
            isFixture = true
        }
        #endif
    }

    /// Diamond ids currently floating (not collected), for tests and debugging.
    var floatingIDs: Set<Int> { Set(shown.filter { !$0.value.collected }.keys) }

    /// - Parameter hidden: shows none yet (the final vault entry still plays).
    func update(state: LaserGameState, diamondTimeStartedAt start: Double?, hidden: Bool = false) {
        let time = state.gameTime
        for item in leaving where time >= item.until { item.diamond.retire() }
        leaving.removeAll { time >= $0.until }
        guard state.phase == .diamondTime, !hidden, let start, let source else { return clear() }
        for (id, item) in shown where item.until.map({ time >= $0 }) == true {
            item.diamond.retire()
            shown[id] = nil
        }
        let wanted = source(max(0, time - start))
        let ids = Set(wanted.map(\.id))
        for (id, item) in shown where !ids.contains(id) {
            if !item.collected { item.diamond.remove() }
            leaving.append((item.diamond, time + Diamond.effectLifetime))
            shown[id] = nil
        }
        for diamond in wanted {
            if let item = shown[diamond.id] {
                if diamond.collected, !item.collected {
                    item.diamond.collect()
                    collections += 1
                    shown[diamond.id]?.collected = true
                    shown[diamond.id]?.until = time + Diamond.effectLifetime
                }
                continue
            }
            guard !diamond.collected, let entity = scene.makeDiamond() else { continue }
            var position = scene.mapping.playerPosition(diamond.lane, heightAboveFloor: diamond.heightAboveFloor)
            position.x += diamond.offsetX * scene.mapping.metersPerGameUnit
            position.z += 0.15
            entity.root.position = position
            entity.root.name = "diamondTime.diamond.\(diamond.id)"
            entity.showIdle()
            shown[diamond.id] = (entity, false, nil)
        }
    }

    /// Removes every diamond at once (phase over, round ended, presenter stopped).
    func clear() {
        for item in shown.values { item.diamond.retire() }
        for item in leaving { item.diamond.retire() }
        shown = [:]
        leaving = []
    }
}

#if DEBUG
/// SYNTHETIC FIXTURE (Debug only, `-diamondFixture`): a scripted Diamond Time
/// so its presentation can be reviewed before J05. Not gameplay: no points
/// are awarded, the team score stays Jevon's, and nothing here is derived
/// from body evidence. At most four diamonds float at once (G B4a); each
/// scripted pickup is replaced elsewhere.
enum DiamondTimeFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-diamondFixture") }

    private struct Entry {
        let id: Int
        let lane: PlayerID
        let offsetX: Float
        let height: Float
        let appearsAt: Double
        let collectedAt: Double?
    }

    /// Reach positions beside each mascot (game units): high outside, low inside.
    private static let entries: [Entry] = [
        Entry(id: 1, lane: .player1, offsetX: -0.55, height: 1.7, appearsAt: 0, collectedAt: 2.5),
        Entry(id: 2, lane: .player1, offsetX: 0.45, height: 0.95, appearsAt: 0, collectedAt: 5.5),
        Entry(id: 3, lane: .player2, offsetX: 0.55, height: 1.7, appearsAt: 0, collectedAt: 4.0),
        Entry(id: 4, lane: .player2, offsetX: -0.45, height: 0.95, appearsAt: 0, collectedAt: 7.0),
        Entry(id: 5, lane: .player1, offsetX: -0.6, height: 1.3, appearsAt: 2.8, collectedAt: 8.5),
        Entry(id: 6, lane: .player2, offsetX: 0.6, height: 1.3, appearsAt: 4.3, collectedAt: nil),
        Entry(id: 7, lane: .player1, offsetX: 0.5, height: 1.65, appearsAt: 5.8, collectedAt: nil),
        Entry(id: 8, lane: .player2, offsetX: -0.5, height: 1.6, appearsAt: 7.3, collectedAt: nil),
    ]

    /// Diamonds in play after `elapsed` seconds of Diamond Time; a collected
    /// one stays listed (collected) for its pickup to play.
    static func diamonds(elapsed: Double) -> [DiamondTimeDiamond] {
        entries.compactMap { entry in
            guard elapsed >= entry.appearsAt else { return nil }
            let collected = entry.collectedAt.map { elapsed >= $0 } ?? false
            if let at = entry.collectedAt, elapsed >= at + 0.5 { return nil }
            return DiamondTimeDiamond(id: entry.id, lane: entry.lane, offsetX: entry.offsetX,
                                      heightAboveFloor: entry.height, collected: collected)
        }
    }

    /// Scripted pickups so far (for the HUD's labelled fixture counter).
    static func collectedCount(elapsed: Double) -> Int {
        entries.filter { $0.collectedAt.map { elapsed >= $0 } ?? false }.count
    }
}
#endif
