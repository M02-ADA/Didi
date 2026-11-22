"""
Exports the gate console stand master to the game's USDZ (Blender 5.2):

    blender --background PR_GateConsole.blend --python gateconsole_export.py -- --out ../../../RealityKitContent/Sources/RealityKitContent/RealityKitContent.rkassets/GateConsole.usdz

Y-up, metres, the console's face (Blender -Y) toward +Z, which faces the RealityKit game camera. The
parts stay separate prims (`Head`, `Post`, `PostStrip`, `Foot`) so the game places the post and foot
at the stand's floor position and recolours the strip. Head's origin is the button's mount; the
others' origins are their feet. Triangulated meshes with exported normals and UsdPreviewSurface
materials (flat colours, roughness, metallic, emission; no textures or Blender-only nodes).
"""
import bpy, sys, os, argparse

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
args = p.parse_args(a)

root = bpy.data.objects["GateConsole"]
bpy.ops.object.select_all(action="DESELECT")
for ob in [root, *root.children_recursive]:
    ob.select_set(True)
bpy.context.view_layer.objects.active = root
print("[export] parts", sorted(ob.name for ob in root.children))
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
    triangulate_meshes=True,
    root_prim_path="/GateConsole",
    merge_parent_xform=False,
    convert_scene_units="METERS",
    export_custom_properties=False,
    author_blender_name=False,
    accessibility_label="Gate console",
    accessibility_description="The gate button's stand",
)
print("[export] wrote", os.path.abspath(args.out), os.path.getsize(os.path.abspath(args.out)), "bytes")
