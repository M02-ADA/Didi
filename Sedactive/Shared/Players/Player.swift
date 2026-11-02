//
//  Player.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// Logical slots bound during mirrored calibration. Scope identity with sessionGeneration.
/// Raw candidate order or later screen position must never reassign a bound person.
nonisolated enum PlayerID: String, Codable, Hashable, Sendable, CaseIterable, CodingKeyRepresentable {
    case player1
    case player2
}
