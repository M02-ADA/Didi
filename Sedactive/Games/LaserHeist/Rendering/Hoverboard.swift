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
@MainActor
final class Hoverboard {
    /// Temporary tuning values, not approved constants.
    static let bobHeight: Float = 0.015
    static let bobDuration: TimeInterval = 1.4

    let root: Entity
    /// Each half of the image, and how far its depth scales its world motion
    /// so both halves move the same distance on screen.
    private let layers: [(part: Entity, rest: Transform, rayScale: Float)]
    private let shadow: (part: Entity, rest: Transform)?

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
        // The front half's layers are a few millimetres apart, and transparent
        // meshes sort by origin, so fix their order: edge, art, then the foot
        // shadows on top. Otherwise a foot shadow can draw first and cut a hole.
        let group = ModelSortGroup()
        for (order, name) in ["Edge", "Art", "FootShadowParent", "FootShadowChild"].enumerated() {
            front.findEntity(named: name)?.components.set(ModelSortGroupComponent(group: group, order: Int32(order)))
        }
    }

    /// Starts the idle hover. Skipped with Reduce Motion.
    func startHovering() {
        stopHovering()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for layer in layers {
            var raised = layer.rest
            raised.translation.y += Self.bobHeight * layer.rayScale
            bob(layer.part, from: layer.rest, to: raised)
        }
        if let shadow {
            // The floor shadow tightens and fades a little as the board rises.
            var tightened = shadow.rest
            tightened.scale *= SIMD3(0.92, 1, 0.92)
            bob(shadow.part, from: shadow.rest, to: tightened)
            shadow.part.components.set(OpacityComponent(opacity: 1))
            let fading = FromToByAnimation<Float>(from: 1, to: 0.75, duration: Self.bobDuration, timing: .easeInOut,
                                                  bindTarget: .opacity, repeatMode: .autoReverse)
            if let resource = try? AnimationResource.generate(with: fading).repeat() {
                shadow.part.playAnimation(resource, handoffType: .compose)
            }
        }
    }

    /// Centres the deck's contact shadows (`FootShadowParent`, `FootShadowChild`)
    /// under each player's feet, so the players read as standing on the board.
    /// They ride with the deck; the players never move with it.
    func setFootShadow(_ lane: GameWorldMapping.Lane, atWorldX x: Float) {
        let name = lane == .parent ? "FootShadowParent" : "FootShadowChild"
        guard let mark = root.findEntity(named: name) else { return }
        // The mesh is authored at its lane with the origin on the board's centre
        // line (for draw order), so shift it by how far its centre is from `x`.
        var position = mark.position(relativeTo: nil)
        position.x += x - mark.visualBounds(relativeTo: nil).center.x
        mark.setPosition(position, relativeTo: nil)
    }

    func stopHovering() {
        for layer in layers {
            layer.part.stopAllAnimations()
            layer.part.transform = layer.rest
        }
        if let shadow {
            shadow.part.stopAllAnimations()
            shadow.part.transform = shadow.rest
            shadow.part.components.remove(OpacityComponent.self)
        }
    }

    private func bob(_ part: Entity, from: Transform, to: Transform) {
        let animation = FromToByAnimation(from: from, to: to, duration: Self.bobDuration, timing: .easeInOut,
                                          bindTarget: .transform, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: animation).repeat() {
            part.playAnimation(resource)
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
