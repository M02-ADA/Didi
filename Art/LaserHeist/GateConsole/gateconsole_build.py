"""
Builds the LaserHeist gate console stand master (Blender 5.2): the front-facing head the approved
gate button (`Art/LaserHeist/GateButton/`) mounts in, its post and its floor foot.

    blender --background --python gateconsole_build.py -- --out PR_GateConsole.blend [--render previews]

Units metres. Blender is Z up with the console's face toward -Y (the export turns that toward +Z, the
RealityKit game camera). Parts (children of the empty `GateConsole`, separate so the game places them):
- Head: the housing. Its origin is the button's mount (the centre of the button plate's front face):
  a bevelled block whose front frame surrounds a recessed dark panel the button plate sits on, with
  a chamfered top-back edge and a deep lower back the post rises into. Symmetric about X, so the same
  head serves P1 and P2 (the game mirrors the placement, never the mesh).
- Post: the square post, origin at its foot (bottom centre), `POST_HEIGHT` tall. The game stands it
  at the stand's existing floor position, yawed with the head, and stretches it to the head.
- PostStrip: the emissive strip on the post's front face (recoloured by the game: violet, green when
  the side is done). Same origin and height as Post.
- Foot: the floor plate, origin at its bottom centre.
"""
import bpy, bmesh, math, sys, os, argparse

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--render", default=None, help="folder for review renders")
p.add_argument("--button", default="../GateButton/PR_GateButton.blend", help="button master, linked into the review renders only")
args = p.parse_args(a)

# --- Dimensions (metres; mirrored in LaserGateConsole) ------------------------------------------------
HEAD_HALF_W = 0.29        # half the head's width (X)
HEAD_HALF_H = 0.27        # half its height (Z), centred on the button's axis
HEAD_FRONT = 0.05         # the frame's front face: the button plate's back (+Y is into the console)
HEAD_TOP_DEPTH = 0.24     # the flat top, from the front, before the chamfer
HEAD_DEPTH = 0.50         # the lower back (the post rises into it)
HEAD_CHAMFER_Z = 0.02     # where the top chamfer meets the back face (Z)
HEAD_CORNER = 0.12        # the front outline's cut corners (octagonal, like the button's plate)
FRAME = 0.05              # the front frame round the recessed panel
PANEL_DEPTH = 0.014       # how far the panel is recessed
POST = 0.18               # square post
POST_HEIGHT = 0.80        # nominal; the game stretches it from the foot to the head
FOOT = (0.30, 0.34, 0.03) # floor plate (X, Y, Z)
STRIP = (0.012, 0.55)     # the post strip (width, share of the post height)

def srgb(h):
    c = [((h >> s) & 255) / 255 for s in (16, 8, 0)]
    return [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c] + [1]

def material(name, color, rough, metal, emit=None, strength=0.0, coat=0.0):
    m = bpy.data.materials.new(name)
    if bpy.app.version < (5, 0, 0):
        m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = srgb(color)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit is not None:
        b.inputs["Emission Color"].default_value = srgb(emit)
        b.inputs["Emission Strength"].default_value = strength
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = 0.15
    return m

bpy.ops.wm.read_factory_settings(use_empty=True)
M_SHELL = material("ConsoleShell", 0x3A2E8A, 0.38, 0.3, coat=0.35)
M_PANEL = material("ConsolePanel", 0x1B1645, 0.5, 0.2)
M_POST = material("ConsolePost", 0x30276F, 0.42, 0.3)
M_FOOT = material("ConsoleFoot", 0x221C52, 0.35, 0.5)
M_STRIP = material("ConsoleStrip", 0x8C7BFF, 0.4, 0.0, emit=0x8C7BFF, strength=2.0)

def new_object(name, bm, mats, parent):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    for m in mats:
        me.materials.append(m)
    ob.parent = parent
    return ob

def apply(ob):
    bpy.context.view_layer.objects.active = ob
    for mod in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)

def bevel(ob, width, segments=3, angle=35):
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width, mod.segments, mod.limit_method = width, segments, "ANGLE"
    mod.angle_limit = math.radians(angle)
    mod.harden_normals = False
    apply(ob)

def smooth(ob, angle=35):
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))
    except Exception:
        bpy.ops.object.shade_smooth()
    ob.select_set(False)

def box(bm, x0, x1, y0, y1, z0, z1):
    v = [bm.verts.new(c) for c in [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
                                   (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]]
    for f in [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]:
        bm.faces.new([v[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

root = bpy.data.objects.new("GateConsole", None)
bpy.context.collection.objects.link(root)

# --- Head: an octagonal front outline (X, Z) extruded back, its top-back edge cut by a chamfer ----------
c = HEAD_CORNER
outline = [(HEAD_HALF_W, -HEAD_HALF_H + c), (HEAD_HALF_W, HEAD_HALF_H - c), (HEAD_HALF_W - c, HEAD_HALF_H),
           (-HEAD_HALF_W + c, HEAD_HALF_H), (-HEAD_HALF_W, HEAD_HALF_H - c), (-HEAD_HALF_W, -HEAD_HALF_H + c),
           (-HEAD_HALF_W + c, -HEAD_HALF_H), (HEAD_HALF_W - c, -HEAD_HALF_H)]
bm = bmesh.new()
fr = [bm.verts.new((x, HEAD_FRONT, z)) for x, z in outline]
bk = [bm.verts.new((x, HEAD_DEPTH, z)) for x, z in outline]
bm.faces.new(fr[::-1])
bm.faces.new(bk)
for i in range(len(outline)):
    j = (i + 1) % len(outline)
    bm.faces.new((fr[i], fr[j], bk[j], bk[i]))
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
# The chamfer: a plane through (y, z) = (HEAD_TOP_DEPTH, HEAD_HALF_H) and (HEAD_DEPTH, HEAD_CHAMFER_Z).
dy, dz = HEAD_DEPTH - HEAD_TOP_DEPTH, HEAD_CHAMFER_Z - HEAD_HALF_H
normal = (0, -dz, dy)
cut = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-6,
                             plane_co=(0, HEAD_TOP_DEPTH, HEAD_HALF_H), plane_no=normal, clear_outer=True)
edges = [e for e in cut["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
bmesh.ops.contextual_create(bm, geom=edges)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
head = new_object("Head", bm, [M_SHELL, M_PANEL], root)
bevel(head, 0.026, 4, angle=30)
bm = bmesh.new()
bm.from_mesh(head.data)
bm.faces.ensure_lookup_table()
front = max((f for f in bm.faces if f.normal.y < -0.99), key=lambda f: f.calc_area())
bmesh.ops.inset_region(bm, faces=[front], thickness=FRAME - 0.026, depth=0.0)
inner = bmesh.ops.inset_region(bm, faces=[front], thickness=0.008, depth=-PANEL_DEPTH)
front.material_index = 1
bm.to_mesh(head.data)
bm.free()
smooth(head, 40)

# --- Post, its strip, and the foot (origins at their feet) -----------------------------------------------
bm = bmesh.new()
box(bm, -POST / 2, POST / 2, -POST / 2, POST / 2, 0, POST_HEIGHT)
post = new_object("Post", bm, [M_POST], root)
bevel(post, 0.014, 3)
smooth(post, 40)
bm = bmesh.new()
z0 = POST_HEIGHT * 0.18
box(bm, -STRIP[0] / 2, STRIP[0] / 2, -POST / 2 - 0.004, -POST / 2 + 0.004, z0, z0 + POST_HEIGHT * STRIP[1])
strip = new_object("PostStrip", bm, [M_STRIP], root)
bevel(strip, 0.004, 2, angle=60)
smooth(strip, 60)
bm = bmesh.new()
box(bm, -FOOT[0] / 2, FOOT[0] / 2, -FOOT[1] / 2, FOOT[1] / 2, 0, FOOT[2])
foot = new_object("Foot", bm, [M_FOOT], root)
bevel(foot, 0.008, 3)
smooth(foot, 40)

parts = [head, post, strip, foot]
tris = sum(sum(len(f.vertices) - 2 for f in ob.data.polygons) for ob in parts)
print("[build] parts", [ob.name for ob in parts], "triangles", tris)
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.out))
print("[build] saved", os.path.abspath(args.out))

# --- Review renders: the head with the approved button linked in, the post at P1's placement ------------
if args.render:
    from mathutils import Vector
    button = os.path.abspath(args.button)
    if os.path.exists(button):
        with bpy.data.libraries.load(button, link=False) as (src, dst):
            dst.objects = [name for name in src.objects]
        for ob in dst.objects:
            if ob is not None:
                bpy.context.collection.objects.link(ob)
    # P1's post in the head's frame (LaserGateConsoleTests prints it): 0.205 m to the outer side (flush
    # with the head's side), 0.155 m behind the mount; the floor 1.037 m below the button's axis.
    floor, top = -1.037, -HEAD_HALF_H + 0.1
    for ob in (post, strip, foot):
        ob.location = (-0.205, 0.155, floor)
    post.location.z = strip.location.z = floor + FOOT[2]
    post.scale.z = strip.scale.z = (top - floor - FOOT[2]) / POST_HEIGHT
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            pass
    scene.render.resolution_x, scene.render.resolution_y = 1100, 1300
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("World")
    scene.world = world
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = srgb(0x2A2350)
    bg.inputs["Strength"].default_value = 0.6
    for name, loc, energy in [("Key", (-0.9, -1.4, 1.0), 380), ("Fill", (1.2, -1.0, 0.0), 140), ("Rim", (0.4, 1.2, 1.0), 200)]:
        light = bpy.data.lights.new(name, "AREA")
        light.energy, light.size = energy, 1.0
        lo = bpy.data.objects.new(name, light)
        scene.collection.objects.link(lo)
        lo.location = loc
        lo.rotation_euler = (-lo.location.normalized()).to_track_quat("-Z", "Y").to_euler()
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.lens = 40
    target = Vector((0, 0.1, -0.35))
    for label, loc in [("front", (0, -2.6, 0.0)), ("three_quarter", (1.5, -2.0, 0.5)), ("side", (2.6, 0.15, 0.0))]:
        cam.location = loc
        cam.rotation_euler = (target - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(os.path.abspath(args.render), f"blender_{label}.png")
        bpy.ops.render.render(write_still=True)
        print("[build] rendered", scene.render.filepath)
