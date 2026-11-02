//
//  Player.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// Family identity, never a Vision candidate index or a session lane.
nonisolated struct PlayerID: Hashable, Sendable, Codable, CodingKeyRepresentable {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    var codingKey: any CodingKey { Key(stringValue: rawValue.uuidString) }
    init?<T: CodingKey>(codingKey: T) {
        guard let id = UUID(uuidString: codingKey.stringValue) else { return nil }
        rawValue = id
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

nonisolated struct Player: Equatable, Sendable, Codable {
    let id: PlayerID
    let name: String
    let weightKg: Double

    func validate() throws {
        try requireBodyValue(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "name")
        try requireBodyValue(weightKg.isFinite && weightKg > 0, "weightKg")
    }
}

nonisolated struct SelectedPlayers: Equatable, Sendable, Codable {
    let firstID: PlayerID
    let secondID: PlayerID
    var ids: [PlayerID] { [firstID, secondID] }
    func validate() throws {
        try requireBodyValue(firstID != secondID, "selectedPlayers must be distinct")
    }
}
