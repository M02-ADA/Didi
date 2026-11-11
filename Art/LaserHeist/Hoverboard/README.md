# LaserHeist hoverboard (VH_Hoverboard)

One reusable 3D hoverboard for both players, built in Blender from
`ref/hoverboard-concept.png`. In the game, each mascot stands on its own
instance (`Sedactive/Games/LaserHeist/Rendering/PlayerHoverboard.swift`).
The instances differ only in their end-stripe accent: Lemon yellow for P1
and Tangerine orange for P2.

| File | What it is |
| --- | --- |
| `VH_Hoverboard.blend` | Editable master (Blender 5.2). Parts stay separate; collection `LOW`. |
| `hoverboard_build.py` | Rebuilds the master from scratch. Every dimension and colour is a named constant. |
| `hoverboard_export.py` | Writes the game's USDZ. Joins everything except `Accent` into one `Body` mesh (on a copy; the master is not saved). |
| `previews/` | Blender renders (front, end, top, three-quarter), the reference compared with the matched Blender camera, and RealityKit Simulator captures. |
| `ref/` | The concept image the model was measured from. |

The runtime asset is
`RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/PlayerHoverboard.usdz`,
compiled by the Reality Composer Pro package with the rest of the content.

## Rebuild

```bash
cd Art/LaserHeist/Hoverboard
/Applications/Blender.app/Contents/MacOS/Blender --background --python hoverboard_build.py -- --out VH_Hoverboard.blend
/Applications/Blender.app/Contents/MacOS/Blender --background VH_Hoverboard.blend --python hoverboard_export.py -- \
  --out ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/PlayerHoverboard.usdz
usdchecker --arkit ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/PlayerHoverboard.usdz
```

## Conventions

- **Units and axes:** metres. Blender is Z up, with the display side (the emblem module) facing −Y. The USD is Y up, with the display side facing +Z, toward the game camera.
- **Origin:** the deck top at the board's centre, where the mascots' soles stand. The rim rises 17 mm above it, and the body hangs 0.118 m below (0.14 m with the thrusters).
- **Size:** 1.16 × 0.46 m. The lanes are 1.4 m apart, so the boards leave a 0.24 m gap between them. The mascots' stance (1.6 m tall, soles about ±0.29 m) fits on the deck.
- **Materials:** UsdPreviewSurface only, with flat colours, roughness and emission. There are no textures or UVs: panel lines, chevrons, stripes and the emblem are real geometry. No Blender-only nodes are used.
- **Budget:** 13,864 triangles. The USDZ has two meshes (`Body` with 17 material subsets, `Accent` with 1) and is about 0.6 MB.

## Measured from the concept

The concept is a single perspective view at about 19° elevation, close to the game camera's 18.7°.

- The top ellipse's height-to-width ratio is 0.126. That gives a depth-to-width ratio of 0.39.
- The side band is about 0.1 m tall.
- The light bars span x ±0.23 to ±0.44.
- The emblem module spans x ±0.2.
- The orange stripes sit at x ±0.50 to ±0.56.

## Inferred

These parts are not visible in the concept:

- **Far side:** mirrored from the display side, including its emblem module.
- **Underside:** two thruster pods with warm emissive cores.
- **Deck panel layout under the feet:** designed in the concept's style.
- **Bulged band profile:** inferred from the concept's shading.

## Known deviations from the concept

- **Rim plates:** the lighter plates set into the rim read smaller and lower in contrast than in the concept.
- **Light bars:** the concept's soft bloom becomes a cream emissive bar. RealityKit has no bloom here.
- **Colours:** tuned for the game's lighting (the mascots' key, fill and dim environment light), not for the Blender studio render.
