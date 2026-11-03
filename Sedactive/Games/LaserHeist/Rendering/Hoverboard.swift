//
//  Hoverboard.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The hoverboard (Platform/Asset 11) that carries both players down the
/// corridor, from the `Hoverboard` group in the `LaserCorridor` scene.
///
/// It is decoration only: it never moves or scales the players, so their
/// crown, wrist and sole positions stay exactly where game data puts them
/// (TEAM_ALIGNMENT §C). Its bob runs on RealityKit time because it is cosmetic.
///
/// The artwork is drawn in perspective, so it faces the camera rather than
/// lying on the floor, which would apply perspective twice. The upper half,
/// behind the players' feet, is pushed back along the camera rays: it looks
/// identical, but a low laser close to the crossing now draws in front of it
/// instead of disappearing behind it. Each half carries a darker copy of its
/// silhouette just below it, which reads as the board's thickness, and the
/// corridor floor lies well below with a soft shadow, so the board hovers.
///
/// The hover has three layers on one sine cycle: the board bobs (primary);
/// the riders follow at a fraction of its height a moment later, while their
/// contact shadows tighten as the deck rises to meet them (secondary); and the
/// lavender underglow and floor shadow breathe with the gap (ambient).
@MainActor
final class Hoverboard {
    /// Temporary tuning values, not approved constants.
    static let bobHeight: Float = 0.015
    static let bobDuration: TimeInterval = 1.4
    /// Riders move this share of the board's bob, this much later, so they
    /// read as carried by it without visibly shifting the players.
    static let riderShare: Float = 0.3
    static let riderLag: TimeInterval = 0.12

    let root: Entity
    /// Each half of the image, and how far its depth scales its world motion
    /// so both halves move the same distance on screen.
    private let layers: [(part: Entity, rest: Transform, rayScale: Float)]
    private let shadow: (part: Entity, rest: Transform)?
    private let footShadows: [Entity]
    private let underglow: Entity?
    /// Presentation-only offsets of the players (`PlayerCutoutEntity.ride`).
    private var riders: [Entity] = []
    /// Resting transforms of the secondary parts, restored when hovering stops.
    private var rests: [Entity.ID: Transform] = [:]
    private(set) var isHovering = false

    /// Returns `nil` when the scene lacks the board's named halves.
    /// - Parameters:
    ///   - camera: World position of the scene camera.
    ///   - backDepth: World z for the upper half; it must lie behind the
    ///     depth where a low beam first overlaps the board on screen.
    init?(entity: Entity, camera: SIMD3<Float>, backDepth: Float) {
        guard let front = entity.findEntity(named: "Front"), let back = entity.findEntity(named: "Back") else { return nil }
        root = entity
        let backScale = Self.push(back, toWorldZ: backDepth, camera: camera)
        layers = [(front, front.transform, 1), (back, back.transform, backScale)]
        shadow = entity.findEntity(named: "Shadow").map { ($0, $0.transform) }
        footShadows = ["FootShadowParent", "FootShadowChild"].compactMap { front.findEntity(named: $0) }
        underglow = front.findEntity(named: "Underglow")
        // The front half's layers are a few millimetres apart, and transparent
        // meshes sort by origin, so fix their order: edge, art, glow, then the
        // foot shadows on top. Otherwise a foot shadow can draw first and cut a hole.
        let group = ModelSortGroup()
        for (order, name) in ["Edge", "Art", "Underglow", "FootShadowParent", "FootShadowChild"].enumerated() {
            front.findEntity(named: name)?.components.set(ModelSortGroupComponent(group: group, order: Int32(order)))
        }
    }

    /// Starts the idle hover. Skipped with Reduce Motion.
    func startHovering() {
        stopHovering()
        isHovering = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for layer in layers {
            var raised = layer.rest
            raised.translation.y += Self.bobHeight * layer.rayScale
            loop(layer.part, from: layer.rest, to: raised)
        }
        if let shadow {
            // The floor shadow tightens and fades a little as the board rises.
            var tightened = shadow.rest
            tightened.scale *= SIMD3(0.92, 1, 0.92)
            loop(shadow.part, from: shadow.rest, to: tightened)
            loop(shadow.part, opacity: 1, to: 0.75)
        }
        for mark in footShadows {
            // The deck rises to meet the feet: the contact shadow tightens and darkens.
            let rest = rest(of: mark)
            var tightened = rest
            tightened.scale.y *= 0.85
            loop(mark, from: rest, to: tightened)
            loop(mark, opacity: 0.8, to: 1)
        }
        if let underglow {
            // Brightest when the board is lowest, nearest the floor.
            loop(underglow, opacity: 1, to: 0.65)
        }
        for rider in riders {
            let rest = rest(of: rider)
            var raised = rest
            raised.translation.y += Self.bobHeight * Self.riderShare
            loop(rider, from: rest, to: raised, after: Self.riderLag)
        }
    }

    /// Centres the deck's contact shadows (`FootShadowParent`, `FootShadowChild`)
    /// under each player's feet, so the players read as standing on the board.
    /// They ride with the deck; the players never move with it.
    func setFootShadow(_ lane: GameWorldMapping.Lane, atWorldX x: Float) {
        let name = lane == .parent ? "FootShadowParent" : "FootShadowChild"
        guard let mark = root.findEntity(named: name) else { return }
        restarting {
            // The mesh is authored at its lane with the origin on the board's centre
            // line (for draw order), so shift it by how far its centre is from `x`.
            var position = mark.position(relativeTo: nil)
            position.x += x - mark.visualBounds(relativeTo: nil).center.x
            mark.setPosition(position, relativeTo: nil)
            rests[mark.id] = mark.transform
        }
    }

    /// The players' presentation-only offsets (`PlayerCutoutEntity.ride`), which
    /// follow the bob faintly. Their placements never move.
    func setRiders(_ riders: [Entity]) {
        restarting {
            self.riders = riders
        }
    }

    func stopHovering() {
        isHovering = false
        for layer in layers {
            layer.part.stopAllAnimations()
            layer.part.transform = layer.rest
        }
        if let shadow {
            shadow.part.stopAllAnimations()
            shadow.part.transform = shadow.rest
            shadow.part.components.remove(OpacityComponent.self)
        }
        for part in footShadows + riders + [underglow].compactMap({ $0 }) {
            part.stopAllAnimations()
            if let rest = rests[part.id] {
                part.transform = rest
            }
            part.components.remove(OpacityComponent.self)
        }
    }

    private func restarting(_ change: () -> Void) {
        let wasHovering = isHovering
        stopHovering()
        change()
        if wasHovering {
            startHovering()
        }
    }

    private func rest(of part: Entity) -> Transform {
        if let rest = rests[part.id] {
            return rest
        }
        rests[part.id] = part.transform
        return part.transform
    }

    /// One sine-eased swing per `bobDuration`, back and forth forever. A delay
    /// is its own held step: an animation `delay` would show `to` meanwhile.
    private func loop(_ part: Entity, from: Transform, to: Transform, after delay: TimeInterval = 0) {
        let swing = FromToByAnimation(from: from, to: to, duration: Self.bobDuration, timing: .easeInOut,
                                      bindTarget: .transform, repeatMode: .autoReverse)
        guard let looping = try? AnimationResource.generate(with: swing).repeat() else { return }
        guard delay > 0 else {
            part.playAnimation(looping)
            return
        }
        let hold = FromToByAnimation(from: from, to: from, duration: delay, bindTarget: .transform)
        if let held = try? AnimationResource.generate(with: hold),
           let sequence = try? AnimationResource.sequence(with: [held, looping]) {
            part.playAnimation(sequence)
        }
    }

    private func loop(_ part: Entity, opacity from: Float, to: Float) {
        part.components.set(OpacityComponent(opacity: from))
        let swing = FromToByAnimation<Float>(from: from, to: to, duration: Self.bobDuration, timing: .easeInOut,
                                             bindTarget: .opacity, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: swing).repeat() {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    /// Moves a camera-facing part to `z` along the rays through the camera and
    /// scales it to match, so it projects to the same pixels. Returns the scale.
    private static func push(_ part: Entity, toWorldZ z: Float, camera: SIMD3<Float>) -> Float {
        let position = part.position(relativeTo: nil)
        let scale = (camera.z - z) / (camera.z - position.z)
        part.setPosition(camera + scale * (position - camera), relativeTo: nil)
        part.scale *= scale
        return scale
    }
}
