"""Tiny SVG kit for the Mochi wardrobe: materials with gradient, rim shade,
rim light, highlight and glint, all on the 200x200 template artboard."""
import math
import re

# Reference Mochi (shape "mochi"): R = 50 at (100, 100), rx 1.14 R, ry 0.88 R, n 2.7.
RX, RY, N = 57.0, 44.0, 2.7


def head_half(yn):
    """Half-width of the reference head at height yn (-1 top ... 1 bottom)."""
    y = min(1.0, abs(yn))
    return RX * (1 - y ** N) ** (1 / N)


def seat(yn):
    """data-seat values for a hat whose seat is at yn: (x, y, half)."""
    return 100.0, 100 + yn * RY, head_half(yn)


T = {  # hi, base, shade, deep
    "sky": ("#A5E3FD", "#38BDF8", "#1E9FD9", "#1580B3"),
    "honey": ("#FFDB80", "#F7B32B", "#DE9A16", "#B97A0B"),
    "gold": ("#FFF0B3", "#FFCB45", "#E8A21C", "#B97A0B"),
    "berry": ("#FF8A93", "#F4505E", "#D63C4B", "#A82536"),
    "mint": ("#8EF0D2", "#2DD4A7", "#20AF89", "#14876A"),
    "lilac": ("#D2C4FE", "#A78BFA", "#8A6CEB", "#6447C9"),
    "plum": ("#B79CFF", "#7C5CFF", "#5B3FD6", "#3F27A8"),
    "cocoa": ("#9A7360", "#6B4A3A", "#523629", "#3A251B"),
    "charcoal": ("#5A5D68", "#2A2B30", "#1C1D21", "#0E0F11"),
    "cream": ("#FFFFFF", "#FFF6E8", "#EAD6B0", "#C9AE82"),
    "white": ("#FFFFFF", "#F7F8FA", "#DADDE3", "#B8BCC6"),
    "tan": ("#F2C98D", "#D9A15B", "#B97F3E", "#8E5B26"),
    "leaf": ("#B5F07A", "#6CCB45", "#47A332", "#2E7A22"),
    "navy": ("#8EA2FF", "#4C63E0", "#3446B8", "#22308A"),
    "pink": ("#FFE0E4", "#FFC2C8", "#F79AA6", "#E07A88"),
    "straw": ("#FFF0B8", "#F5D27A", "#DDB257", "#B88D35"),
    "orange": ("#FFC48A", "#FF8A3D", "#E8661C", "#B84A0E"),
}

NARGS = {"M": 2, "L": 2, "C": 6, "Q": 4, "S": 4, "T": 2, "A": 7, "H": 1, "V": 1, "Z": 0}


def f(v):
    s = f"{v:.1f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def parse(d):
    toks = re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?", d)
    out, i, cmd = [], 0, None
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            assert cmd in NARGS, f"use absolute commands only: {cmd}"
            i += 1
            if cmd == "Z":
                out.append(("Z", []))
                continue
        n = NARGS[cmd]
        out.append((cmd, [float(t) for t in toks[i:i + n]]))
        i += n
        if cmd == "M":
            cmd = "L"
    return out


def xform(d, fn, radii=None):
    """Applies fn(x, y) -> (x, y) to every point of an absolute path (and
    radii(rx, ry) to arc radii, when given)."""
    parts = []
    for cmd, a in parse(d):
        if cmd == "Z":
            parts.append("Z")
            continue
        if cmd == "H" or cmd == "V":
            raise ValueError("H/V not supported in xform")
        if cmd == "A":
            x, y = fn(a[5], a[6])
            rx, ry = radii(a[0], a[1]) if radii else (a[0], a[1])
            parts.append("A" + " ".join(f(v) for v in [rx, ry] + a[2:5] + [x, y]))
            continue
        pts = []
        for j in range(0, len(a), 2):
            x, y = fn(a[j], a[j + 1])
            pts += [x, y]
        parts.append(cmd + " ".join(f(v) for v in pts))
    return " ".join(parts)


def move(d, dx, dy):
    return xform(d, lambda x, y: (x + dx, y + dy))


def mirror(d, cx=100):
    return xform(d, lambda x, y: (2 * cx - x, y))


def rot(d, deg, cx, cy):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return xform(d, lambda x, y: (cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c))


def scale(d, k, cx, cy, ky=None):
    ky = k if ky is None else ky
    return xform(d, lambda x, y: (cx + (x - cx) * k, cy + (y - cy) * ky), lambda rx, ry: (rx * k, ry * ky))


def smooth(pts, closed=True):
    """Catmull-Rom through points, as cubic Beziers."""
    n = len(pts)
    P = lambda i: pts[i % n] if closed else pts[max(0, min(n - 1, i))]
    d = f"M{f(pts[0][0])},{f(pts[0][1])}"
    for i in range(n if closed else n - 1):
        p0, p1, p2, p3 = P(i - 1), P(i), P(i + 1), P(i + 2)
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{f(c1[0])},{f(c1[1])} {f(c2[0])},{f(c2[1])} {f(p2[0])},{f(p2[1])}"
    return d + (" Z" if closed else "")


def poly(pts, closed=True):
    d = "M" + " L".join(f"{f(x)},{f(y)}" for x, y in pts)
    return d + (" Z" if closed else "")


def ell(cx, cy, rx, ry=None):
    ry = rx if ry is None else ry
    return (f"M{f(cx - rx)},{f(cy)} A{f(rx)} {f(ry)} 0 1 0 {f(cx + rx)},{f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 0 {f(cx - rx)},{f(cy)} Z")


def epts(cx, cy, rx, ry, a0, a1, n=24):
    """Points on an ellipse from angle a0 to a1 (degrees, 0 = right, 90 = down)."""
    return [(cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def rrect(x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    return (f"M{f(x + r)},{f(y)} L{f(x + w - r)},{f(y)} A{f(r)} {f(r)} 0 0 1 {f(x + w)},{f(y + r)} "
            f"L{f(x + w)},{f(y + h - r)} A{f(r)} {f(r)} 0 0 1 {f(x + w - r)},{f(y + h)} "
            f"L{f(x + r)},{f(y + h)} A{f(r)} {f(r)} 0 0 1 {f(x)},{f(y + h - r)} "
            f"L{f(x)},{f(y + r)} A{f(r)} {f(r)} 0 0 1 {f(x + r)},{f(y)} Z")


def fluff(cx, cy, r, bumps=9, amp=0.12, phase=0.0, n=72):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        rr = r * (1 + amp * (0.5 + 0.5 * math.cos(bumps * a + phase)) - amp * 0.5)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return smooth(pts)


def star(cx, cy, r, inner=0.48, n=5, rot_deg=-90, round_=True):
    pts = []
    for i in range(n * 2):
        a = math.radians(rot_deg + 180 * i / n)
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return smooth(pts) if round_ else poly(pts)


def heart(cx, cy, w, h):
    """A plump heart centred on (cx, cy), w wide, h tall."""
    x0, y0 = cx - w / 2, cy - h / 2
    X = lambda u: x0 + u * w
    Y = lambda v: y0 + v * h
    return (f"M{f(X(.5))},{f(Y(.26))} C{f(X(.42))},{f(Y(.06))} {f(X(0))},{f(Y(-.02))} {f(X(0))},{f(Y(.32))} "
            f"C{f(X(0))},{f(Y(.6))} {f(X(.3))},{f(Y(.78))} {f(X(.5))},{f(Y(1))} "
            f"C{f(X(.7))},{f(Y(.78))} {f(X(1))},{f(Y(.6))} {f(X(1))},{f(Y(.32))} "
            f"C{f(X(1))},{f(Y(-.02))} {f(X(.58))},{f(Y(.06))} {f(X(.5))},{f(Y(.26))} Z")


BIG = "M-60,-60 L260,-60 L260,260 L-60,260 Z"
GUIDE = ('  <g id="guide" opacity="0.25"><ellipse cx="100" cy="100" rx="57" ry="44" fill="#DDDDDD"/>'
         '<ellipse cx="79.5" cy="105.3" rx="6.2" ry="6.8" fill="#1A1412"/>'
         '<ellipse cx="120.5" cy="105.3" rx="6.2" ry="6.8" fill="#1A1412"/></g>')


def stops_xml(stops):
    out = ""
    for st in stops:
        o, c, a = (tuple(st) + (1,))[:3]
        op = "" if a == 1 else ' stop-opacity="' + f(a) + '"'
        out += f'<stop offset="{f(o)}" stop-color="{c}"{op}/>'
    return out


class Art:
    def __init__(self, slot, name, **attrs):
        self.slot, self.name, self.attrs = slot, name, attrs
        self.defs, self.out, self.n = [], [], 0
        self.stack = [self.out]

    def uid(self, p):
        self.n += 1
        return f"{p}{self.n}"

    # ── defs ──
    def lin(self, x1, y1, x2, y2, stops):
        i = self.uid("g")
        s = stops_xml(stops)
        self.defs.append(f'<linearGradient id="{i}" gradientUnits="userSpaceOnUse" x1="{f(x1)}" y1="{f(y1)}" '
                         f'x2="{f(x2)}" y2="{f(y2)}">{s}</linearGradient>')
        return f"url(#{i})"

    def rad(self, cx, cy, r, stops, fx=None, fy=None):
        i = self.uid("g")
        s = stops_xml(stops)
        foc = "" if fx is None else f' fx="{f(fx)}" fy="{f(fy)}"'
        self.defs.append(f'<radialGradient id="{i}" gradientUnits="userSpaceOnUse" cx="{f(cx)}" cy="{f(cy)}" '
                         f'r="{f(r)}"{foc}>{s}</radialGradient>')
        return f"url(#{i})"

    def clip(self, d):
        if self.shrink:
            d = scale(d, self.shrink[0], self.shrink[1], self.shrink[2])
        i = self.uid("c")
        self.defs.append(f'<clipPath id="{i}"><path d="{d}"/></clipPath>')
        return f"url(#{i})"

    # ── elements ──
    shrink = None

    def p(self, d, fill, op=None, rule=None):
        if op == 0:
            return
        if self.shrink:
            rest = d[len(BIG):] if d.startswith(BIG) else d
            d = (BIG + " " if d.startswith(BIG) else "") + scale(rest.strip(), *self.shrink)
        a = f' opacity="{f(op)}"' if op is not None and op < 1 else ""
        r = f' fill-rule="{rule}"' if rule else ""
        self.stack[-1].append(f'<path d="{d}" fill="{fill}"{a}{r}/>')

    def begin(self, clip=None, swing=None, amp=None, layer=None, comment=None):
        attrs = ""
        if clip:
            attrs += f' clip-path="{clip}"'
        if swing:
            attrs += f' data-swing="{f(swing[0])} {f(swing[1])}"'
        if amp is not None:
            attrs += f' data-amp="{f(amp)}"'
        if layer:
            attrs += f' data-layer="{layer}"'
        self.stack.append([])
        self._g = attrs
        self.stack[-1].append(("open", attrs, comment))

    def end(self):
        items = self.stack.pop()
        _, attrs, comment = items[0]
        body = "".join(items[1:])
        c = f"<!-- {comment} -->" if comment else ""
        self.stack[-1].append(f"{c}<g{attrs}>{body}</g>")

    def comment(self, text):
        self.stack[-1].append(f"<!-- {text} -->")

    # ── material: the house style ──
    def mat(self, d, tone, box, rim=2.6, light=1.2, hl=None, hl_op=0.3, glint=None, glint_op=0.8,
            grad=None, pattern=None, ao=None, rim_op=0.6):
        """One shaped piece of material, lit from the top right like Mochi:
        a diagonal gradient, the pattern, a crisp darker rim along the lower
        left, a thin rim light on the upper right, a soft highlight blob and a
        glint."""
        hi, base, shade, deep = T[tone] if isinstance(tone, str) else tone
        x0, y0, x1, y1 = box
        fill = grad or self.lin(x1, y0, x0, y1, [(0, hi), (0.38, base), (1, shade)])
        self.p(d, fill)
        c = self.clip(d)
        self.begin(clip=c)
        if pattern:
            pattern(self)
        if ao:
            for ad, aop in ao:
                self.p(ad, "#000000", aop)
        if rim:
            self.p(BIG + " " + move(d, rim * 0.75, -rim * 0.75), deep, rim_op, "evenodd")
        if light:
            self.p(BIG + " " + move(d, -light * 0.75, light * 0.75), "#FFFFFF", 0.35, "evenodd")
        if hl:
            self.p(hl, "#FFFFFF", hl_op)
        self.end()
        if glint:
            self.p(glint, "#FFFFFF", glint_op)
        return c

    def svg(self, guide=True):
        attrs = "".join(f' {k.replace("_", "-")}="{v}"' for k, v in self.attrs.items())
        defs = ("  <defs>" + "".join(self.defs) + "</defs>\n") if self.defs else ""
        body = "\n".join("  " + e for e in self.out)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" data-slot="{self.slot}" '
                f'data-name="{self.name}"{attrs}>\n{defs}{GUIDE if guide else ""}\n{body}\n</svg>\n')


def glint(x, y, w=6, h=2.4, deg=-35):
    return rot(rrect(x - w / 2, y - h / 2, w, h, h / 2), deg, x, y)


def ell_rev(cx, cy, rx, ry=None):
    """An ellipse drawn the other way round: a hole under the nonzero rule."""
    ry = rx if ry is None else ry
    return (f"M{f(cx - rx)},{f(cy)} A{f(rx)} {f(ry)} 0 1 1 {f(cx + rx)},{f(cy)} "
            f"A{f(rx)} {f(ry)} 0 1 1 {f(cx - rx)},{f(cy)} Z")


def rrect_pts(x, y, w, h, r, n=6):
    pts = []
    for cx, cy, a0 in [(x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)]:
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def holed(outer, *inners, smooth_=True):
    """Outer outline with holes (point lists): fills and clips under nonzero."""
    mk = smooth if smooth_ else poly
    return " ".join([mk(outer)] + [mk(list(reversed(i))) for i in inners])


def union_circles(circles, n=90):
    """Outline of a union of circles (x, y, r), as dense points around its centre."""
    cx = sum(c[0] for c in circles) / len(circles)
    cy = sum(c[1] for c in circles) / len(circles)
    pts = []
    for (x, y, r) in circles:
        for i in range(n):
            a = 2 * math.pi * i / n
            px, py = x + r * math.cos(a), y + r * math.sin(a)
            if all((px - x2) ** 2 + (py - y2) ** 2 >= (r2 - 0.01) ** 2 for (x2, y2, r2) in circles if (x2, y2, r2) != (x, y, r)):
                pts.append((px, py))
    pts.sort(key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    return pts


def ribbon(spine, widths):
    """A soft shape grown along a spine: widths[i] is the full width at spine[i]."""
    left, right = [], []
    n = len(spine)
    for i, (x, y) in enumerate(spine):
        x0, y0 = spine[max(0, i - 1)]
        x1, y1 = spine[min(n - 1, i + 1)]
        tx, ty = x1 - x0, y1 - y0
        ln = math.hypot(tx, ty) or 1
        nx, ny = -ty / ln, tx / ln
        w = widths[i] / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    return smooth(left + right[::-1])


def bez(p0, p1, p2, n=16):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in [i / n for i in range(n + 1)]]


def taper(n, base, mid, tip_round=True):
    """Ear-like width profile: narrow base, full by a third, round tip."""
    out = []
    for i in range(n + 1):
        t = i / n
        w = base + (mid - base) * min(1, t / 0.35)
        if t > 0.7:
            w *= math.sqrt(max(0, 1 - ((t - 0.7) / 0.3) ** 2)) if tip_round else 1
        out.append(max(w, 0.01))
    return out
