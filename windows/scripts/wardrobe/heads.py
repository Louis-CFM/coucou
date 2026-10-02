from kit import *


def hat(name, yn, **kw):
    x, y, half = seat(yn)
    return Art("head", name, data_seat=f"{f(x)} {f(y)} {f(half)}", data_seat_yn=f(yn), **kw)


def beanie():
    a = hat("Beanie", -0.41)
    dome = "M47,72 C46,44 68,27 100,27 C132,27 154,44 153,72 Z"

    def ribs(s):
        for i in range(10):
            x = 50 + i * 11.1
            cx = 100 + (x - 100) * 1.18
            s.p(f"M100,28 Q{f(cx - 1.6)},44 {f(x - 1.7)},74 L{f(x + 1.7)},74 Q{f(cx + 1.6)},44 100,28 Z",
                T["honey"][3], 0.32)
    a.mat(dome, "honey", (46, 27, 154, 74), rim=3.4, pattern=ribs,
          hl="M108,31 C128,34 144,46 148,62 C138,50 126,42 106,38 Z", hl_op=0.3)
    cuff = ("M43,62 C66,71 134,71 157,62 C159,62 160.5,64.5 160.5,68 L159.5,78 C159,81 157,82.5 154,83 "
            "C132,92 68,92 46,83 C43,82.5 41,81 40.5,78 L39.5,68 C39.5,64.5 41,62 43,62 Z")

    def cuff_ribs(s):
        for i in range(21):
            x = 43 + i * 5.7
            u = (x - 100) / 60
            yt = 62 + 8.5 * (1 - u * u)
            yb = 83 + 8.5 * (1 - u * u)
            w = 2.6 * (0.45 + 0.55 * math.sqrt(max(0, 1 - u * u)))
            s.p(rrect(x - w / 2, yt + 1.5, w, yb - yt - 3, w / 2), T["honey"][3], 0.4)
    a.mat(cuff, "honey", (40, 62, 160, 92), rim=2.6, pattern=cuff_ribs,
          ao=[("M30,58 C70,72 130,72 170,58 L170,64 C130,78 70,78 30,64 Z", 0.0)],
          hl="M118,66 C134,64 148,62 155,63 L155,67 C144,69 132,70 118,70 Z", hl_op=0.35)
    # the cuff shades the dome just above it
    a.begin(clip=a.clip(dome))
    a.p("M40,58 C66,68 134,68 160,58 L160,74 L40,74 Z", "#000000", 0.14)
    a.end()
    # pom-pom
    pom = fluff(100, 24.5, 10.4, bumps=11, amp=0.16)
    a.mat(pom, "cream", (89, 14, 111, 35), rim=2.2,
          hl=ell(104, 20, 5, 3.6), hl_op=0.5)
    for (x, y, r) in [(94, 28, 1.3), (99, 31, 1.1), (93, 22.5, 1.1), (106, 29, 1.0)]:
        a.p(ell(x, y, r * 1.6, r), T["cream"][3], 0.55)
    return a


def tophat():
    a = hat("Top hat", -0.8)
    hi, base, shade, deep = T["charcoal"]
    # brim: lit top face, darker front lip
    brim_top = ell(100, 66, 48, 9.5)
    a.mat(brim_top, "charcoal", (52, 56, 148, 76), rim=0, light=0,
          grad=a.lin(100, 56, 100, 76, [(0, "#1C1D21"), (0.5, "#2A2B30"), (1, "#4A4C55")]))
    lip = smooth(epts(100, 66, 48, 9.5, 0, 180, 30) + epts(100, 69.5, 48, 9.5, 180, 0, 30)[::-1][::-1], closed=True)
    lip = poly(epts(100, 66, 48, 9.5, 0, 180, 40) + epts(100, 69.6, 47, 9.6, 180, 0, 40))
    a.p(lip, deep)
    # crown
    crown = ("M71,66 L69,23 " + " ".join(f"L{f(x)},{f(y)}" for x, y in epts(100, 23, 31, 6.5, 180, 360, 24)) +
             " L129,66 " + " ".join(f"L{f(x)},{f(y)}" for x, y in epts(100, 66, 29, 6.5, 0, 180, 24)) + " Z")
    crown_g = a.lin(131, 30, 69, 60, [(0, "#4A4C55"), (0.3, "#2A2B30"), (1, "#1C1D21")])
    a.mat(crown, "charcoal", (69, 16, 131, 73), rim=2.4, grad=crown_g,
          hl=rrect(114, 26, 7, 26, 3.5), hl_op=0.14)
    # band
    band = poly(epts(100, 52, 30.2, 6.5, 0, 180, 30) + epts(100, 62.5, 29.4, 6.5, 180, 0, 30))
    a.begin(clip=a.clip(crown))
    a.p(poly(epts(100, 62.5, 30, 6.5, 0, 180, 30) + epts(100, 66, 30, 6.5, 180, 0, 30)), "#000000", 0.35)
    a.end()
    a.mat(band, "berry", (69, 45, 131, 69), rim=1.6, light=0.8,
          hl=poly(epts(100, 53.6, 26, 6, 20, 75, 10) + epts(100, 56.2, 26, 6, 75, 20, 10)), hl_op=0.45)
    # top
    top = ell(100, 23, 31, 6.5)
    a.p(top, a.lin(118, 17, 86, 29, [(0, "#5A5D68"), (1, "#2A2B30")]))
    a.p(poly(epts(100, 23, 31, 6.5, 200, 340, 20) + epts(100, 24.6, 28, 4.6, 340, 200, 20)), "#FFFFFF", 0.12)
    a.p(rrect(118.6, 27, 3.2, 20, 1.6), "#FFFFFF", 0.35)
    return a


def partyhat():
    a = hat("Party hat", -0.84)
    ax, ay = 101, 25
    cone = (f"M75,62 L{f(ax - 3)},{f(ay + 3)} C{f(ax - 1.5)},{f(ay - 0.6)} {f(ax + 1.5)},{f(ay - 0.6)} "
            f"{f(ax + 3)},{f(ay + 3)} L125,62 " +
            " ".join(f"L{f(x)},{f(y)}" for x, y in epts(100, 62, 25, 6, 0, 180, 24)) + " Z")

    def stripes(s):
        cols = [T["honey"][1], T["mint"][1], T["berry"][1]]
        for i, y in enumerate([33, 43, 53]):
            k = (y - ay) / (62 - ay)
            w = 25 * k + 6
            s.p(poly(epts(100, y, w, 4.2 * k + 1, 0, 180, 20) + epts(100, y + 4.6, w + 3, 4.6 * k + 1, 180, 0, 20)),
                cols[i])
    a.mat(cone, "lilac", (75, 22, 125, 68), rim=2.6, pattern=stripes,
          hl="M106,32 L116,54 C118,58 119,60 120,62 L117,62 C112,52 108,42 104,33 Z", hl_op=0.35)
    # fluffy trim
    trim = smooth([(x, y + 1.6 * math.sin(i * 1.9)) for i, (x, y) in enumerate(epts(100, 60.5, 27.5, 6, 180, 360, 14))] +
                  [(x, y + 1.8 * math.sin(i * 2.3 + 1)) for i, (x, y) in enumerate(epts(100, 64.5, 28, 7.5, 0, 180, 14))])
    a.mat(trim, "white", (72, 53, 128, 73), rim=2.0, light=0.8)
    pom = fluff(ax, ay - 2, 6.6, bumps=9, amp=0.2)
    a.mat(pom, "berry", (ax - 7, ay - 9, ax + 7, ay + 5), rim=1.6, hl=ell(ax + 2.2, ay - 4.6, 3, 2), hl_op=0.5)
    return a


def crown():
    a = hat("Crown", -0.88)
    hi, base, shade, deep = T["gold"]
    # inside of the back of the crown
    back = poly(epts(100, 50, 30, 7, 180, 360, 30) + [(130, 56), (70, 56)])
    a.p(back, a.lin(100, 42, 100, 56, [(0, T["gold"][3]), (1, "#8A5A0A")]))
    for x in (90, 110):
        a.p(f"M{x - 6},46 L{x},31 L{x + 6},46 Z", T["gold"][3])
        a.p(ell(x, 30.5, 2.6), T["gold"][2])
    # front: band + five points as one piece
    pts = [(70, 50)]
    tips = [(68.5, 30), (84, 27), (100, 22), (116, 27), (131.5, 30)]
    valleys = [(77, 45), (92, 45.5), (108, 45.5), (123, 45)]
    for i, t in enumerate(tips):
        pts.append(t)
        if i < 4:
            pts.append(valleys[i])
    front = (poly(pts, closed=False) + " L130,50 L130,61 " +
             " ".join(f"L{f(x)},{f(y)}" for x, y in epts(100, 61, 30, 7, 0, 180, 24)) + " Z")
    front = front.replace("M70,50 L68.5,30", "M70,61 L70,50 L68.5,30")
    a.mat(front, "gold", (68, 22, 132, 68), rim=2.2, light=1,
          hl=poly(epts(100, 52, 27, 6, 15, 165, 20) + epts(100, 55, 27, 6, 165, 15, 20)), hl_op=0.4)
    # band rim lines
    a.p(poly(epts(100, 50.5, 30.2, 7, 0, 180, 24) + epts(100, 52.2, 30.2, 7, 180, 0, 24)), T["gold"][3], 0.55)
    # balls on the tips
    for x, y in tips:
        a.mat(ell(x, y - 1.6, 3.6), "gold", (x - 4, y - 5, x + 4, y + 2), rim=1.2, light=0.5,
              glint=ell(x + 1.2, y - 2.8, 1.2, 0.9), glint_op=0.85)
    # gems
    a.mat(ell(100, 58.5, 5, 5.6), "berry", (95, 53, 105, 64), rim=1.4, light=0.6,
          glint=ell(101.8, 56.4, 1.6, 1.2), glint_op=0.9)
    for x in (82, 118):
        a.mat(ell(x, 57, 3.4), "sky", (x - 3.5, 53.5, x + 3.5, 60.5), rim=1.1, light=0.5,
              glint=ell(x + 1.1, 55.8, 1.1, 0.8), glint_op=0.9)
    return a


def cowboy():
    a = hat("Cowboy hat", -0.78)
    brim = "M37,50 C52,64 76,67 100,67 C124,67 148,64 163,50 C164,58 158,72 144,78 C130,84 116,85 100,85 C84,85 70,84 56,78 C42,72 36,58 37,50 Z"
    a.mat(brim, "tan", (36, 50, 164, 85), rim=0, light=0,
          grad=a.lin(100, 60, 100, 86, [(0, T["tan"][2]), (0.4, T["tan"][1]), (1, T["tan"][0])]),
          ao=[("M66,60 C80,72 120,72 134,60 L134,78 C120,84 80,84 66,78 Z", 0.0)])
    # brim edge, curling up at the sides
    a.p("M37,50 C36,58 42,72 56,78 C70,84 84,85 100,85 C116,85 130,84 144,78 C158,72 164,58 163,50 "
        "C163.5,60 159,74 145,81 C131,88 116,89 100,89 C84,89 69,88 55,81 C41,74 36.5,60 37,50 Z", T["tan"][3])
    crown = ("M72,70 C70,56 71,40 77,30 C82,22 92,23 100,30 C108,23 118,22 123,30 C129,40 130,56 128,70 "
             "C112,75 88,75 72,70 Z")
    a.begin(clip=a.clip(brim))
    a.p(ell(100, 72, 34, 7), "#000000", 0.18)
    a.end()
    a.mat(crown, "tan", (70, 22, 130, 75), rim=2.8,
          hl="M110,28 C118,26 124,34 126,46 C122,40 116,34 108,33 Z", hl_op=0.4,
          ao=[("M98.6,31 C98,38 98.6,44 99.4,50 L100.6,50 C101.4,44 102,38 101.4,31 Z", 0.22),
              (ell(86, 38, 5, 9), 0.08), (ell(115, 38, 5, 9), 0.06)])
    band = "M71.5,60 C88,65 112,65 128.5,60 L128.3,68 C112,73.5 88,73.5 71.7,68 Z"
    a.mat(band, "cocoa", (71, 60, 129, 74), rim=1.5, light=0.6)
    a.mat(ell(100, 67.6, 4.6, 3.6), "gold", (95, 64, 105, 71), rim=1.0, light=0.5,
          glint=ell(101.6, 66.4, 1.3, 0.9), glint_op=0.9)
    return a


def chef():
    a = hat("Chef hat", -0.84)
    circles = [(76, 40, 13), (89, 29, 15), (106, 26, 15.5), (122, 32, 14), (128, 44, 10), (100, 40, 20)]
    top = union_circles(circles)
    d = poly(top)
    a.mat(d, "white", (60, 11, 140, 60), rim=3, light=1,
          hl=ell(113, 22, 8, 4.5), hl_op=0.7,
          ao=[(ell(88, 50, 7, 12), 0.05), (ell(112, 50, 7, 12), 0.04)])
    band = "M66,47 C80,52 120,52 134,47 L134.5,62 C120,68 80,68 65.5,62 Z"

    def pleats(s):
        for x in (75, 87.5, 100, 112.5, 125):
            u = (x - 100) / 34
            s.p(rrect(x - 1.1, 51 + 3 * (1 - u * u), 2.2, 12.5, 1.1), T["white"][2], 0.9)
    a.mat(band, "white", (65, 47, 135, 68), rim=2.2, pattern=pleats,
          ao=[("M60,45 C80,53 120,53 140,45 L140,50 C120,57 80,57 60,50 Z", 0.08)])
    return a


def witch():
    a = hat("Witch hat", -0.8)
    brim = ell(100, 64, 55, 11)
    a.mat(brim, "plum", (45, 53, 155, 75), rim=0, light=0,
          grad=a.lin(100, 53, 100, 75, [(0, T["plum"][3]), (0.55, T["plum"][2]), (1, T["plum"][1])]))
    a.p(poly(epts(100, 64, 55, 11, 0, 180, 40) + epts(100, 67.4, 54, 11, 180, 0, 40)), T["plum"][3])
    cone = ("M70,62 C75,50 86,38 96,28 C102,22 112,16 138,14.5 C131,19 121,26 115.5,36 "
            "C120,45 127,55 130,62 C112,68 88,68 70,62 Z")
    a.mat(cone, "plum", (70, 14, 138, 68), rim=3,
          hl="M108,22 C120,18 128,16 134,15.6 C126,20 118,26 113,34 C111,30 110,26 108,22 Z", hl_op=0.3,
          ao=[("M96,28 C100,30 106,33 115.5,36 L114,38.5 C106,36 100,33 95,30.6 Z", 0.25)])
    band = "M60,49 C80,56 120,56 140,49 L140,59.5 C120,66.5 80,66.5 60,59.5 Z"
    a.begin(clip=a.clip(cone))
    a.mat(band, "berry", (70, 49, 130, 66), rim=1.6, light=0.7)
    a.end()
    buckle = rrect(93, 52.5, 14, 11, 2.6) + " " + rrect(96.6, 55.8, 6.8, 4.6, 1.2)
    a.p(buckle, a.lin(107, 52, 93, 64, [(0, T["gold"][0]), (0.4, T["gold"][1]), (1, T["gold"][2])]), rule="evenodd")
    a.p(glint(104.5, 54.2, 3, 1.2, 0), "#FFFFFF", 0.8)
    # a star sticker
    a.mat(star(84, 40, 4.6), "gold", (79, 35, 89, 45), rim=1, light=0.5)
    return a


def egg(cx, base_y, tip_y, w, tilt=0, n=40):
    """An ear: an egg, widest a third of the way down from its tip."""
    pts = []
    h = base_y - tip_y
    for i in range(n):
        t = 2 * math.pi * i / n
        yy = -math.cos(t)
        xx = math.sin(t) * (0.6 + 0.4 * (1 - (yy + 1) / 2) ** 0.6) * w / 2
        pts.append((cx + xx, tip_y + h / 2 * (1 + yy)))
    return rot(smooth(pts), tilt, cx, base_y)


def bunny():
    a = hat("Bunny ears", -0.62, data_shadow="0")
    # left ear stands up, the right one bends over at the top
    ears = [
        bez((83, 57), (80, 36), (72, 13)),
        bez((117, 57), (121, 38), (124, 32)) + bez((124, 32), (130, 22), (147, 34))[1:],
    ]
    for spine in ears:
        n = len(spine) - 1
        a.mat(ribbon(spine, taper(n, 10, 21)), "white", (60, 12, 150, 63), rim=2.4, light=0.8)
        inner = spine[3:-2]
        a.mat(ribbon(inner, taper(len(inner) - 1, 3, 8.6)), "pink", (60, 12, 150, 63), rim=1.2, light=0)
    # the fold casts a little shadow on the ear below it
    a.begin(clip=a.clip(ribbon(ears[1], taper(len(ears[1]) - 1, 10, 21))))
    a.p("M110,38 C118,30 128,30 136,38 L136,42 C128,36 118,36 110,44 Z", "#000000", 0.1)
    a.end()
    band = "M45,77 C45,60 66,51 100,51 C134,51 155,60 155,77 L150,77 C150,64 132,57 100,57 C68,57 50,64 50,77 Z"
    a.mat(band, "berry", (45, 51, 155, 77), rim=1.6, light=0.7)
    return a


def catears():
    a = hat("Cat ears", -0.62, data_shadow="0")
    left = smooth([(58, 66), (61, 44), (64, 25), (69, 23.5), (82, 37), (92, 52)])
    for d in (left, mirror(left)):
        a.mat(d, "charcoal", (56, 22, 144, 66), rim=2.2, light=1,
              grad=a.lin(144, 22, 56, 66, [(0, "#5A5D68"), (0.4, "#2A2B30"), (1, "#1C1D21")]))
    inner = smooth([(64, 58), (66, 42), (68, 31), (70.5, 30.5), (79, 41), (85, 52)])
    for d in (inner, mirror(inner)):
        a.mat(d, "pink", (62, 30, 138, 58), rim=1.2, light=0)
    band = "M45,77 C45,60 66,51 100,51 C134,51 155,60 155,77 L150,77 C150,64 132,57 100,57 C68,57 50,64 50,77 Z"
    a.mat(band, "charcoal", (45, 51, 155, 77), rim=1.4, light=0.8)
    return a


def sprout():
    a = hat("Sprout", -0.95)
    hi, base, shade, deep = T["leaf"]
    stem = "M98.2,59.5 C97.6,52 98,45 100,37 L102.8,37.6 C101.2,45 101,52 101.8,59.5 Z"
    a.mat(stem, "leaf", (97, 37, 103, 60), rim=1, light=0.4)
    left = "M99.5,40 C93,30 80,27 69,32 C76,42 89,46 99.5,40 Z"
    right = "M101,38.5 C108,24 124,18.5 137,22.5 C131,36 116,43 101,38.5 Z"
    a.mat(left, "leaf", (69, 27, 100, 45), rim=2, light=0.8)
    a.p("M98,39.6 C90,35 82,33 73,32.6 C82,32 91,34 98.6,38.4 Z", hi, 0.75)
    a.mat(right, "leaf", (101, 18, 137, 43), rim=2.2, light=0.8)
    a.p("M102.6,38 C111,31 121,26 133.5,23.4 C122,24 111,29 101.6,37 Z", hi, 0.75)
    # a dew drop
    drop = "M121,26.5 C123.5,30 125,32 125,34 A4,4 0 0 1 117,34 C117,32 118.5,30 121,26.5 Z"
    a.mat(drop, "sky", (117, 26, 125, 38), rim=1, light=0.4, glint=ell(122.6, 32.6, 1.1, 1.6), glint_op=0.9)
    return a


def gradcap():
    a = hat("Graduation cap", -0.78)
    skull = "M60,66 C60,56 78,50 100,50 C122,50 140,56 140,66 L140,71 C124,78 76,78 60,71 Z"
    a.mat(skull, "charcoal", (60, 50, 140, 78), rim=2,
          grad=a.lin(140, 50, 60, 78, [(0, "#4A4C55"), (0.4, "#2A2B30"), (1, "#1C1D21")]))
    side = "M41,40 L100,57 L159,40 L159,44.5 L100,61.5 L41,44.5 Z"
    a.p(side, a.lin(100, 40, 100, 62, [(0, "#0E0F11"), (1, "#2A2B30")]))
    board = "M100,24 C101,24 157,39 158,39.6 C159,40.2 101,56.6 100,56.6 C99,56.6 41,40.2 42,39.6 C43,39 99,24 100,24 Z"
    a.mat(board, "charcoal", (42, 24, 158, 57), rim=0, light=1,
          grad=a.lin(130, 26, 70, 54, [(0, "#5A5D68"), (0.45, "#34363D"), (1, "#24252A")]),
          hl="M100,27 L148,39.5 L136,42.6 L100,32 Z", hl_op=0.07)
    # tassel cord across the board, then hanging from the corner
    a.p("M100,39.2 C118,39 136,39.6 152,41.2 L151.8,43 C136,41.4 118,40.8 100,41 Z", T["gold"][2])
    a.mat(ell(100, 40, 4.4, 2.8), "gold", (95.6, 37, 104.4, 43), rim=1, light=0.5)
    a.begin(swing=(152, 42), amp=1.0)
    a.p("M151,42 L153,42 L153.2,61 L150.8,61 Z", T["gold"][2])
    tassel = "M149.2,60 L154.8,60 C156.5,66 158,72 158,76 C155,77.6 149,77.6 146,76 C146,72 147.5,66 149.2,60 Z"

    def strands(s):
        for x in (148.6, 151.2, 153.6, 156):
            s.p(rrect(x - 0.5, 64, 1, 13, 0.5), T["gold"][3], 0.45)
    a.mat(tassel, "gold", (146, 60, 158, 78), rim=1.4, light=0.6, pattern=strands)
    a.mat(rrect(148.4, 58, 7.2, 4.4, 2), "gold", (148, 58, 156, 63), rim=1, light=0.5)
    a.end()
    return a


def strawhat():
    a = hat("Straw hat", -0.74)
    brim = ell(100, 69, 64, 15)

    def rings(s):
        for k in range(5):
            rx, ry = 38 + k * 6, 9 + k * 1.4
            s.p(poly(epts(100, 69, rx, ry, 0, 360, 60) + epts(100, 69, rx - 1.1, ry - 0.5, 360, 0, 60)),
                T["straw"][3], 0.3, )
    a.mat(brim, "straw", (36, 54, 164, 84), rim=0, light=0,
          grad=a.lin(100, 54, 100, 84, [(0, T["straw"][2]), (0.5, T["straw"][1]), (1, T["straw"][0])]),
          pattern=rings)
    a.p(poly(epts(100, 69, 64, 15, 0, 180, 40) + epts(100, 72, 63, 15, 180, 0, 40)), T["straw"][3])
    crown = "M70,68 C69,46 82,35 100,35 C118,35 131,46 130,68 C116,73 84,73 70,68 Z"
    a.begin(clip=a.clip(brim))
    a.p("M64,64 C80,78 120,78 136,64 L136,72 C120,84 80,84 64,72 Z", "#000000", 0.2)
    a.end()

    def weave(s):
        for y in range(40, 70, 4):
            s.p(f"M60,{y} C80,{y + 4} 120,{y + 4} 140,{y} L140,{y + 1.1} C120,{y + 5.1} 80,{y + 5.1} 60,{y + 1.1} Z",
                T["straw"][3], 0.28)
    a.mat(crown, "straw", (69, 35, 131, 73), rim=2.6, pattern=weave,
          hl="M108,38 C120,40 127,48 128,58 C123,50 116,44 106,42 Z", hl_op=0.4)
    band = "M70,58 C86,63.5 114,63.5 130,58 L130.2,66.6 C114,72.4 86,72.4 69.8,66.6 Z"
    a.mat(band, "berry", (69, 58, 131, 73), rim=1.6, light=0.7)
    # bow on the side
    loop_l = "M124,65 C116,58 112,62 113,67 C114,72 120,71 124,66.5 Z"
    loop_r = "M126,65 C132,56 140,58 139.5,64 C139,70 132,70.5 126,66.5 Z"
    a.mat(loop_l, "berry", (112, 58, 125, 72), rim=1.4, light=0.5)
    a.mat(loop_r, "berry", (126, 57, 140, 71), rim=1.4, light=0.5)
    a.p("M123,68 L119,80 L122.5,78.6 L124.6,81.4 L126,68.5 Z", T["berry"][2])
    a.mat(ell(125, 65.8, 3.4, 3.2), "berry", (121.6, 62.6, 128.4, 69), rim=1, light=0.4)
    return a


ITEMS = {
    "beanie": beanie, "tophat": tophat, "partyhat": partyhat, "crown": crown,
    "cowboy": cowboy, "chef": chef, "witch": witch, "bunny": bunny, "catears": catears,
    "sprout": sprout, "gradcap": gradcap, "strawhat": strawhat,
}
