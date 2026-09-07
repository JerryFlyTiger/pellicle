#!/usr/bin/env python3
"""Generate the pellicle app-icon artwork.

    dev/gen-icon.py

Writes, relative to the repository root:

    assets/icon/pellicle.icon/Assets/whole.svg   the icon's single layer
    assets/icon/pellicle-flat.svg                one flat file for docs/web

`assets/icon/pellicle.icon/icon.json` is *not* generated: it is the Icon
Composer document proper (gradient, per-group glass and shadow), hand-authored
and read back here so the flat file cannot drift from the real icon's colours.
`dev/make-app-bundle.sh` compiles the package with actool.

The mark: a lowercase lambda -- Emacs Lisp -- inside Lisp parentheses, its
right leg swept into a tapered wing tip for Swift. The gradient runs Swift
orange to Emacs purple.

Why the whole mark is one flat layer, and not the layered glass composition it
started as. The owner asked for the orange background in dark mode too. Icon
Composer 1.6 (Xcode 26.6) does not allow that to be authored:

  - The document `fill` is replaced, in the dark appearance, by a fixed neutral
    dark grey -- gray-gamma-22 white 0.192 to 0.078, read out of
    `ictool --export-intermediate-representation`, not derived from the authored
    colours at all.
  - This version has no per-appearance override. Its icon.json decoder reads
    only `fill`, `groups`, `supported-platforms`,
    `color-space-for-untagged-svg-colors`, `features`, `languages` and
    `implicit-asset-mirroring` at the top level; `fill-specializations`, which
    later versions use, is silently ignored by both ictool and actool. That is
    measured, not assumed: giving each candidate key a garbage string shows
    which ones make the decoder throw, and this one never does.
  - Painting the gradient into a *layer* does survive into the dark appearance.
    But any layer that is not the only one is composited as glass there, at a
    fill opacity low enough that a white glyph over a bright background washes
    out -- at 48 px, the Dock size, the mark was gone. Nothing fixes that:
    translucency off moves at most 18/255, blend modes and `lighting` move
    nothing, `glass: false` makes it worse, and it happens whether the glyph
    takes its colour from the layer `fill` or from its own SVG.

So the icon is one layer that already contains everything, which the dark
appearance leaves alone. The cost is the per-layer parallax and specular; the
alternative was an icon whose glyph vanished in the Dock.

Colours in that layer have to be written in **Display P3**:
`color-space-for-untagged-svg-colors` accepts no value but `display-p3` (every
other spelling is rejected outright), so untagged SVG hex is read as P3, and
writing sRGB hex there shifted the render by up to 64/255. The document `fill`
stays set to the sRGB gradient -- it is the one place the colours are authored,
it is what the flat file uses as-is, and it is what shows if the layer is ever
dropped -- and the P3 values below are converted from it.

Why the geometry is generated rather than drawn by hand in an editor: actool
accepts only a subset of SVG (Reticle.icon's artwork, read as prior art, is
likewise fill-only), so every stroke has to ship as an explicit filled
outline. Hand-maintaining several hundred outline points is not possible;
maintaining a dozen centreline control points and a width profile is. Round
terminals are emitted as real arcs, and because overlapping subpaths union
under fill-rule="nonzero" only when they share an orientation, every polygon
is normalised to counter-clockwise before it is written. That normalisation is
sufficient only while each ribbon is itself simple: a half-width larger than
its centreline's local radius of curvature makes the ribbon self-overlap, its
own shoelace sum mix signs, and the union produce a hole or a bowtie instead.
No profile here comes near that, and nothing checks it.

Two numbers this prints are the reason it prints anything: the content bounding
box (the icon's safe area is an assertion about pixels, so it is measured, not
eyeballed) and the closest approach of the lambda to the parentheses -- at the
unscaled sizes those two shapes touch, and the glyph scale below is what buys
the gap. The second is the smallest distance between two *vertices* of the
240-sample outlines, so it is an upper bound on the true curve-to-curve
distance, not that distance; it is computed over every vertex pair rather than
a subsample, because subsampling can only drop candidate pairs and therefore
only overstate the margin, and the full pass costs about 0.14 s.
"""

import json
import math
import os

N = 240  # samples per centreline
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONPKG = os.path.join(ROOT, "assets", "icon", "pellicle.icon")


# ------------------------------------------------------------------ geometry


def bez3(p0, p1, p2, p3, t):
    u = 1 - t
    return (
        u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
        u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
    )


def bez2(p0, p1, p2, t):
    u = 1 - t
    return (
        u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
    )


def width_at(profile, t):
    """Piecewise-linear half-width from [(t, halfwidth), ...] with t ascending."""
    if t <= profile[0][0]:
        return profile[0][1]
    for (t0, w0), (t1, w1) in zip(profile, profile[1:]):
        if t <= t1:
            return w0 + (w1 - w0) * (t - t0) / (t1 - t0)
    return profile[-1][1]


def ribbon(curve, profile, cap_start=True, cap_end=True):
    """Outline of a variable-width stroke along curve(t), as a closed point list."""
    pts = [curve(i / (N - 1)) for i in range(N)]
    # Central differences: a forward difference degenerates at the last sample,
    # and at a cusp it would flip the normal for one segment only.
    norms = []
    for i in range(N):
        a, b = pts[max(i - 1, 0)], pts[min(i + 1, N - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1e-9:
            # A cusp or a repeated sample. Dividing by a floor of 1.0 here would
            # yield the zero vector, which pinches the ribbon onto its centreline
            # at that one sample -- a visible notch. Carry the previous normal
            # instead; at i == 0 there is none, so seed an arbitrary but
            # consistent direction (a run of degenerate leading samples would
            # therefore carry the seed, not a computed normal). No centreline in
            # this file comes close -- the smallest central difference across
            # all five is 0.435 -- so this guards future edits, nothing here.
            norms.append(norms[-1] if norms else (0.0, 1.0))
            continue
        norms.append((-dy / length, dx / length))
    half = [width_at(profile, i / (N - 1)) for i in range(N)]

    left = [(p[0] + n[0] * w, p[1] + n[1] * w) for p, n, w in zip(pts, norms, half)]
    right = [(p[0] - n[0] * w, p[1] - n[1] * w) for p, n, w in zip(pts, norms, half)]

    def cap(centre, normal, w, sign):
        a0 = math.atan2(sign * normal[1], sign * normal[0])
        return [(centre[0] + math.cos(a0 - math.pi * k / 16) * w,
                 centre[1] + math.sin(a0 - math.pi * k / 16) * w) for k in range(1, 16)]

    out = list(left)
    if cap_end:
        out += cap(pts[-1], norms[-1], half[-1], 1)
    out += list(reversed(right))
    if cap_start:
        out += cap(pts[0], norms[0], half[0], -1)
    return out


def ccw(poly):
    """Normalise orientation; nonzero-rule union only works one-directionally.

    Assumes `poly` is simple -- see the self-overlap caveat in the module
    docstring. The shoelace sign is meaningless for a self-intersecting ring.
    """
    twice_area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1]
                     - poly[(i + 1) % len(poly)][0] * poly[i][1]
                     for i in range(len(poly)))
    return poly if twice_area >= 0 else list(reversed(poly))


def path_data(polys):
    return " ".join("M " + " L ".join("%.2f %.2f" % p for p in ccw(poly)) + " Z"
                    for poly in polys)


def scale_about(cx, cy, s):
    return lambda p: (cx + (p[0] - cx) * s, cy + (p[1] - cy) * s)


def compose(*fns):
    def apply(p):
        for fn in fns:
            p = fn(p)
        return p
    return apply


def canvas_rect(side=1024.0):
    """The background layer: the whole canvas, which the icon shape then masks."""
    return [(0.0, 0.0), (side, 0.0), (side, side), (0.0, side)]


def squircle(side=1024.0, n=5.5, steps=400):
    """Superellipse standing in for the macOS icon mask in the flat file only."""
    a = side / 2.0
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((a + a * math.copysign(abs(c) ** (2 / n), c),
                    a + a * math.copysign(abs(s) ** (2 / n), s)))
    return pts


# ------------------------------------------------------------------- the mark

# A lowercase lambda is an inverted V *plus* a tail hooking up-left from the
# apex. The first attempt ran the tail collinear with the right leg and the
# 256px render read as an "A"; the tail is therefore its own, shallower stroke,
# breaking about 30 degrees off the leg.
APEX = (474, 360)

tail = lambda t: bez2((348, 286), (398, 300), APEX, t)
tail_profile = [(0.00, 20), (1.00, 54)]

# Right leg -- the Swift half: it descends, then flicks right into a tapered
# wing tip rather than landing square on the baseline.
leg = lambda t: bez3(APEX, (530, 500), (624, 706), (760, 772), t)
leg_profile = [(0.00, 56), (0.55, 58), (0.78, 46), (1.00, 9)]

# Left leg: to the baseline with a hair of bow, round terminal.
left = lambda t: bez2(APEX, (390, 580), (292, 796), t)
left_profile = [(0.00, 56), (1.00, 48)]

# The parentheses: tapered, and taller than the glyph they frame.
lp = lambda t: bez2((268, 196), (148, 518), (268, 840), t)
rp = lambda t: bez2((756, 196), (876, 518), (756, 840), t)
paren_profile = [(0.00, 15), (0.50, 31), (1.00, 15)]

# The lambda is drawn oversized for control, then scaled about its own centre
# and recentred; that scale is what opens the clearance printed at the end.
# GROW then sets how much of the canvas the whole composition occupies.
GROW = scale_about(512, 512, 1.03)
LAM_X = compose(scale_about(506, 555, 0.86), lambda p: (p[0] + 6, p[1] - 37), GROW)

lam = [[LAM_X(p) for p in poly] for poly in
       (ribbon(leg, leg_profile),
        ribbon(left, left_profile, cap_start=False),
        ribbon(tail, tail_profile, cap_end=False))]
par = [[GROW(p) for p in poly] for poly in
       (ribbon(lp, paren_profile), ribbon(rp, paren_profile))]


# --------------------------------------------------------------------- output

SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
       'width="1024" height="1024">\n%s\n</svg>\n')


def write(path, body):
    with open(path, "w") as f:
        f.write(SVG % body)
    print("wrote %s" % os.path.relpath(path, ROOT))


def hex_of(fill):
    """'srgb:r,g,b,a' as authored in icon.json -> '#rrggbb' (still sRGB)."""
    r, g, b, _a = (float(v) for v in fill.split(":", 1)[1].split(","))
    return "#%02x%02x%02x" % tuple(min(255, max(0, round(c * 255))) for c in (r, g, b))


# sRGB and Display P3 share a transfer function and a white point (D65) and
# differ only in primaries, so the conversion is decode, one 3x3, re-encode.
# Both matrices are the standard D65 ones; the product is applied directly.
SRGB_TO_XYZ = ((0.4123907993, 0.3575843394, 0.1804807884),
               (0.2126390059, 0.7151686788, 0.0721923154),
               (0.0193308187, 0.1191947798, 0.9505321522))
XYZ_TO_P3 = ((2.4934969119, -0.9313836179, -0.4027107845),
             (-0.8294889696, 1.7626640603, 0.0236246858),
             (0.0358458302, -0.0761723893, 0.9568845240))


def _decode(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _encode(c):
    c = min(1.0, max(0.0, c))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def p3_hex_of(fill):
    """'srgb:r,g,b,a' -> '#rrggbb' in Display P3, for untagged SVG colours."""
    lin = [_decode(float(v)) for v in fill.split(":", 1)[1].split(",")[:3]]
    xyz = [sum(m * c for m, c in zip(row, lin)) for row in SRGB_TO_XYZ]
    p3 = [sum(m * c for m, c in zip(row, xyz)) for row in XYZ_TO_P3]
    return "#%02x%02x%02x" % tuple(round(_encode(c) * 255) for c in p3)


with open(os.path.join(ICONPKG, "icon.json")) as f:
    stops = json.load(f)["fill"]["linear-gradient"]
if len(stops) != 2:
    # The same limit actool enforces, failed here with a message that names it
    # rather than as a bare "too many values to unpack".
    raise SystemExit('icon.json: linear-gradient has %d stops, and actool takes '
                     'exactly two ("Linear gradients require exactly 2 colors")'
                     % len(stops))
top, bottom = (hex_of(s) for s in stops)

BODY = """  <defs>
    <linearGradient id="bg" %s>
      <stop offset="0" stop-color="%s"/>
      <stop offset="1" stop-color="%s"/>
    </linearGradient>
  </defs>
  <path fill="url(#bg)" d="%s"/>
  <path fill="#ffffff" fill-opacity="0.82" fill-rule="nonzero" d="%s"/>
  <path fill="#ffffff" fill-rule="nonzero" d="%s"/>"""

# The macOS icon shape is the middle 80% of the canvas, and the document `fill`
# runs its gradient across the shape, not across the canvas. A layer's own
# gradient runs across the canvas, so pinning it to the shape's box is what
# makes the two agree; measured by rendering a black-to-white ramp both ways at
# 512 px and reading the rows (fill: 0.1874/0.4998/0.8120 at y=128/256/384, i.e.
# a span of exactly 512*0.8 centred; layer: 0.2496/0.4998/0.7495, exactly 512).
# Outside the stops the gradient pads, which is right: that area is masked off.
SHAPE_INSET = 0.10
SPAN = ('gradientUnits="userSpaceOnUse" x1="0" y1="%.1f" x2="0" y2="%.1f"'
        % (1024 * SHAPE_INSET, 1024 * (1 - SHAPE_INSET)))

# The icon package's single layer. It paints the bare canvas rather than a
# squircle, because the icon shape masks it; the flat file below draws its own,
# because nothing masks that, and its gradient spans that squircle.
write(os.path.join(ICONPKG, "Assets", "whole.svg"),
      BODY % (SPAN, p3_hex_of(stops[0]), p3_hex_of(stops[1]),
              path_data([canvas_rect()]), path_data(par), path_data(lam)))

write(os.path.join(ROOT, "assets", "icon", "pellicle-flat.svg"),
      BODY % ('x1="0" y1="0" x2="0" y2="1"', top, bottom,
              path_data([squircle()]), path_data(par), path_data(lam)))


# The two measurements this file exists to keep honest.
allpts = [p for poly in lam + par for p in poly]
xs, ys = [p[0] for p in allpts], [p[1] for p in allpts]
print("content bbox x %.0f..%.0f y %.0f..%.0f (%.0f%% x %.0f%% of the canvas)"
      % (min(xs), max(xs), min(ys), max(ys),
         (max(xs) - min(xs)) / 10.24, (max(ys) - min(ys)) / 10.24))
lamp = [p for poly in lam for p in poly]
parp = [p for poly in par for p in poly]
print("lambda x %.0f..%.0f y %.0f..%.0f; closest lambda-paren vertices %.2f px"
      % (min(p[0] for p in lamp), max(p[0] for p in lamp),
         min(p[1] for p in lamp), max(p[1] for p in lamp),
         min(math.hypot(a[0] - b[0], a[1] - b[1]) for a in lamp for b in parp)))
