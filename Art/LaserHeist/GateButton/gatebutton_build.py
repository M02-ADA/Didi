"""
Builds the LaserHeist gate activation button master (Blender 5.2), from ref/gate-button-concept.webp:

    blender --background --python gatebutton_build.py -- --out PR_GateButton.blend [--render previews]

Units metres. Blender is Z up with the button's face toward -Y (the export turns that toward +Z,
the RealityKit game camera). The origin is the centre of the mounting plate's front face; the press
axis is +Y (into the console).

Parts (children of the empty `GateButton`, kept separate so the game can drive them):
- Housing: chamfered octagonal mounting plate with four slotted screws, and the body behind it that
  sinks into the stand.
- Collar: the raised bevelled ring round the socket, with four light-bar tabs.
- Socket: the dark bore and floor the cap travels in.
- Cap: the red button (deep red sidewall, bright red rounded edge and convex face). Its origin is
  its back centre, so moving it along +Y presses it.
- Accents: the four light bars and the glow ring inside the socket (one emissive material the game
  recolours).
"""
import bpy, bmesh, math, sys, os, argparse

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
p = argparse.ArgumentParser()
p.add_argument("--out", required=True)
p.add_argument("--render", default=None, help="folder for review renders")
args = p.parse_args(a)

# --- Dimensions (metres) ---------------------------------------------------------------------
PLATE_HALF = 0.22          # octagon: half its width across the flats
PLATE_CORNER = 0.08        # how far each corner is cut back
PLATE_DEPTH = 0.05         # plate thickness (front face at y = 0)
BODY_HALF = 0.17           # the body behind the plate (sinks into the stand)
BODY_DEPTH = 0.2
SCREW_R, SCREW_AT = 0.012, 0.172
CAP_R = 0.15               # cap radius (0.30 m across)
CAP_WALL = 0.042           # straight sidewall
CAP_EDGE = 0.017           # rounded front edge
CAP_RISE = 0.02            # convex face's rise
CAP_BACK = 0.0             # the cap's back at rest (y); its face is then 4.5 cm proud of the collar
SOCKET_R = CAP_R + 0.012
SOCKET_FLOOR = 0.035
COLLAR_OUT = 0.2
COLLAR_TOP = -0.034        # the collar's front (y)
TAB_W, TAB_H, TAB_D = 0.115, 0.05, 0.042
BAR_W, BAR_H = 0.08, 0.017

# --- Colours (linear-ish sRGB values) ----------------------------------------------------------
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
        b.inputs["Coat Roughness"].default_value = 0.08
    return m

bpy.ops.wm.read_factory_settings(use_empty=True)
M_HOUSING = material("Housing", 0x241E58, 0.42, 0.35)
M_SCREW = material("Screw", 0x6E68B0, 0.25, 0.85)
M_COLLAR = material("CollarMetal", 0x3B3480, 0.26, 0.75)
M_SOCKET = material("Socket", 0x0D0A20, 0.7, 0.1)
M_CAP = material("CapRed", 0xE3122C, 0.22, 0.05, emit=0xC0001A, strength=0.35, coat=0.6)
M_CAP_SIDE = material("CapSide", 0x9A0A1E, 0.38, 0.05, emit=0x60000E, strength=0.3)
M_ACCENT = material("AccentGlow", 0xFF2A22, 0.4, 0.0, emit=0xFF2A22, strength=2.5)

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

def bevel(ob, width, segments=3, angle=35):
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width, mod.segments, mod.limit_method = width, segments, "ANGLE"
    mod.angle_limit = math.radians(angle)
    apply(ob)

def apply(ob):
    bpy.context.view_layer.objects.active = ob
    for mod in list(ob.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)

def smooth(ob, angle=35):
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle))
    except Exception:
        bpy.ops.object.shade_smooth()
    ob.select_set(False)

def prism(bm, outline, y0, y1):
    """Extrudes an XZ outline (counter-clockwise seen from -Y) from y0 to y1."""
    front = [bm.verts.new((x, y0, z)) for x, z in outline]
    back = [bm.verts.new((x, y1, z)) for x, z in outline]
    bm.faces.new(front[::-1] if y0 > y1 else front)
    bm.faces.new(back if y0 > y1 else back[::-1])
    n = len(outline)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

def octagon(half, corner):
    pts = [(half, -half + corner), (half, half - corner), (half - corner, half), (-half + corner, half),
           (-half, half - corner), (-half, -half + corner), (-half + corner, -half), (half - corner, -half)]
    return pts

def lathe(name, profile, mats, parent, steps=128, side_material=None):
    """Spins a profile [(radius, y)] round the Y axis (smooth); faces whose normal lies across the
    axis take `side_material` when given."""
    bm = bmesh.new()
    rings = []
    for k in range(steps):
        t = 2 * math.pi * k / steps
        rings.append([bm.verts.new((r * math.cos(t), y, r * math.sin(t))) for r, y in profile])
    for k in range(steps):
        a, b = rings[k], rings[(k + 1) % steps]
        for i in range(len(profile) - 1):
            if profile[i][0] < 1e-5 and profile[i + 1][0] < 1e-5:
                continue
            bm.faces.new((a[i], a[i + 1], b[i + 1], b[i]))
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if side_material is not None:
        for f in bm.faces:
            f.material_index = side_material if abs(f.normal.y) < 0.55 else 0
    ob = new_object(name, bm, mats, parent)
    return ob

def arc(cx, cy, r, a0, a1, n=8):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]

root = bpy.data.objects.new("GateButton", None)
bpy.context.collection.objects.link(root)

# --- Housing: octagonal plate, body, screws ---------------------------------------------------------
bm = bmesh.new()
prism(bm, octagon(PLATE_HALF, PLATE_CORNER), 0.0, PLATE_DEPTH)
plate = new_object("Plate", bm, [M_HOUSING], root)
bevel(plate, 0.009, 3)
bm = bmesh.new()
prism(bm, octagon(BODY_HALF, 0.05), PLATE_DEPTH - 0.01, PLATE_DEPTH + BODY_DEPTH)
body = new_object("Body", bm, [M_HOUSING], root)
bevel(body, 0.008, 2)
screws = []
for sx, sz in [(1, 1), (-1, 1), (-1, -1), (1, -1)]:
    s = lathe("Screw", [(0.0, -0.007), (SCREW_R - 0.003, -0.007), (SCREW_R, -0.004), (SCREW_R, 0.002)], [M_SCREW], root, steps=32)
    s.location = (sx * SCREW_AT, 0, sz * SCREW_AT)
    bm = bmesh.new()
    prism(bm, [(-0.009, -0.0016), (0.009, -0.0016), (0.009, 0.0016), (-0.009, 0.0016)], -0.0085, -0.006)
    slot = new_object("Slot", bm, [M_SOCKET], root)
    slot.location = s.location
    slot.rotation_euler = (0, math.radians(45 if sx * sz > 0 else -45), 0)
    screws += [s, slot]
for ob in [plate, body, *screws]:
    ob.select_set(True)
bpy.context.view_layer.objects.active = plate
bpy.ops.object.transform_apply(location=True, rotation=True, scale=False)
bpy.ops.object.join()
housing = bpy.context.view_layer.objects.active
housing.name = housing.data.name = "Housing"
bpy.ops.object.select_all(action="DESELECT")
smooth(housing, 35)

# --- Collar: bevelled ring with four light-bar tabs ---------------------------------------------------
edge = 0.008
collar = lathe("Collar", [(COLLAR_OUT, 0.002), (COLLAR_OUT, COLLAR_TOP + edge)]
               + arc(COLLAR_OUT - edge, COLLAR_TOP + edge, edge, 0, -math.pi / 2, 5)[1:]
               + [(SOCKET_R + 0.01, COLLAR_TOP), (SOCKET_R + 0.002, COLLAR_TOP + 0.006), (SOCKET_R, COLLAR_TOP + 0.012)],
               [M_COLLAR], root)
tabs = []
for angle in (0, 90, 180, 270):
    bm = bmesh.new()
    w, h = TAB_W / 2, TAB_H / 2
    prism(bm, [(-w, -h), (w, -h), (w, h), (-w, h)], -TAB_D, 0.004)
    tab = new_object("Tab", bm, [M_COLLAR], root)
    bevel(tab, 0.008, 3)
    t = math.radians(angle)
    rad = COLLAR_OUT - 0.004
    tab.location = (rad * math.cos(t), 0, rad * math.sin(t))
    tab.rotation_euler = (0, -t + math.pi / 2, 0)
    tabs.append(tab)
for ob in [collar, *tabs]:
    ob.select_set(True)
bpy.context.view_layer.objects.active = collar
bpy.ops.object.transform_apply(location=True, rotation=True, scale=False)
bpy.ops.object.join()
collar = bpy.context.view_layer.objects.active
collar.name = collar.data.name = "Collar"
bpy.ops.object.select_all(action="DESELECT")
smooth(collar, 40)

# --- Socket: bore and floor ---------------------------------------------------------------------------
socket = lathe("Socket", [(SOCKET_R, COLLAR_TOP + 0.012), (SOCKET_R, SOCKET_FLOOR), (0.0, SOCKET_FLOOR)], [M_SOCKET], root, steps=96)
smooth(socket, 30)

# --- Cap: deep red sidewall, rounded edge, convex face (origin at its back centre) --------------------
inner = CAP_R - CAP_EDGE
face = [(inner * (1 - i / 14), -(CAP_WALL + CAP_EDGE) - CAP_RISE * (1 - (1 - i / 14) ** 2)) for i in range(1, 15)]
cap = lathe("Cap", [(0.0, 0.0), (CAP_R, 0.0), (CAP_R, -CAP_WALL)]
            + arc(CAP_R - CAP_EDGE, -CAP_WALL, CAP_EDGE, 0, -math.pi / 2, 8)[1:] + face,
            [M_CAP, M_CAP_SIDE], root, steps=128, side_material=1)
smooth(cap, 50)
cap.location = (0, CAP_BACK, 0)

# --- Accents: four light bars on the tabs and a glow ring inside the socket ----------------------------
parts = []
for angle in (0, 90, 180, 270):
    bm = bmesh.new()
    w, h = BAR_W / 2, BAR_H / 2
    prism(bm, [(-w, -h), (w, -h), (w, h), (-w, h)], -TAB_D - 0.004, -TAB_D + 0.002)
    bar = new_object("Bar", bm, [M_ACCENT], root)
    bevel(bar, 0.006, 3, angle=60)
    t = math.radians(angle)
    rad = COLLAR_OUT - 0.004
    bar.location = (rad * math.cos(t), 0, rad * math.sin(t))
    bar.rotation_euler = (0, -t + math.pi / 2, 0)
    parts.append(bar)
ring = lathe("GlowRing", [(SOCKET_R - 0.0008, COLLAR_TOP + 0.014), (SOCKET_R - 0.0008, COLLAR_TOP + 0.03)], [M_ACCENT], root, steps=96)
parts.append(ring)
for ob in parts:
    ob.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=False)
bpy.ops.object.join()
accents = bpy.context.view_layer.objects.active
accents.name = accents.data.name = "Accents"
bpy.ops.object.select_all(action="DESELECT")

for ob in [housing, collar, socket, cap, accents]:
    ob.parent = root
tris = sum(sum(len(f.vertices) - 2 for f in ob.data.polygons) for ob in [housing, collar, socket, cap, accents])
print("[build] parts", [ob.name for ob in root.children], "triangles", tris)
bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.out))
print("[build] saved", os.path.abspath(args.out))

# --- Review renders ---------------------------------------------------------------------------------
if args.render:
    os.makedirs(args.render, exist_ok=True)
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            pass
    scene.render.resolution_x, scene.render.resolution_y = 1200, 1200
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("World")
    scene.world = world
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs["Color"].default_value = srgb(0x2A2350)
    bg.inputs["Strength"].default_value = 0.6
    for name, loc, energy in [("Key", (-0.6, -1.0, 0.9), 220), ("Fill", (0.8, -0.8, 0.2), 90), ("Rim", (0.3, 0.8, 0.8), 120)]:
        light = bpy.data.lights.new(name, "AREA")
        light.energy, light.size = energy, 0.8
        lo = bpy.data.objects.new(name, light)
        scene.collection.objects.link(lo)
        lo.location = loc
        direction = -lo.location.normalized()
        lo.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.lens = 60
    from mathutils import Vector
    for label, loc in [("front", (0, -1.35, 0.0)), ("three_quarter", (0.85, -1.0, 0.35)), ("side", (1.25, -0.45, 0.1))]:
        cam.location = loc
        cam.rotation_euler = (Vector((0, -0.04, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(os.path.abspath(args.render), f"blender_{label}.png")
        bpy.ops.render.render(write_still=True)
        print("[build] rendered", scene.render.filepath)
