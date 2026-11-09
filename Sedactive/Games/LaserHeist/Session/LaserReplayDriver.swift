import Foundation

/// Synthetic source composition and scripted actions. None of these controls enter CP1 or live input.
@MainActor
final class LaserReplayDriver {
    let script: LaserReplayScript
    let provider: ReplayBodyInput
    private var cursor = 0
    private var vaultCursor = 0

    init(script: LaserReplayScript) throws {
        self.script = script
        provider = try ReplayBodyInput(fixture: script.input)
    }

    /// Compose outside the authoritative coordinator; App can inject its retained live provider instead.
    static func makeSession(script: LaserReplayScript) throws -> GameSessionCoordinator {
        let driver = try LaserReplayDriver(script: script)
        return GameSessionCoordinator(provider: driver.provider,
            inputConfiguration: script.input.configuration, configuration: script.configuration,
            encounters: script.encounters, replayDriver: driver)
    }

    func nextDeliveryTime(through time: Double) -> Double? {
        guard cursor < script.input.records.count,
              script.input.records[cursor].deliveredAt <= time else { return nil }
        return script.input.records[cursor].deliveredAt
    }

    func deliverNext() throws {
        try provider.advance(to: script.input.records[cursor].deliveredAt)
        cursor += 1
    }

    func applyActions(through time: Double, clock: inout GameClock, game: inout LaserGame) throws {
        while vaultCursor < script.vaultActions.count,
              script.vaultActions[vaultCursor].time <= time, game.roundOutcome == nil {
            let action = script.vaultActions[vaultCursor]
            try clock.advance(to: action.time)
            if let player = action.player, let button = action.button {
                try game.touchVault(id: script.vaultID, playerID: player, button: button, validity: .valid,
                    generation: script.input.configuration.sessionGeneration,
                    calibrationRevision: script.input.configuration.calibrations[player]!.revision,
                    at: clock.gameTime)
            } else { try game.openVault(id: script.vaultID, at: clock.gameTime) }
            vaultCursor += 1
        }
    }

    func recordCoverage(through time: Double, game: inout LaserGame) throws {
        guard time >= script.trackedCoverage.lowerBound else { return }
        for player in PlayerID.allCases {
            try game.recordTrackedInterval(playerID: player, from: script.trackedCoverage.lowerBound,
                to: min(time, script.trackedCoverage.upperBound), observedAt: time)
        }
    }
}
