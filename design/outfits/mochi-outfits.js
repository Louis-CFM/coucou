// Mochi outfit reference renderer (Canvas 2D).
// Coordinates mirror BotEngine.draw(): origin at body centre, y down on screen,
// R = W*0.3, rx = 1.14R, ry = 0.88R. Head "3D" model: superellipsoid whose
// horizontal radius at height y (y up, -1..1) is r(y) = (1-|y|^2.7)^(1/2.7),
// so that its silhouette matches mochiPath at yaw = pitch = 0.

const EXP = 2.7;
// Accessories are seen slightly from above (and hats sit tipped forward): rings show as ellipses.
const VIEW_TILT = -0.30;
const ACC_PITCH = 0.4;
const EYE_W = 0.25, EYE_H = 0.27, EYE_SP = 0.37, EYE_P = -0.12;

function ringR(y) { const a = Math.min(1, Math.abs(y)); return Math.pow(1 - Math.pow(a, EXP), 1 / EXP); }

// rotate a head-local point (x right, y up, z toward viewer) by yaw then pitch
function rot(p, yaw, pitch) {
  let [x, y, z] = p;
  const cy = Math.cos(yaw), sy = Math.sin(yaw);
  let x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
  const cp = Math.cos(pitch), sp = Math.sin(pitch);
  let y2 = y * cp + z1 * sp, z2 = -y * sp + z1 * cp;
  return [x1, y2, z2];
}
// head-local -> screen (body space). returns {x, y, z}
function proj(H, p) {
  // accessories follow the head pitch only partly, so hats never flip to a top-down view
  const r = rot(p, H.yaw, (H.view || 0) + H.pitch * ACC_PITCH);
  return { x: r[0] * H.rx, y: -r[1] * H.ry, z: r[2] };
}
// point on the head surface at height y, longitude lon (0 = facing viewer), scaled by s
function surf(y, lon, s = 1) { const r = ringR(y) * s; return [r * Math.sin(lon), y, r * Math.cos(lon)]; }

function mochiPath(rx, ry) {
  const p = new Path2D(); const n = 96, e = 2 / EXP;
  for (let i = 0; i <= n; i++) {
    const a = i / n * Math.PI * 2, ca = Math.cos(a), sa = Math.sin(a);
    const x = rx * Math.sign(ca) * Math.pow(Math.abs(ca), e);
    const y = ry * Math.sign(sa) * Math.pow(Math.abs(sa), e);
    i ? p.lineTo(x, y) : p.moveTo(x, y);
  }
  p.closePath(); return p;
}

function lin(ctx, x0, y0, x1, y1, stops) {
  const g = ctx.createLinearGradient(x0, y0, x1, y1);
  stops.forEach(([o, c]) => g.addColorStop(o, c)); return g;
}
function rad(ctx, x, y, r0, r1, stops) {
  const g = ctx.createRadialGradient(x, y, r0, x, y, r1);
  stops.forEach(([o, c]) => g.addColorStop(o, c)); return g;
}

// ---------- Body + eyes (faithful to BotEngine) ----------
function drawBody(ctx, H, colors) {
  const { rx, ry, R } = H; const path = mochiPath(rx, ry);
  const top = colors ? colors[0] : '#EDEDEF', bot = colors ? colors[1] : '#C4C5CA';
  ctx.fillStyle = lin(ctx, rx * 0.7, -ry * 0.85, -rx * 0.8, ry * 0.9, [[0, top], [1, bot]]);
  ctx.fill(path);
  ctx.fillStyle = rad(ctx, 0, 0, R * 0.15, R * 1.25, [[0, 'rgba(0,0,0,0)'], [0.6, 'rgba(0,0,0,0)'], [1, 'rgba(0,0,0,0.2)']]);
  ctx.fill(path);
  ctx.fillStyle = rad(ctx, rx * 0.34, -ry * 0.46, 0, R * 0.42, [[0, 'rgba(255,255,255,0.55)'], [1, 'rgba(255,255,255,0)']]);
  ctx.fill(path);
  return path;
}

// Same formula as drawEyes(): spherical addition, NOT the rotation used for accessories.
function eyeFrames(H) {
  const out = [];
  for (const sd of [-1, 1]) {
    const eyeYaw = sd * EYE_SP + H.yaw;
    let eyePitch = EYE_P + H.pitch;
    const cp = Math.cos(eyePitch);
    const visible = Math.cos(eyeYaw) * cp > 0.04;
    out.push({
      sd, visible,
      x: Math.sin(eyeYaw) * cp * H.rx,
      y: -Math.sin(eyePitch) * H.ry,
      fx: Math.max(0.18, Math.cos(eyeYaw)),
      fy: Math.max(0.18, cp),
      w: H.R * EYE_W, h: H.R * EYE_H,
    });
  }
  return out;
}
function drawEyes(ctx, H, path, alpha = 1) {
  ctx.save(); ctx.clip(path);
  for (const e of eyeFrames(H)) {
    if (!e.visible) continue;
    ctx.save(); ctx.translate(e.x, e.y); ctx.scale(e.fx, e.fy);
    const w = e.w, hh = e.h;
    ctx.fillStyle = `rgba(26,20,18,${alpha})`;
    roundRect(ctx, -w / 2, -hh / 2, w, hh, Math.min(w, hh) / 2); ctx.fill();
    ctx.restore();
  }
  ctx.restore();
}
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}

// ---------- helpers for "wrapped" items ----------
// Front arc of a ring (height y, scale s) projected, from left extreme to right extreme (z >= 0 side).
function ringPoints(H, y, s, n = 72) {
  const pts = [];
  for (let i = 0; i <= n; i++) { const lon = -Math.PI + i / n * 2 * Math.PI; pts.push({ lon, ...proj(H, surf(y, lon, s)) }); }
  return pts;
}
function frontArc(H, y, s) {
  // walk the ring, keep the contiguous z>=0 part ordered by screen x
  const pts = ringPoints(H, y, s, 120).filter(p => p.z >= -0.02);
  pts.sort((a, b) => a.x - b.x); return pts;
}
// region of the inflated head ABOVE the front arc of ring y (the part a cap covers)
function capClip(H, y, s, extraTop = 3) {
  const arc = frontArc(H, y, s);
  const p = new Path2D();
  p.moveTo(arc[0].x - H.rx, arc[0].y);
  for (const q of arc) p.lineTo(q.x, q.y);
  p.lineTo(arc[arc.length - 1].x + H.rx, arc[arc.length - 1].y);
  p.lineTo(H.rx * 2, -H.ry * extraTop); p.lineTo(-H.rx * 2, -H.ry * extraTop); p.closePath();
  return p;
}
// contiguous visible (z>=0) run of a closed ring, ordered left->right
function frontRun(ring) {
  const n = ring.length - 1; let start = -1;
  for (let i = 0; i < n; i++) if (ring[i].z >= 0 && ring[(i - 1 + n) % n].z < 0) { start = i; break; }
  if (start < 0) { // whole ring visible (seen from above): use its lower half
    const my = ring.reduce((s, q) => s + q.y, 0) / ring.length;
    return ring.filter(q => q.y >= my).sort((a, b) => a.x - b.x);
  }
  const out = []; for (let k = 0; k < n; k++) { const q = ring[(start + k) % n]; if (q.z < 0) break; out.push(q); }
  if (out.length > 1 && out[0].x > out[out.length - 1].x) out.reverse();
  return out;
}
function strokeArc(ctx, arc) { ctx.beginPath(); arc.forEach((q, i) => i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y)); }

// soft round "pompom" made of overlapping puffs
function pompom(ctx, x, y, r, base = '#FFFFFF', shade = '#D5D9E2') {
  ctx.save(); ctx.translate(x, y);
  // fluffy rim bumps
  const n = 11;
  for (let i = 0; i < n; i++) {
    const a = i / n * Math.PI * 2, br = r * (0.34 + 0.06 * Math.sin(i * 2.3));
    const bx = Math.cos(a) * r * 0.78, by = Math.sin(a) * r * 0.78;
    ctx.fillStyle = rad(ctx, bx - br * 0.4, by - br * 0.5, 0, br * 1.3, [[0, base], [1, shade]]);
    ctx.beginPath(); ctx.arc(bx, by, br, 0, Math.PI * 2); ctx.fill();
  }
  ctx.fillStyle = rad(ctx, -r * 0.3, -r * 0.35, 0, r * 1.05, [[0, base], [0.7, base], [1, shade]]);
  ctx.beginPath(); ctx.arc(0, 0, r * 0.86, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}
// fuzzy band along a polyline (santa trim)
function fuzzyBand(ctx, arc, thick, base = '#FFFFFF', shade = '#DADDE4') {
  ctx.save();
  ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  strokeArc(ctx, arc); ctx.strokeStyle = shade; ctx.lineWidth = thick; ctx.stroke();
  strokeArc(ctx, arc); ctx.strokeStyle = base; ctx.lineWidth = thick * 0.78; ctx.stroke();
  // bumps along the edges
  const step = Math.max(2, Math.floor(arc.length / 16));
  for (let i = 0; i < arc.length; i += step) {
    const q = arc[i]; const r = thick * (0.32 + 0.1 * Math.sin(i * 1.7));
    ctx.fillStyle = rad(ctx, q.x - r * 0.3, q.y - thick * 0.35 - r * 0.3, 0, r * 1.2, [[0, base], [1, shade]]);
    ctx.beginPath(); ctx.arc(q.x, q.y - thick * 0.32, r, 0, Math.PI * 2); ctx.fill();
  }
  ctx.restore();
}
// quadratic bezier helpers for tubes
function qb(p0, p1, p2, t) { const u = 1 - t; return { x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x, y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y }; }
function qbd(p0, p1, p2, t) { const u = 1 - t; return { x: 2 * u * (p1.x - p0.x) + 2 * t * (p2.x - p1.x), y: 2 * u * (p1.y - p0.y) + 2 * t * (p2.y - p1.y) }; }

// ---------- OUTFITS ----------
// Each outfit has optional back(ctx,H) (before body) and front(ctx,H,path) (after body+eyes).
// H.phys = {dx, dy}: spring lag of floppy parts in head units (driven by yaw velocity + gravity in Swift).

const OUTFITS = {};

// --- Beanie: knitted cap that wraps the top of the head, ribbed cuff, bouncy pompom
OUTFITS.beanie = {
  front(ctx, H, path) {
    const s = 1.035, yEdge = 0.42, yCuff = 0.58;
    const head = mochiPath(H.rx * s, H.ry * s);
    // shadow on the head under the cuff
    ctx.save(); ctx.clip(path); ctx.clip(capClip(H, yEdge - 0.12, 1));
    ctx.fillStyle = 'rgba(30,40,70,0.10)'; ctx.fill(path); ctx.restore();
    // knit body
    ctx.save(); ctx.clip(capClip(H, yCuff, s));
    ctx.fillStyle = lin(ctx, H.rx * 0.5, -H.ry * 1.1, -H.rx * 0.6, H.ry * 0.2, [[0, '#7DB6FF'], [1, '#2F6FE0']]);
    ctx.fill(head);
    // vertical knit ribs following meridians
    ctx.clip(head);
    for (let k = -6; k <= 6; k++) {
      const lon = k * 0.24; const pts = [];
      for (let i = 0; i <= 16; i++) { const y = yCuff + (1.05 - yCuff) * i / 16; const q = proj(H, surf(y, lon, s)); if (q.z > 0) pts.push(q); }
      if (pts.length < 2) continue;
      ctx.beginPath(); pts.forEach((q, i) => i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y));
      ctx.strokeStyle = 'rgba(20,50,140,0.16)'; ctx.lineWidth = H.R * 0.045; ctx.stroke();
    }
    ctx.restore();
    // cuff (folded band)
    ctx.save(); ctx.clip(capClip(H, yEdge, s * 1.04)); ctx.clip(invert(capClip(H, yCuff, s * 1.04), H));
    const cuffHead = mochiPath(H.rx * s * 1.04, H.ry * s * 1.04);
    ctx.fillStyle = lin(ctx, 0, -H.ry * 0.6, 0, -H.ry * 0.2, [[0, '#3C7BEA'], [1, '#2257C4']]);
    ctx.fill(cuffHead);
    ctx.clip(cuffHead);
    for (let k = -14; k <= 14; k++) {
      const lon = k * 0.115; const a = proj(H, surf(yEdge, lon, s * 1.04)), b = proj(H, surf(yCuff, lon, s * 1.04));
      if (a.z < 0) continue;
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.strokeStyle = 'rgba(10,30,100,0.22)'; ctx.lineWidth = H.R * 0.035; ctx.stroke();
    }
    ctx.restore();
    // top highlight
    ctx.save(); ctx.clip(capClip(H, yCuff, s)); ctx.clip(head);
    ctx.fillStyle = rad(ctx, H.rx * 0.3, -H.ry * 0.85, 0, H.R * 0.45, [[0, 'rgba(255,255,255,0.35)'], [1, 'rgba(255,255,255,0)']]);
    ctx.fill(head); ctx.restore();
    // pompom on a short spring
    const top = proj(H, [0, 1.08 * s, 0]);
    pompom(ctx, top.x + H.phys.dx * H.rx * 0.25, top.y - H.R * 0.12 + H.phys.dy * H.ry * 0.15, H.R * 0.24);
  }
};

// region complement helper (big rect minus path) using evenodd
function invert(p, H) {
  const q = new Path2D(); q.rect(-H.rx * 4, -H.ry * 4, H.rx * 8, H.ry * 8); q.addPath(p); q.__evenodd = true; return q;
}
// patch ctx.clip to honour evenodd paths
const _clip = CanvasRenderingContext2D.prototype.clip;
CanvasRenderingContext2D.prototype.clip = function (p, rule) { if (p && p.__evenodd) return _clip.call(this, p, 'evenodd'); return p ? _clip.call(this, p, rule) : _clip.call(this); };

// --- Santa hat: soft red bag that flops to the side, fuzzy trim, pompom at the tip
OUTFITS.santaHat = {
  front(ctx, H, path) {
    const s = 1.05, yEdge = 0.52;
    const arc = frontArc(H, yEdge, s);
    const L = arc[0], Rt = arc[arc.length - 1];
    const crown = proj(H, [0, 1.05, 0]);
    // tip: flops to the right and down, plus spring lag
    const side = 1;
    const tip = { x: crown.x + side * H.rx * (0.95 + H.phys.dx * 0.35), y: crown.y + H.ry * (0.05 + H.phys.dy * 0.2) };
    const peak = { x: crown.x + side * H.rx * 0.25, y: crown.y - H.ry * 0.62 };
    const bag = new Path2D();
    bag.moveTo(L.x, L.y);
    bag.bezierCurveTo(L.x - H.rx * 0.05, L.y - H.ry * 0.7, peak.x - H.rx * 0.55, peak.y - H.ry * 0.05, peak.x, peak.y);
    bag.quadraticCurveTo(tip.x - H.rx * 0.05, peak.y - H.ry * 0.02, tip.x, tip.y);
    bag.quadraticCurveTo(tip.x - H.rx * 0.12, tip.y - H.ry * 0.22, peak.x + H.rx * 0.18, peak.y + H.ry * 0.32);
    bag.bezierCurveTo(Rt.x + H.rx * 0.05, peak.y + H.ry * 0.45, Rt.x + H.rx * 0.08, Rt.y - H.ry * 0.35, Rt.x, Rt.y);
    for (let i = arc.length - 1; i >= 0; i--) bag.lineTo(arc[i].x, arc[i].y);
    bag.closePath();
    // shadow on head
    ctx.save(); ctx.clip(path); ctx.clip(capClip(H, yEdge - 0.14, 1)); ctx.fillStyle = 'rgba(120,10,10,0.10)'; ctx.fill(path); ctx.restore();
    ctx.fillStyle = lin(ctx, -H.rx * 0.6, -H.ry * 1.6, H.rx * 0.7, -H.ry * 0.3, [[0, '#FF6B6B'], [0.55, '#E53935'], [1, '#B71C1C']]);
    ctx.fill(bag);
    // folds: soft darker creases following the flop
    ctx.save(); ctx.clip(bag);
    ctx.lineCap = 'round';
    for (const [a, b, w] of [[0.15, 0.55, 0.10], [0.45, 0.85, 0.08]]) {
      ctx.beginPath();
      ctx.moveTo(peak.x - H.rx * 0.1 + (Rt.x - L.x) * a * 0.3, peak.y + H.ry * 0.15);
      ctx.quadraticCurveTo(peak.x + H.rx * 0.35, peak.y + H.ry * (0.05 + a * 0.3), tip.x - H.rx * (0.45 - b * 0.3), tip.y - H.ry * 0.12);
      ctx.strokeStyle = 'rgba(90,0,0,0.20)'; ctx.lineWidth = H.R * w; ctx.stroke();
    }
    ctx.fillStyle = rad(ctx, peak.x - H.rx * 0.25, peak.y + H.ry * 0.05, 0, H.R * 0.5, [[0, 'rgba(255,255,255,0.32)'], [1, 'rgba(255,255,255,0)']]);
    ctx.fill(bag);
    ctx.restore();
    // trim + pompom
    fuzzyBand(ctx, arc, H.R * 0.3);
    pompom(ctx, tip.x, tip.y + H.R * 0.04, H.R * 0.22);
  }
};

// --- Party hat: chubby cone with rounded tip, polka dots, pompom; sits tilted on the crown
OUTFITS.partyHat = {
  front(ctx, H, path) {
    const baseY = 0.82, baseR = 0.42, lean = -0.24 + H.phys.dx * 0.12;
    // base ring on the head (front arc), apex above, leaning
    const c = proj(H, [0.16, baseY + 0.06, 0]);
    const ring = []; for (let i = 0; i <= 48; i++) { const a = i / 48 * Math.PI * 2; ring.push(proj(H, [0.16 + baseR * Math.sin(a), baseY + 0.06, baseR * Math.cos(a)])); }
    let left = ring.reduce((m, q) => q.x < m.x ? q : m), right = ring.reduce((m, q) => q.x > m.x ? q : m);
    const h = H.ry * 1.6;
    const apex = { x: c.x + Math.sin(lean) * h, y: c.y - Math.cos(lean) * h };
    const front = frontRun(ring);
    const cone = new Path2D();
    cone.moveTo(left.x, left.y);
    cone.quadraticCurveTo((left.x + apex.x) / 2 - H.rx * 0.06, (left.y + apex.y) / 2, apex.x - H.R * 0.05, apex.y + H.R * 0.06);
    cone.quadraticCurveTo(apex.x, apex.y - H.R * 0.03, apex.x + H.R * 0.05, apex.y + H.R * 0.06);
    cone.quadraticCurveTo((right.x + apex.x) / 2 + H.rx * 0.06, (right.y + apex.y) / 2, right.x, right.y);
    for (let i = front.length - 1; i >= 0; i--) cone.lineTo(front[i].x, front[i].y);
    cone.closePath();
        ctx.fillStyle = lin(ctx, left.x, apex.y, right.x, left.y, [[0, '#FF9BD0'], [0.5, '#F15BAE'], [1, '#C2187A']]);
    ctx.fill(cone);
    ctx.save(); ctx.clip(cone);
    // polka dots placed along the cone
    const dots = [[0.25, -0.35], [0.3, 0.3], [0.55, -0.05], [0.72, 0.28], [0.8, -0.3], [0.45, 0.6], [0.48, -0.65]];
    for (const [t, u] of dots) {
      const bx = left.x + (right.x - left.x) * (0.5 + u * 0.5);
      const by = left.y + (right.y - left.y) * (0.5 + u * 0.5);
      const x = bx + (apex.x - bx) * (1 - t) * 0.0 + (apex.x - bx) * (1 - t);
      const y = by + (apex.y - by) * (1 - t);
      const r = H.R * 0.075 * (0.6 + t * 0.5);
      ctx.beginPath(); ctx.ellipse(x, y, r, r * 0.9, 0, 0, Math.PI * 2); ctx.fillStyle = 'rgba(255,255,255,0.92)'; ctx.fill();
    }
    ctx.fillStyle = lin(ctx, left.x, 0, right.x, 0, [[0, 'rgba(255,255,255,0.28)'], [0.35, 'rgba(255,255,255,0)'], [1, 'rgba(80,0,40,0.18)']]);
    ctx.fill(cone);
    ctx.restore();
    // rim at the base
    ctx.beginPath(); front.forEach((q, i) => i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y));
    ctx.strokeStyle = '#FFD84D'; ctx.lineWidth = H.R * 0.07; ctx.lineCap = 'round'; ctx.stroke();
    pompom(ctx, apex.x, apex.y - H.R * 0.04, H.R * 0.16, '#FFE27A', '#F2B705');
  }
};

// --- Crown: golden band AROUND the head, spikes all around (back ones behind the head)
function crownGeom(H) {
  const s = 1.06, yb = 0.46, yt = 0.66, n = 8;
  return { s, yb, yt, n, spikeH: 0.42 };
}
function crownPart(ctx, H, side) { // side: -1 back half, +1 front half
  const { s, yb, yt, n, spikeH } = crownGeom(H);
  const N = 120; const seg = [];
  for (let i = 0; i <= N; i++) {
    const lon = -Math.PI + i / N * 2 * Math.PI;
    const b = proj(H, surf(yb, lon, s)), t = proj(H, surf(yt, lon, s));
    const phase = ((lon + Math.PI) / (2 * Math.PI)) * n; const f = phase - Math.floor(phase);
    const spike = Math.pow(Math.max(0, 1 - Math.abs(f - 0.5) * 2), 1.6); // 0..1 peak at middle
    const topY = yt + spikeH * spike;
    const tt = proj(H, [surf(yt, lon, s)[0] * (1 - 0.08 * spike), topY, surf(yt, lon, s)[2] * (1 - 0.08 * spike)]);
    seg.push({ lon, b, t, tt, z: b.z, spike });
  }
  const keep = seg.filter(q => side > 0 ? q.z >= 0 : q.z < 0.02);
  if (keep.length < 2) return;
  keep.sort((a, b) => a.b.x - b.b.x);
  const shape = new Path2D();
  keep.forEach((q, i) => i ? shape.lineTo(q.tt.x, q.tt.y) : shape.moveTo(q.tt.x, q.tt.y));
  for (let i = keep.length - 1; i >= 0; i--) shape.lineTo(keep[i].b.x, keep[i].b.y);
  shape.closePath();
  const dark = side < 0;
  ctx.fillStyle = lin(ctx, 0, -H.ry * 1.05, 0, -H.ry * 0.45, dark ? [[0, '#C98A12'], [1, '#8A5A06']] : [[0, '#FFE58A'], [0.5, '#FBBF24'], [1, '#D08A0B']]);
  ctx.fill(shape);
  if (!dark) {
    // band highlight + gems + ball tips on front spikes
    ctx.save(); ctx.clip(shape);
    ctx.fillStyle = lin(ctx, -H.rx, 0, H.rx, 0, [[0, 'rgba(120,70,0,0.25)'], [0.45, 'rgba(255,255,255,0.0)'], [0.62, 'rgba(255,255,255,0.35)'], [1, 'rgba(120,70,0,0.25)']]);
    ctx.fill(shape); ctx.restore();
    const gems = ['#EF4444', '#3B82F6', '#22C55E', '#A855F7'];
    for (let k = 0; k < n; k++) {
      const lon = -Math.PI + (k + 0.5) / n * 2 * Math.PI;
      const sp = surf(yt, lon, s);
      const tipP = proj(H, [sp[0] * 0.92, yt + spikeH, sp[2] * 0.92]);
      const mid = proj(H, surf((yb + yt) / 2, lon, s * 1.01));
      if (mid.z <= 0.12) continue;
      const r = H.R * 0.055;
      ctx.beginPath(); ctx.arc(tipP.x, tipP.y - r * 0.5, r, 0, Math.PI * 2);
      ctx.fillStyle = rad(ctx, tipP.x - r * 0.3, tipP.y - r, 0, r * 1.2, [[0, '#FFF6CC'], [1, '#E0A21A']]); ctx.fill();
      const gr = H.R * 0.075;
      ctx.beginPath(); ctx.ellipse(mid.x, mid.y, gr * Math.max(0.35, mid.z), gr, 0, 0, Math.PI * 2);
      ctx.fillStyle = gems[k % gems.length]; ctx.fill();
      ctx.beginPath(); ctx.arc(mid.x - gr * 0.25 * mid.z, mid.y - gr * 0.35, gr * 0.28, 0, Math.PI * 2); ctx.fillStyle = 'rgba(255,255,255,0.75)'; ctx.fill();
    }
  }
}
OUTFITS.crown = {
  back(ctx, H) { crownPart(ctx, H, -1); },
  front(ctx, H, path) {
    ctx.save(); ctx.clip(path); ctx.clip(capClip(H, crownGeom(H).yb - 0.1, 1)); ctx.clip(invert(capClip(H, crownGeom(H).yb, 1), H));
    ctx.fillStyle = 'rgba(80,50,0,0.12)'; ctx.fill(path); ctx.restore();
    crownPart(ctx, H, 1);
  }
};

// --- Witch hat: wide floppy brim around the head, tall cone with a bent tip, orange band + gold buckle
function witchBrimPts(H) {
  const y = 0.70, rr = 1.42, pts = [];
  for (let i = 0; i <= 120; i++) {
    const a = -Math.PI + i / 120 * 2 * Math.PI;
    const wob = 1 + 0.035 * Math.sin(a * 3 + 0.6);
    const droop = -0.10 * Math.pow(Math.abs(Math.sin(a)), 2); // brim edges droop a little
    pts.push({ a, ...proj(H, [rr * wob * Math.sin(a), y + droop, rr * wob * Math.cos(a)]) });
  }
  return pts;
}
OUTFITS.witchHat = {
  back(ctx, H) {
    const pts = witchBrimPts(H).filter(p => p.z < 0.05).sort((a, b) => a.x - b.x);
    const ell = new Path2D(); witchBrimPts(H).forEach((q, i) => i ? ell.lineTo(q.x, q.y) : ell.moveTo(q.x, q.y)); ell.closePath();
    ctx.fillStyle = lin(ctx, 0, -H.ry * 1.0, 0, -H.ry * 0.4, [[0, '#2A0A4F'], [1, '#3B0F6B']]);
    ctx.fill(ell); // whole brim behind the head; front part is redrawn in front()
  },
  front(ctx, H, path) {
    const all = witchBrimPts(H);
    const brim = new Path2D(); all.forEach((q, i) => i ? brim.lineTo(q.x, q.y) : brim.moveTo(q.x, q.y)); brim.closePath();
    const fr = all.filter(p => p.z >= 0).sort((a, b) => a.x - b.x);
    // shadow of brim on head
    ctx.save(); ctx.clip(path); ctx.clip(capClip(H, 0.50, 1)); ctx.fillStyle = 'rgba(40,0,70,0.10)'; ctx.fill(path); ctx.restore();
    ctx.fillStyle = lin(ctx, 0, -H.ry * 0.9, 0, -H.ry * 0.3, [[0, '#5B21B6'], [1, '#3B0764']]);
    ctx.fill(brim);
    ctx.beginPath(); fr.forEach((q, i) => i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y));
    ctx.strokeStyle = 'rgba(190,150,255,0.35)'; ctx.lineWidth = H.R * 0.035; ctx.stroke();
    // cone: base ring r=0.62 at y=0.72, apex high, tip bends over
    const baseR = 0.62, by = 0.74;
    const bl = proj(H, [-baseR, by, 0]), br = proj(H, [baseR, by, 0]);
    const c = proj(H, [0, by, 0]);
    const lean = 0.10 + H.phys.dx * 0.15;
    const top = { x: c.x + H.rx * 0.18 + Math.sin(lean) * H.ry * 0.3, y: c.y - H.ry * 1.25 };
    const tip = { x: top.x + H.rx * (0.45 + H.phys.dx * 0.25), y: top.y + H.ry * (0.22 + H.phys.dy * 0.1) };
    const cone = new Path2D();
    cone.moveTo(bl.x, bl.y);
    cone.bezierCurveTo(bl.x + H.rx * 0.12, bl.y - H.ry * 0.5, top.x - H.rx * 0.28, top.y + H.ry * 0.25, top.x - H.rx * 0.02, top.y - H.ry * 0.02);
    cone.quadraticCurveTo(top.x + H.rx * 0.25, top.y - H.ry * 0.08, tip.x, tip.y);
    cone.quadraticCurveTo(top.x + H.rx * 0.22, top.y + H.ry * 0.08, top.x + H.rx * 0.14, top.y + H.ry * 0.22);
    cone.bezierCurveTo(br.x - H.rx * 0.18, c.y - H.ry * 0.45, br.x - H.rx * 0.02, br.y - H.ry * 0.2, br.x, br.y);
    const capFront = frontArc(H, by, baseR / ringR(by)).filter(q => q.x >= bl.x - 1 && q.x <= br.x + 1);
    for (let i = capFront.length - 1; i >= 0; i--) cone.lineTo(capFront[i].x, capFront[i].y + H.ry * 0.0);
    cone.closePath();
    ctx.fillStyle = lin(ctx, bl.x, top.y, br.x, bl.y, [[0, '#7C3AED'], [0.55, '#4C1D95'], [1, '#2E1065']]);
    ctx.fill(cone);
    ctx.save(); ctx.clip(cone);
    ctx.fillStyle = lin(ctx, bl.x, 0, br.x, 0, [[0, 'rgba(255,255,255,0.22)'], [0.4, 'rgba(255,255,255,0)'], [1, 'rgba(0,0,0,0.15)']]);
    ctx.fill(cone);
    // crease where the tip bends
    ctx.beginPath(); ctx.moveTo(top.x - H.rx * 0.05, top.y + H.ry * 0.05); ctx.quadraticCurveTo(top.x + H.rx * 0.1, top.y + H.ry * 0.12, top.x + H.rx * 0.2, top.y + H.ry * 0.06);
    ctx.strokeStyle = 'rgba(20,0,40,0.35)'; ctx.lineWidth = H.R * 0.05; ctx.lineCap = 'round'; ctx.stroke();
    // orange band: gentle curve across the cone just above its base
    const fc = proj(H, [0, by, baseR]);
    const lift = H.ry * 0.11;
    ctx.beginPath();
    ctx.moveTo(bl.x - 2, bl.y - lift);
    ctx.quadraticCurveTo(fc.x, 2 * (fc.y - lift) - (bl.y + br.y) / 2 + lift * 0.0, br.x + 2, br.y - lift);
    ctx.strokeStyle = '#F97316'; ctx.lineWidth = H.ry * 0.17; ctx.lineCap = 'butt'; ctx.stroke();
    ctx.restore();
    // buckle
    const bk0 = proj(H, [0, by, baseR]); const bk = { x: bk0.x, y: bk0.y - H.ry * 0.11 };
    const bw = H.R * 0.2, bh = H.R * 0.16;
    ctx.save(); ctx.translate(bk.x, bk.y - H.ry * 0.0);
    roundRect(ctx, -bw / 2, -bh / 2, bw, bh, bh * 0.25); ctx.fillStyle = '#FCD34D'; ctx.fill();
    roundRect(ctx, -bw / 2 + bw * 0.24, -bh / 2 + bh * 0.28, bw * 0.52, bh * 0.44, bh * 0.1); ctx.fillStyle = '#C2410C'; ctx.fill();
    ctx.restore();
  }
};

// --- Glasses pinned to the real eye positions
function lens(ctx, e, w, h, r) { ctx.save(); ctx.translate(e.x, e.y); ctx.scale(e.fx, e.fy); roundRect(ctx, -w / 2, -h / 2, w, h, r); ctx.restore(); }
OUTFITS.sunglasses = {
  frontAfterEyes: true,
  front(ctx, H, path) {
    const eyes = eyeFrames(H);
    const w = H.R * 0.62, h = H.R * 0.46;
    ctx.save(); ctx.clip(path);
    // bridge
    const [l, r] = eyes;
    if (l.visible && r.visible) {
      ctx.beginPath(); ctx.moveTo(l.x + w / 2 * l.fx * 0.9, l.y - h * 0.18); ctx.quadraticCurveTo((l.x + r.x) / 2, (l.y + r.y) / 2 - h * 0.42, r.x - w / 2 * r.fx * 0.9, r.y - h * 0.18);
      ctx.strokeStyle = '#111317'; ctx.lineWidth = H.R * 0.07; ctx.stroke();
    }
    // temples to the head edge
    for (const e of eyes) {
      if (!e.visible) continue;
      const ox = e.x + e.sd * w / 2 * e.fx;
      ctx.beginPath(); ctx.moveTo(ox, e.y - h * 0.2); ctx.lineTo(e.sd * H.rx * 1.05, e.y - h * 0.35);
      ctx.strokeStyle = '#111317'; ctx.lineWidth = H.R * 0.06; ctx.stroke();
    }
    for (const e of eyes) {
      if (!e.visible) continue;
      lens(ctx, e, w, h, h * 0.42); ctx.fillStyle = 'rgba(17,19,23,0.82)'; ctx.fill();
      ctx.lineWidth = H.R * 0.05; ctx.strokeStyle = '#0B0C0F'; ctx.stroke();
      ctx.save(); ctx.translate(e.x, e.y); ctx.scale(e.fx, e.fy);
      ctx.beginPath(); ctx.moveTo(-w * 0.28, -h * 0.05); ctx.lineTo(-w * 0.05, -h * 0.3);
      ctx.strokeStyle = 'rgba(255,255,255,0.45)'; ctx.lineWidth = H.R * 0.05; ctx.lineCap = 'round'; ctx.stroke();
      ctx.restore();
    }
    ctx.restore();
  }
};
OUTFITS.roundGlasses = {
  front(ctx, H, path) {
    const eyes = eyeFrames(H); const d = H.R * 0.56;
    ctx.save(); ctx.clip(path);
    const [l, r] = eyes;
    if (l.visible && r.visible) {
      ctx.beginPath(); ctx.moveTo(l.x + d / 2 * l.fx, l.y - d * 0.08); ctx.quadraticCurveTo((l.x + r.x) / 2, (l.y + r.y) / 2 - d * 0.3, r.x - d / 2 * r.fx, r.y - d * 0.08);
      ctx.strokeStyle = '#8A4B12'; ctx.lineWidth = H.R * 0.055; ctx.stroke();
    }
    for (const e of eyes) {
      if (!e.visible) continue;
      ctx.beginPath(); ctx.moveTo(e.x + e.sd * d / 2 * e.fx, e.y - d * 0.1); ctx.lineTo(e.sd * H.rx * 1.05, e.y - d * 0.25);
      ctx.strokeStyle = '#8A4B12'; ctx.lineWidth = H.R * 0.05; ctx.stroke();
    }
    for (const e of eyes) {
      if (!e.visible) continue;
      ctx.save(); ctx.translate(e.x, e.y); ctx.scale(e.fx, e.fy);
      ctx.beginPath(); ctx.arc(0, 0, d / 2, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(190,225,255,0.18)'; ctx.fill();
      ctx.lineWidth = H.R * 0.065; ctx.strokeStyle = '#9A5A1A'; ctx.stroke();
      ctx.beginPath(); ctx.arc(0, 0, d / 2 - H.R * 0.03, Math.PI * 1.1, Math.PI * 1.45);
      ctx.strokeStyle = 'rgba(255,255,255,0.55)'; ctx.lineWidth = H.R * 0.03; ctx.stroke();
      ctx.restore();
    }
    ctx.restore();
  }
};

// --- Scarf: knitted band wrapped low around the body, knot + hanging end
OUTFITS.scarf = {
  front(ctx, H, path) {
    const s = 1.05, y0 = -0.34, y1 = -0.66;
    const top = frontArc(H, y0, s), bot = frontArc(H, y1, s);
    const band = new Path2D();
    top.forEach((q, i) => i ? band.lineTo(q.x, q.y) : band.moveTo(q.x, q.y));
    for (let i = bot.length - 1; i >= 0; i--) band.lineTo(bot[i].x, bot[i].y);
    band.closePath();
    ctx.save(); ctx.clip(mochiPath(H.rx * s, H.ry * s));
    ctx.fillStyle = lin(ctx, 0, -H.ry * 0.2, 0, H.ry * 0.7, [[0, '#F87171'], [1, '#B91C1C']]); ctx.fill(band);
    ctx.clip(band);
    // stripes along meridians
    for (const lon of [-1.0, -0.45, 0.1, 0.65, 1.2]) {
      const a = proj(H, surf(y0, lon + H.yaw * 0, s)), b = proj(H, surf(y1, lon, s));
      if (a.z < 0) continue;
      ctx.beginPath(); ctx.moveTo(a.x, a.y - 4); ctx.lineTo(b.x, b.y + 4);
      ctx.strokeStyle = 'rgba(255,255,255,0.85)'; ctx.lineWidth = H.R * 0.09 * Math.max(0.3, a.z); ctx.stroke();
    }
    ctx.fillStyle = lin(ctx, 0, -H.ry * 0.5, 0, H.ry * 0.3, [[0, 'rgba(255,255,255,0.18)'], [1, 'rgba(0,0,0,0.1)']]); ctx.fill(band);
    ctx.restore();
    // hanging end from the knot at lon -0.55
    const k = proj(H, surf((y0 + y1) / 2, -0.55, s * 1.03));
    if (k.z > 0) {
      const sw = H.phys.dx * H.rx * 0.12;
      const end = new Path2D();
      end.moveTo(k.x - H.R * 0.16, k.y);
      end.quadraticCurveTo(k.x - H.R * 0.24 + sw, k.y + H.ry * 0.35, k.x - H.R * 0.2 + sw * 1.4, k.y + H.ry * 0.62);
      end.lineTo(k.x + H.R * 0.06 + sw * 1.4, k.y + H.ry * 0.6);
      end.quadraticCurveTo(k.x + H.R * 0.02 + sw, k.y + H.ry * 0.3, k.x + H.R * 0.12, k.y);
      end.closePath();
      ctx.fillStyle = lin(ctx, 0, k.y, 0, k.y + H.ry * 0.6, [[0, '#EF4444'], [1, '#B91C1C']]); ctx.fill(end);
      ctx.save(); ctx.clip(end);
      ctx.fillStyle = 'rgba(255,255,255,0.85)';
      for (const t of [0.35, 0.7]) ctx.fillRect(k.x - H.R * 0.4 + sw, k.y + H.ry * 0.62 * t, H.R * 0.8, H.R * 0.07);
      ctx.restore();
      // fringe
      for (let i = 0; i < 4; i++) {
        const fx = k.x - H.R * 0.17 + sw * 1.4 + i * H.R * 0.075;
        ctx.beginPath(); ctx.moveTo(fx, k.y + H.ry * 0.6); ctx.lineTo(fx, k.y + H.ry * 0.72);
        ctx.strokeStyle = '#DC2626'; ctx.lineWidth = H.R * 0.035; ctx.lineCap = 'round'; ctx.stroke();
      }
      // knot
      ctx.beginPath(); ctx.ellipse(k.x, k.y, H.R * 0.17, H.R * 0.14, 0.2, 0, Math.PI * 2);
      ctx.fillStyle = rad(ctx, k.x - H.R * 0.05, k.y - H.R * 0.05, 0, H.R * 0.2, [[0, '#F87171'], [1, '#B91C1C']]); ctx.fill();
    }
  }
};

// --- Pumpkin: body recolour + soft ribs following meridians + curly stem & leaf
OUTFITS.pumpkin = {
  bodyColors: ['#FFA94D', '#E8590C'],
  front(ctx, H, path) {
    ctx.save(); ctx.clip(path);
    for (const lon of [-1.15, -0.55, 0.0, 0.55, 1.15]) {
      const pts = [];
      for (let i = 0; i <= 30; i++) { const y = -0.98 + 1.96 * i / 30; const q = proj(H, surf(y, lon, 1)); if (q.z > 0) pts.push(q); }
      if (pts.length < 2) continue;
      ctx.beginPath(); pts.forEach((q, i) => i ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y));
      const zz = pts[Math.floor(pts.length / 2)].z;
      ctx.strokeStyle = `rgba(150,50,0,${0.22 * zz})`; ctx.lineWidth = H.R * 0.12; ctx.lineCap = 'round'; ctx.stroke();
      ctx.strokeStyle = `rgba(255,220,170,${0.18 * zz})`; ctx.lineWidth = H.R * 0.04; ctx.save(); ctx.translate(H.R * 0.07, 0); ctx.stroke(); ctx.restore();
    }
    ctx.restore();
    const t = proj(H, [0.02, 1.0, 0]);
    // stem
    ctx.beginPath(); ctx.moveTo(t.x - H.R * 0.09, t.y + H.R * 0.04);
    ctx.quadraticCurveTo(t.x - H.R * 0.08, t.y - H.R * 0.22, t.x + H.R * 0.08, t.y - H.R * 0.3);
    ctx.lineTo(t.x + H.R * 0.13, t.y - H.R * 0.22);
    ctx.quadraticCurveTo(t.x + H.R * 0.04, t.y - H.R * 0.15, t.x + H.R * 0.08, t.y + H.R * 0.04); ctx.closePath();
    ctx.fillStyle = lin(ctx, t.x - H.R * 0.1, 0, t.x + H.R * 0.1, 0, [[0, '#65A30D'], [1, '#3F6212']]); ctx.fill();
    // leaf
    ctx.save(); ctx.translate(t.x - H.R * 0.06, t.y - H.R * 0.02); ctx.rotate(-0.5);
    ctx.beginPath(); ctx.moveTo(0, 0); ctx.quadraticCurveTo(-H.R * 0.18, -H.R * 0.2, -H.R * 0.38, -H.R * 0.02); ctx.quadraticCurveTo(-H.R * 0.18, H.R * 0.1, 0, 0);
    ctx.fillStyle = lin(ctx, 0, -H.R * 0.15, -H.R * 0.3, 0, [[0, '#84CC16'], [1, '#4D7C0F']]); ctx.fill();
    ctx.beginPath(); ctx.moveTo(-H.R * 0.02, -H.R * 0.01); ctx.quadraticCurveTo(-H.R * 0.18, -H.R * 0.08, -H.R * 0.32, -H.R * 0.03); ctx.strokeStyle = 'rgba(30,60,0,0.4)'; ctx.lineWidth = H.R * 0.02; ctx.stroke();
    ctx.restore();
    // curly tendril
    ctx.beginPath(); ctx.moveTo(t.x + H.R * 0.1, t.y - H.R * 0.12);
    ctx.bezierCurveTo(t.x + H.R * 0.3, t.y - H.R * 0.25, t.x + H.R * 0.35, t.y - H.R * 0.02, t.x + H.R * 0.22, t.y - H.R * 0.06);
    ctx.strokeStyle = '#4D7C0F'; ctx.lineWidth = H.R * 0.03; ctx.lineCap = 'round'; ctx.stroke();
  }
};

// --- Bow (kept, now anchored in 3D so it turns with the head)
OUTFITS.bow = {
  front(ctx, H, path) {
    const a = proj(H, surf(0.86, 0.55, 1.02));
    if (a.z < -0.2) return;
    const s = H.R * 0.26, sq = Math.max(0.45, Math.cos(0.55 + H.yaw));
    ctx.save(); ctx.translate(a.x, a.y); ctx.rotate(0.35 + H.yaw * 0.3); ctx.scale(sq, 1);
    for (const sd of [-1, 1]) {
      ctx.beginPath(); ctx.moveTo(0, 0);
      ctx.bezierCurveTo(sd * s * 0.6, -s * 0.85, sd * s * 1.35, -s * 0.55, sd * s * 1.15, 0);
      ctx.bezierCurveTo(sd * s * 1.35, s * 0.55, sd * s * 0.6, s * 0.85, 0, 0);
      ctx.fillStyle = lin(ctx, 0, -s, 0, s, [[0, '#FF8CC6'], [1, '#DB2777']]); ctx.fill();
      ctx.beginPath(); ctx.moveTo(sd * s * 0.25, -s * 0.05); ctx.quadraticCurveTo(sd * s * 0.7, -s * 0.15, sd * s * 0.95, -s * 0.05);
      ctx.strokeStyle = 'rgba(140,10,70,0.35)'; ctx.lineWidth = s * 0.08; ctx.lineCap = 'round'; ctx.stroke();
    }
    ctx.beginPath(); ctx.ellipse(0, 0, s * 0.24, s * 0.3, 0, 0, Math.PI * 2);
    ctx.fillStyle = rad(ctx, -s * 0.06, -s * 0.1, 0, s * 0.35, [[0, '#FFB3D9'], [1, '#C2185B']]); ctx.fill();
    ctx.restore();
  }
};

// ---------- composite draw ----------
function drawMochi(ctx, W, opts) {
  const R = W * (opts.scale || 1) * 0.3;
  const H = { R, rx: R * 1.14, ry: R * 0.88, view: VIEW_TILT, yaw: opts.yaw || 0, pitch: opts.pitch || 0, phys: opts.phys || { dx: 0, dy: 0 } };
  const o = opts.outfit ? OUTFITS[opts.outfit] : null;
  ctx.save(); ctx.translate(W / 2, W / 2 + R * 0.45);
  if (opts.tilt) ctx.rotate(opts.tilt);
  if (o && o.back) o.back(ctx, H);
  const path = drawBody(ctx, H, o && o.bodyColors);
  drawEyes(ctx, H, path);
  if (o && o.front) o.front(ctx, H, path);
  ctx.restore();
}
