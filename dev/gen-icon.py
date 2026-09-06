#!/usr/bin/env python3
"""Generate the swiftemacs app-icon artwork.

    dev/gen-icon.py

Writes, relative to the repository root:

    assets/icon/swiftemacs.icon/Assets/lambda.svg   layer 2 (front), the glyph
    assets/icon/swiftemacs.icon/Assets/parens.svg   layer 1 (back), the frame
    assets/icon/swiftemacs-flat.svg                 one flat file for docs/web

`assets/icon/swiftemacs.icon/icon.json` is *not* generated: it is the Icon
Composer document proper (gradient, per-group glass and shadow), hand-authored
and read back here so the flat file cannot drift from the real icon's colours.
`dev/make-app-bundle.sh` compiles the package with actool.

The mark: a lowercase lambda -- Emacs Lisp -- inside Lisp parentheses, its
right leg swept into a tapered wing tip for Swift. The gradient runs Swift
orange to Emacs purple.

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
ICONPKG = os.path.join(ROOT, "assets", "icon", "swiftemacs.icon")


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
    """'srgb:r,g,b,a' as authored in icon.json -> '#rrggbb'."""
    r, g, b, _a = (float(v) for v in fill.split(":", 1)[1].split(","))
    return "#%02x%02x%02x" % tuple(min(255, max(0, round(c * 255))) for c in (r, g, b))


with open(os.path.join(ICONPKG, "icon.json")) as f:
    stops = json.load(f)["fill"]["linear-gradient"]
if len(stops) != 2:
    # The same limit actool enforces, failed here with a message that names it
    # rather than as a bare "too many values to unpack".
    raise SystemExit('icon.json: linear-gradient has %d stops, and actool takes '
                     'exactly two ("Linear gradients require exactly 2 colors")'
                     % len(stops))
top, bottom = (hex_of(s) for s in stops)

assets = os.path.join(ICONPKG, "Assets")
write(os.path.join(assets, "lambda.svg"),
      '  <path fill-rule="nonzero" d="%s"/>' % path_data(lam))
write(os.path.join(assets, "parens.svg"),
      '  <path fill-rule="nonzero" d="%s"/>' % path_data(par))

write(os.path.join(ROOT, "assets", "icon", "swiftemacs-flat.svg"), """  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="%s"/>
      <stop offset="1" stop-color="%s"/>
    </linearGradient>
  </defs>
  <path fill="url(#bg)" d="%s"/>
  <path fill="#ffffff" fill-opacity="0.82" fill-rule="nonzero" d="%s"/>
  <path fill="#ffffff" fill-rule="nonzero" d="%s"/>""" % (
    top, bottom, path_data([squircle()]), path_data(par), path_data(lam)))


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
