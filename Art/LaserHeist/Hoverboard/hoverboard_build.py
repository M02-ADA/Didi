"""
LaserHeist hoverboard: reproducible Blender build (Blender 5.2, bpy only).

    blender --background --python hoverboard_build.py -- --out VH_Hoverboard.blend

Builds the editable master from scratch, measured from
`ref/hoverboard-concept.png` (one perspective concept at about 19 degrees
elevation, nearly the game camera's 18.7 degrees). Every constant is metres:
1 unit = 1 m, Z up, the board's display side (emblem module) faces -Y. That is
+Z in RealityKit after the Y-up USD export, which faces the game camera.

Origin: the deck top at the board's centre, where the mascots' soles stand.
So the board can bank about the feet without moving them.

Reference measurements (concept, 1235 px wide silhouette):
  top ellipse height / width        0.126   -> depth / width 0.39 at 18.7 deg
  side band visible height          ~100 px -> band about 0.10 m
  light bars x                      -0.437 ... -0.232 of a 1.2 m board
  module x                          +-0.20, protrudes and drops below the band
  orange stripes x                  -0.564 ... -0.497
Inferred (not visible in the concept): the far side (mirrored from the front,
simpler module), the underside and its thrusters, the deck under the feet.
"""
import bpy, bmesh, sys, os, math, argparse
from mathutils import Vector, Matrix

# ---------------------------------------------------------------- dimensions
W, D = 1.16, 0.46          # outer width (X) and depth (Y); 0.2 m gap between P1/P2 lanes 1.4 m apart
A, B = W / 2, D / 2
N_EXP = 2.15               # superellipse exponent: concept ends are a little fuller than an ellipse
SAMPLES = 192              # outline points (even, divisible by 4)
DECK_Z = 0.0               # feet
RIM_Z = 0.017              # rim top, 17 mm above the deck
BOTTOM_Z = -0.118          # underside plate
BAND = (-0.088, -0.032)    # side band z range (bulged), ~0.1 m visible with the lip

# ---------------------------------------------------------------- palette (sRGB hex from the concept)
PALETTE = {
    "HB_Band":       ("4C3C92", 0.66, None),
    "HB_BandUpper":  ("5E4EA8", 0.62, None),
    "HB_BandDark":   ("2E255E", 0.75, None),
    "HB_Rim":        ("9282D4", 0.55, None),
    "HB_RimPlate":   ("C6BEEA", 0.45, None),
    "HB_Groove":     ("2F2970", 0.75, None),
    "HB_Deck":       ("40387F", 0.72, None),
    "HB_DeckLine":   ("2E295E", 0.80, None),
    "HB_Underside":  ("2B2560", 0.75, None),
    "HB_Cream":      ("F4E0C2", 0.50, None),
    "HB_LightBar":   ("FFE4B8", 0.40, ("FFD9A0", 0.45)),
    "HB_Accent":     ("F2832C", 0.50, ("F2832C", 0.35)),
    "HB_ModuleFrame":("8473CE", 0.55, None),
    "HB_Pod":        ("5A4AAE", 0.60, None),
    "HB_Slot":       ("2C2566", 0.80, None),
    "HB_Emblem":     ("2A2360", 0.60, None),
    "HB_Sun":        ("FCD79A", 0.40, ("FCD79A", 0.35)),
    "HB_Thruster":   ("FFD9A0", 0.40, ("FFD9A0", 3.0)),
}


def args():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    return p.parse_args(a)


def srgb_to_linear(h):
    def c(v):
        v = int(v, 16) / 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (c(h[0:2]), c(h[2:4]), c(h[4:6]), 1.0)


def make_materials():
    mats = {}
    for name, (hexc, rough, emit) in PALETTE.items():
        m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        if bpy.app.version < (5, 0, 0):
            m.use_nodes = True
        nt = m.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Base Color"].default_value = srgb_to_linear(hexc)
        bsdf.inputs["Roughness"].default_value = rough
        bsdf.inputs["Metallic"].default_value = 0.0
        if emit:
            bsdf.inputs["Emission Color"].default_value = srgb_to_linear(emit[0])
            bsdf.inputs["Emission Strength"].default_value = emit[1]
        m.diffuse_color = srgb_to_linear(hexc)  # workbench / viewport colour
        mats[name] = m
    return mats


# ---------------------------------------------------------------- outline

def superellipse(a, b, t):
    c, s = math.cos(t), math.sin(t)
    x = a * math.copysign(abs(c) ** (2 / N_EXP), c)
    y = b * math.copysign(abs(s) ** (2 / N_EXP), s)
    return x, y


def arclength_params():
    """Parameters t giving evenly spaced points on the outer outline, starting at +X, counter-clockwise."""
    fine = [2 * math.pi * i / 4096 for i in range(4097)]
    pts = [superellipse(A, B, t) for t in fine]
    acc = [0.0]
    for i in range(1, len(pts)):
        acc.append(acc[-1] + math.dist(pts[i - 1], pts[i]))
    total = acc[-1]
    out, j = [], 0
    for k in range(SAMPLES):
        target = total * k / SAMPLES
        while acc[j + 1] < target:
            j += 1
        f = (target - acc[j]) / (acc[j + 1] - acc[j])
        out.append(fine[j] + f * (fine[j + 1] - fine[j]))
    return out


T = arclength_params()


def ring(ox, oy, z, scale=1.0):
    """One closed ring: the outline shrunk by (ox, oy) (negative = outward), optionally scaled toward the centre."""
    return [Vector((*(v * scale for v in superellipse(A - ox, B - oy, t)), z)) for t in T]


def front_point(x, outset, z):
    """Point on the outer band surface at the given x on the -Y side, pushed `outset` outward."""
    t = -math.acos(max(-1, min(1, math.copysign(abs(x / A) ** (N_EXP / 2), x))))
    px, py = superellipse(A, B, t)
    # outward normal from the implicit superellipse gradient
    gx = N_EXP / A * abs(px / A) ** (N_EXP - 1) * math.copysign(1, px)
    gy = N_EXP / B * abs(py / B) ** (N_EXP - 1) * math.copysign(1, py)
    n = Vector((gx, gy, 0)).normalized()
    return Vector((px, py, z)) + n * outset, n


# ---------------------------------------------------------------- helpers

def new_object(name, bm, mats, collection):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    collection.objects.link(ob)
    return ob


def loft(bm, rings, mat_index_per_strip, closed=True):
    vs = [[bm.verts.new(p) for p in r] for r in rings]
    n = len(rings[0])
    for i in range(len(rings) - 1):
        for k in range(n if closed else n - 1):
            k2 = (k + 1) % n
            f = bm.faces.new((vs[i][k], vs[i][k2], vs[i + 1][k2], vs[i + 1][k]))
            f.material_index = mat_index_per_strip[i]
    return vs


def cap(bm, verts, mat_index, flip=False):
    c = sum((v.co for v in verts), Vector()) / len(verts)
    cv = bm.verts.new(c)
    n = len(verts)
    for k in range(n):
        a, b = verts[k], verts[(k + 1) % n]
        f = bm.faces.new((cv, b, a) if flip else (cv, a, b))
        f.material_index = mat_index


def prism(bm, outline2d, to3d, depth_from, depth_to, mat_index):
    """Extrude a CCW 2D polygon (u, v) between two depths; to3d(u, v, d) -> Vector."""
    front = [bm.verts.new(to3d(u, v, depth_to)) for u, v in outline2d]
    back = [bm.verts.new(to3d(u, v, depth_from)) for u, v in outline2d]
    faces = []
    faces.append(bm.faces.new(front))
    faces.append(bm.faces.new(list(reversed(back))))
    n = len(outline2d)
    for k in range(n):
        k2 = (k + 1) % n
        faces.append(bm.faces.new((back[k], back[k2], front[k2], front[k])))
    for f in faces:
        f.material_index = mat_index
    return front, back


def rounded_rect(w, h, r, seg=4):
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def pill(length, height, seg=6):
    r = height / 2
    pts = []
    for i in range(seg + 1):
        a = math.radians(-90 + 180 * i / seg)
        pts.append((length / 2 - r + r * math.cos(a), r * math.sin(a)))
    for i in range(seg + 1):
        a = math.radians(90 + 180 * i / seg)
        pts.append((-length / 2 + r + r * math.cos(a), r * math.sin(a)))
    return pts


def fix_normals(bm):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)


# ---------------------------------------------------------------- body shell

def build_body(mats, collection):
    names = ["HB_Underside", "HB_BandDark", "HB_Band", "HB_BandUpper", "HB_Rim", "HB_Groove", "HB_Deck"]
    idx = {n: i for i, n in enumerate(names)}
    # (ox, oy, z, material of the strip from this ring to the next)
    profile = [
        (0.050, 0.040, BOTTOM_Z, "HB_Underside"),
        (0.020, 0.020, BOTTOM_Z + 0.005, "HB_BandDark"),
        (0.006, 0.006, -0.103, "HB_BandDark"),
        (0.000, 0.000, BAND[0], "HB_Band"),
        (-0.004, -0.004, -0.062, "HB_Band"),
        (0.000, 0.000, BAND[1], "HB_BandUpper"),
        (0.004, 0.004, -0.016, "HB_BandUpper"),
        (0.009, 0.009, 0.004, "HB_Rim"),
        (0.017, 0.016, 0.013, "HB_Rim"),
        (0.027, 0.024, RIM_Z, "HB_Rim"),
        (0.062, 0.050, RIM_Z, "HB_Rim"),
        (0.069, 0.055, 0.013, "HB_Groove"),
        (0.073, 0.058, 0.003, "HB_Groove"),
        (0.075, 0.059, -0.003, "HB_Groove"),
        (0.081, 0.063, -0.003, "HB_Groove"),
        (0.084, 0.065, DECK_Z, "HB_Deck"),
    ]
    rings = [ring(ox, oy, z) for ox, oy, z, _ in profile]
    # deck interior: scaled copies of the deck edge, then a centre cap
    deck = profile[-1]
    for s in (0.8, 0.6, 0.4, 0.2):
        rings.append(ring(deck[0], deck[1], DECK_Z, scale=s))
    strip_mats = [idx[m] for *_, m in profile] + [idx["HB_Deck"]] * 3
    # underside interior: scaled rings inward from the first ring
    under = [ring(0.05, 0.04, BOTTOM_Z, scale=s) for s in (0.25, 0.5, 0.75)]
    rings = under + rings
    strip_mats = [idx["HB_Underside"]] * 3 + strip_mats
    bm = bmesh.new()
    vs = loft(bm, rings, strip_mats)
    cap(bm, vs[0], idx["HB_Underside"], flip=True)
    cap(bm, vs[-1], idx["HB_Deck"])
    fix_normals(bm)
    ob = new_object("HB_Body", bm, [mats[n] for n in names], collection)
    return ob


# ---------------------------------------------------------------- deck and rim details

def strip_polyline(bm, pts, width, z, mat_index):
    """Flat ribbon along a 2D polyline (mitred joints) at height z, 1.2 mm thick."""
    left, right = [], []
    for i, p in enumerate(pts):
        p = Vector((*p, 0))
        d0 = (p - Vector((*pts[i - 1], 0))).normalized() if i > 0 else None
        d1 = (Vector((*pts[i + 1], 0)) - p).normalized() if i < len(pts) - 1 else None
        d = ((d0 or d1) + (d1 or d0)).normalized()
        n = Vector((-d.y, d.x, 0))
        cos_half = max(0.4, n.dot(Vector((-(d1 or d0).y, (d1 or d0).x, 0))))
        off = n * (width / 2 / cos_half)
        left.append(p + off)
        right.append(p - off)
    top = [(l + Vector((0, 0, z)), r + Vector((0, 0, z))) for l, r in zip(left, right)]
    for i in range(len(pts) - 1):
        f = bm.faces.new((bm.verts.new(top[i][1]), bm.verts.new(top[i + 1][1]),
                          bm.verts.new(top[i + 1][0]), bm.verts.new(top[i][0])))
        f.material_index = mat_index


def deck_edge_y(x, side):
    """y of the deck's edge (inner groove) at x, on the front (-1) or back (+1)."""
    a, b = A - 0.084, B - 0.065
    u = min(1.0, abs(x) / a)
    return side * b * (1 - u ** N_EXP) ** (1 / N_EXP)


def build_deck_details(mats, collection):
    names = ["HB_DeckLine", "HB_Cream", "HB_RimPlate"]
    bm = bmesh.new()
    lw, lz = 0.006, DECK_Z + 0.0012
    inset = 0.006
    def fe(x): return deck_edge_y(x, -1) + inset
    def be(x): return deck_edge_y(x, 1) - inset
    lines = []
    for s in (1, -1):
        lines += [
            [(s * 0.125, fe(0.125)), (s * 0.108, -0.035), (s * 0.0, -0.035)],
            [(s * 0.082, be(0.082)), (s * 0.070, 0.060), (s * 0.0, 0.060)],
            [(s * 0.108, -0.035), (s * 0.205, -0.035), (s * 0.240, 0.018), (s * 0.405, 0.018)],
            [(s * 0.070, 0.060), (s * 0.185, 0.060), (s * 0.212, be(0.212))],
            [(s * 0.205, -0.035), (s * 0.232, fe(0.232))],
            [(s * 0.330, 0.018), (s * 0.350, be(0.350))],
            [(s * 0.315, 0.018), (s * 0.338, fe(0.338))],
        ]
    for pl in lines:
        # keep the centre line continuous: drop duplicate centre points across both halves
        strip_polyline(bm, pl, lw, lz, 0)
    # chevrons: thick cream V at each deck tip, pointing outward (< on -X, > on +X)
    for s in (-1, 1):
        tip, arm, th = 0.452, 0.052, 0.030
        outline = [(tip, 0.0), (tip - arm, arm * 1.05), (tip - arm - th, arm * 1.05),
                   (tip - th * 1.35, 0.0), (tip - arm - th, -arm * 1.05), (tip - arm, -arm * 1.05)]
        pts = [(s * x, y) for x, y in outline]
        if s < 0:
            pts = list(reversed(pts))
        prism(bm, pts, lambda u, v, d: Vector((u, v, d)), DECK_Z, DECK_Z + 0.0025, 1)
    # rim inset plates: four, set into the rim's inner half at the diagonals
    rim_in, rim_out = (0.060, 0.049), (0.030, 0.026)
    for centre_deg in (35, 145, 215, 325):
        k0 = int(round((centre_deg - 13) / 360 * SAMPLES))
        k1 = int(round((centre_deg + 13) / 360 * SAMPLES))
        ks = [k % SAMPLES for k in range(k0, k1 + 1)]
        inner = ring(*rim_in, RIM_Z + 0.0022)
        outer = ring(*rim_out, RIM_Z + 0.0022)
        inner0 = ring(*rim_in, RIM_Z - 0.002)
        outer0 = ring(*rim_out, RIM_Z - 0.002)
        top = [(bm.verts.new(inner[k]), bm.verts.new(outer[k])) for k in ks]
        low = [(bm.verts.new(inner0[k]), bm.verts.new(outer0[k])) for k in ks]
        for i in range(len(ks) - 1):
            bm.faces.new((top[i][0], top[i + 1][0], top[i + 1][1], top[i][1])).material_index = 2
            bm.faces.new((low[i][0], top[i][0], top[i + 1][0], low[i + 1][0])).material_index = 2
            bm.faces.new((top[i][1], top[i + 1][1], low[i + 1][1], low[i][1])).material_index = 2
            bm.faces.new((low[i][1], low[i + 1][1], low[i + 1][0], low[i][0])).material_index = 2
        for i in (0, len(ks) - 1):
            q = (low[i][0], low[i][1], top[i][1], top[i][0])
            bm.faces.new(q if i == 0 else tuple(reversed(q))).material_index = 2
    fix_normals(bm)
    for f in bm.faces:
        if f.material_index == 0 and f.normal.z < 0:
            f.normal_flip()
    return new_object("HB_DeckDetails", bm, [mats[n] for n in names], collection)


# ---------------------------------------------------------------- side band decals (both sides)

def band_decal(bm, shape2d, x0, z0, outset, thickness, mat_index, side=-1):
    """A flat 2D shape (u along the band, v up) wrapped onto the band at x0, z0; side -1 = display side."""
    def to3d(u, v, d):
        p, _ = front_point(x0 + u, outset + d, z0 + v)
        return p if side < 0 else Vector((p.x, -p.y, p.z))
    prism(bm, shape2d, to3d, 0.0, thickness, mat_index)


def band_strip(bm, half_len, extent, x0, z0, outset, thickness, mat_index, side=-1, steps=40):
    """A shape on the band given by its vertical extent (v_lo, v_hi) at each u in [-half_len, half_len],
    built as quad strips that follow the band's curve (front, back, top, bottom, end walls)."""
    def to3d(u, v, d):
        p, _ = front_point(x0 + u, outset + d, z0 + v)
        return p if side < 0 else Vector((p.x, -p.y, p.z))
    us = [-half_len + 2 * half_len * i / steps for i in range(steps + 1)]
    cols = []
    for u in us:
        lo, hi = extent(u)
        cols.append([bm.verts.new(to3d(u, lo, thickness)), bm.verts.new(to3d(u, hi, thickness)),
                     bm.verts.new(to3d(u, hi, 0.0)), bm.verts.new(to3d(u, lo, 0.0))])
    for i in range(steps):
        a, b = cols[i], cols[i + 1]
        for k in range(4):
            k2 = (k + 1) % 4
            bm.faces.new((a[k], b[k], b[k2], a[k2])).material_index = mat_index
    bm.faces.new(tuple(reversed(cols[0]))).material_index = mat_index
    bm.faces.new(tuple(cols[-1])).material_index = mat_index


def pill_extent(length, height):
    r, flat = height / 2, length / 2 - height / 2
    def f(u):
        e = max(0.0, abs(u) - flat)
        h = math.sqrt(max(0.0, r * r - e * e))
        return (-max(h, 0.0004), max(h, 0.0004))
    return f


def rrect_extent(length, height, r, skew=0.0):
    flat = length / 2 - r
    def f(u):
        e = max(0.0, abs(u) - flat)
        h = height / 2 - r + math.sqrt(max(0.0, r * r - e * e))
        return (-max(h, 0.0004), max(h, 0.0004))
    return f


def build_band_details(mats, collection):
    names = ["HB_LightBar", "HB_BandDark", "HB_Accent"]
    bm = bmesh.new()
    accent_bm = bmesh.new()
    bar_len, bar_h, bar_z = 0.200, 0.020, -0.060
    track_len, track_h = 0.236, 0.032
    for side in (-1, 1):
        for s in (-1, 1):
            xc = s * 0.322
            band_strip(bm, track_len / 2, rrect_extent(track_len, track_h, 0.012), xc, bar_z, 0.0020, 0.0030, 1, side)
            band_strip(bm, bar_len / 2, pill_extent(bar_len, bar_h), xc, bar_z, 0.0040, 0.0030, 0, side)
            # two slanted orange stripes near each end ( // on the right, \\ on the left)
            for k in range(2):
                xs = s * (0.488 + 0.034 * k)
                lean = 0.012 * s
                para = [(-0.010 - lean, -0.017), (0.010 - lean, -0.017), (0.010 + lean, 0.017), (-0.010 + lean, 0.017)]
                band_decal(accent_bm, para, xs, bar_z + 0.002, 0.0030, 0.0025, 0, side)
    fix_normals(bm)
    fix_normals(accent_bm)
    details = new_object("HB_BandDetails", bm, [mats[n] for n in names[:2]], collection)
    accent = new_object("Accent", accent_bm, [mats["HB_Accent"]], collection)
    return details, accent


# ---------------------------------------------------------------- emblem module (display side) and a simpler far module

def build_module(mats, collection, side=-1, full=True):
    names = ["HB_ModuleFrame", "HB_Pod", "HB_Slot", "HB_Emblem", "HB_Sun"]
    bm = bmesh.new()
    y_band = side * B  # outer band at x = 0
    def at(u, v, d):
        # u along X, v up, d outward from the band (positive = toward the viewer on this side)
        return Vector((u, side * (B + d), v))
    # badge: rounded top tab that rises over the rim edge, tapering to a flat bottom
    badge = []
    for i in range(17):
        a = math.radians(180 * i / 16)
        badge.append((0.056 * math.cos(a), -0.024 + 0.030 * math.sin(a)))  # rounded top tab, centre z -0.024
    badge = [(x, y + 0.0) for x, y in badge]
    badge = [(0.066, -0.044)] + badge + [(-0.066, -0.044), (-0.044, -0.114), (0.044, -0.114)]
    # CCW as seen from outside: reverse on the -Y side
    outline = badge if side > 0 else list(reversed(badge))
    if full:
        prism(bm, outline, at, -0.03, 0.026, 0)
        # emblem disc and sun on the badge face
        disc = [(0.040 * math.cos(math.radians(a)), -0.058 + 0.040 * math.sin(math.radians(a))) for a in range(0, 360, 15)]
        prism(bm, disc if side > 0 else list(reversed(disc)), at, 0.020, 0.029, 3)
        dot = [(0.010 * math.cos(math.radians(a)), -0.058 + 0.010 * math.sin(math.radians(a))) for a in range(0, 360, 30)]
        prism(bm, dot if side > 0 else list(reversed(dot)), at, 0.025, 0.032, 4)
        for r in range(8):
            ang = math.radians(r * 45)
            c, s_ = math.cos(ang), math.sin(ang)
            r0, r1, hw = 0.016, 0.033, 0.0028
            ray = [(r0 * c - hw * -s_, r0 * s_ - hw * c), (r1 * c - hw * -s_, r1 * s_ - hw * c),
                   (r1 * c + hw * -s_, r1 * s_ + hw * c), (r0 * c + hw * -s_, r0 * s_ + hw * c)]
            ray = [(x, y - 0.058) for x, y in ray]
            prism(bm, ray if side > 0 else list(reversed(ray)), at, 0.025, 0.031, 4)
    else:
        small = [(0.05, -0.04), (0.05, -0.095), (-0.05, -0.095), (-0.05, -0.04)]
        prism(bm, small if side > 0 else list(reversed(small)), at, -0.03, 0.012, 0)
    # vent pods either side of the badge, following the band's curve
    for s in (-1, 1):
        xc = s * 0.128
        def to_band(u, v, d, _xc=xc):
            p, _ = front_point(_xc + u, d, -0.072 + v)
            return p if side < 0 else Vector((p.x, -p.y, p.z))
        if full:
            band_strip(bm, 0.0525, rrect_extent(0.105, 0.062, 0.014), xc, -0.072, -0.02, 0.040, 1, side, steps=16)
            for k in range(3):
                u = (k - 1) * 0.016
                slot = [(u - 0.006 - 0.006, -0.015), (u + 0.000 - 0.006, -0.015), (u + 0.006 + 0.004, 0.015), (u + 0.000 + 0.004, 0.015)]
                slot = slot if side > 0 else list(reversed(slot))
                prism(bm, slot, to_band, 0.019, 0.022, 2)
    fix_normals(bm)
    return new_object("HB_Module" + ("Front" if side < 0 else "Back"), bm, [mats[n] for n in names], collection)


# ---------------------------------------------------------------- underside thrusters

def build_thrusters(mats, collection):
    housing = bmesh.new()
    glow = bmesh.new()
    for x in (-0.30, 0.30):
        # housing: a short cylinder hanging under the underside plate
        bmesh.ops.create_cone(housing, cap_ends=True, cap_tris=False, segments=32, radius1=0.080, radius2=0.090,
                              depth=0.018, matrix=Matrix.Translation((x, 0, BOTTOM_Z - 0.009)))
        # glowing core ring and disc, just below the housing
        bmesh.ops.create_cone(glow, cap_ends=True, cap_tris=False, segments=32, radius1=0.056, radius2=0.056,
                              depth=0.004, matrix=Matrix.Translation((x, 0, BOTTOM_Z - 0.020)))
    fix_normals(housing)
    fix_normals(glow)
    h = new_object("HB_ThrusterHousing", housing, [mats["HB_Underside"]], collection)
    g = new_object("Thrusters", glow, [mats["HB_Thruster"]], collection)
    return h, g


# ---------------------------------------------------------------- assemble

def shade(ob, angle=38):
    ob.data.shade_smooth()
    ob.data.set_sharp_from_angle(angle=math.radians(angle))


def main():
    a = args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"
    sc.unit_settings.scale_length = 1.0
    col = bpy.data.collections.new("LOW")
    sc.collection.children.link(col)
    mats = make_materials()
    root = bpy.data.objects.new("Board", None)
    root.empty_display_type = "PLAIN_AXES"
    root.empty_display_size = 0.1
    col.objects.link(root)
    parts = [build_body(mats, col), build_deck_details(mats, col), *build_band_details(mats, col),
             build_module(mats, col, -1, True), build_module(mats, col, 1, True), *build_thrusters(mats, col)]
    for ob in parts:
        shade(ob, 34 if ob.name == "HB_Body" else 30)
        ob.parent = root
    tris = sum(sum(len(p.vertices) - 2 for p in ob.data.polygons) for ob in parts)
    print("[hoverboard] parts", [o.name for o in parts], "triangles", tris)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(a.out))


if __name__ == "__main__":
    main()
