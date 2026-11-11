"""
Exports the hoverboard master to the game's USDZ (Blender 5.2):

    blender --background VH_Hoverboard.blend --python hoverboard_export.py -- --out ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/PlayerHoverboard.usdz

Y-up, metres, display side (Blender -Y) toward +Z, which faces the RealityKit
game camera. Origin at the deck top centre. Triangulated meshes with exported
normals and UsdPreviewSurface materials (flat colours and emission only, no
textures), so nothing depends on Blender-only shader nodes.
"""
import bpy, sys, os, argparse

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
args = p.parse_args(a)

root = bpy.data.objects["Board"]
# Delivery copy (the master file is not saved): every part except the
# per-player accent is joined into one `Body` mesh, so RealityKit draws one
# mesh per material instead of one per part per material.
parts = [ob for ob in root.children if ob.type == "MESH"]
body_parts = [ob for ob in parts if ob.name != "Accent"]
bpy.ops.object.select_all(action="DESELECT")
for ob in body_parts:
    ob.select_set(True)
bpy.context.view_layer.objects.active = body_parts[0]
bpy.ops.object.join()
body = bpy.context.view_layer.objects.active
body.name = body.data.name = "Body"
bpy.ops.object.select_all(action="DESELECT")
for ob in [root, *root.children_recursive]:
    ob.select_set(True)
bpy.context.view_layer.objects.active = root
print("[export] meshes", [ob.name for ob in root.children], "materials",
      {ob.name: len(ob.data.materials) for ob in root.children if ob.type == "MESH"})

bpy.ops.wm.usd_export(
    filepath=os.path.abspath(args.out),
    selected_objects_only=True,
    export_animation=False,
    export_uvmaps=False,
    export_normals=True,
    export_materials=True,
    generate_preview_surface=True,
    generate_materialx_network=False,
    convert_orientation=True,
    export_global_forward_selection="NEGATIVE_Z",
    export_global_up_selection="Y",
    export_textures_mode="NEW",
    triangulate_meshes=True,
    root_prim_path="/PlayerHoverboard",
    merge_parent_xform=False,
    convert_scene_units="METERS",
    export_custom_properties=False,
    author_blender_name=False,
    accessibility_label="Hoverboard",
    accessibility_description="The players' hover platform",
)
print("[export] wrote", os.path.abspath(args.out), os.path.getsize(os.path.abspath(args.out)), "bytes")
