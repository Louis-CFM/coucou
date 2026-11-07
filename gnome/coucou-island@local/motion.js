// Use GNOME stage coordinates for both the frame and capsule. Coucou reports
// its visible size in logical pixels inside a 720 px wide transparent window.
// GTK/XWayland can change the actual frame size after native positioning.
export function centeredFrame(window, capsule) {
    return {...window, x: Math.round(capsule.x + (capsule.width - window.width) / 2)};
}
export function capsulePose(window, capsule, surface) {
    const scale = window.width / 720;
    return {
        scale_x: capsule.width / Math.max(1, surface.width * scale),
        scale_y: capsule.height / Math.max(1, surface.height * scale),
        translation_x: capsule.x + capsule.width / 2 - window.x - window.width / 2,
        translation_y: capsule.y - window.y,
    };
}

export function surfaceRect(window, surface) {
    const scale = window.width / 720;
    const width = surface.width * scale;
    return {x: window.x + (window.width - width) / 2, y: window.y,
        width, height: surface.height * scale};
}

// Four-way subtraction makes a real input hole, so inside clicks reach Coucou
// on Wayland as well as X11. An outside press is consumed like a normal popup.
export function outsideRects(monitors, holes) {
    let pieces = monitors.map(r => ({x: r.x, y: r.y, width: r.width, height: r.height}));
    for (const hole of holes) {
        const next = [];
        for (const r of pieces) {
            const x1 = Math.max(r.x, hole.x);
            const y1 = Math.max(r.y, hole.y);
            const x2 = Math.min(r.x + r.width, hole.x + hole.width);
            const y2 = Math.min(r.y + r.height, hole.y + hole.height);
            if (x1 >= x2 || y1 >= y2) { next.push(r); continue; }
            next.push(
                {x: r.x, y: r.y, width: r.width, height: y1 - r.y},
                {x: r.x, y: y2, width: r.width, height: r.y + r.height - y2},
                {x: r.x, y: y1, width: x1 - r.x, height: y2 - y1},
                {x: x2, y: y1, width: r.x + r.width - x2, height: y2 - y1});
        }
        pieces = next.filter(r => r.width > 0 && r.height > 0);
    }
    return pieces;
}
