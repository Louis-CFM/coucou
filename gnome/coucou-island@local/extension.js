import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import Cairo from 'cairo';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {centeredFrame, capsulePose, surfaceRect, outsideRects} from './motion.js';

const decoder = new TextDecoder();

export default class CoucouIsland extends Extension {
    enable() {
        this._test = GLib.getenv('COUCOU_PANEL_TEST') === '1';
        this._runtime = GLib.get_user_runtime_dir();
        this._activeFile = Gio.File.new_for_path(`${this._runtime}/coucou-panel-active`);
        this._statusFile = Gio.File.new_for_path(`${this._runtime}/coucou-panel-status.json`);
        this._frameFile = Gio.File.new_for_path(`${this._runtime}/coucou-panel-frame.png`);
        this._pointerFile = Gio.File.new_for_path(`${this._runtime}/coucou-panel-pointer.json`);
        this._pixelsFile = Gio.File.new_for_path(`${this._runtime}/coucou-panel-frame.rgba`);
        this._texture = null;
        this._textureContent = null;
        this._sequence = -1;
        this._pixelTime = 0;
        this._paintedFrames = 0;
        this._clockTicks = 0;
        this._frameSurface = null;
        this._frameTime = 0;
        this._pointerKey = '';
        this._pointerTime = 0;
        this._dateMenu = Main.panel.statusArea.dateMenu;
        this._dateVisible = this._dateMenu.container.visible;
        this._calendarSource = this._dateMenu.menu.sourceActor;
        this._calendarFocus = this._dateMenu.menu.focusActor;
        this._lastExpanded = false;
        this._lastClosing = false;
        this._lastPhase = 'idle';
        this._dismissAreas = [];
        this._dismissRequested = false;
        this._surfaceModal = false;
        this._surfaceSize = null;
        this._surfaceActor = null;
        this._motionState = null;

        this._button = new PanelMenu.Button(0.5, _('Coucou Dynamic Island'), true);
        this._button.add_style_class_name('coucou-island-button');
        this._button.set_style('padding: 0 4px; background-color: transparent; border: none; box-shadow: none;');
        this._pill = new St.BoxLayout({style_class: 'coucou-island-pill',
            y_align: Clutter.ActorAlign.CENTER});
        this._gaze = {x: 0, y: 0};
        this._blink = false;
        this._face = new St.Widget({width: 40, height: 28,
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        this._fallback = new St.DrawingArea({width: 40, height: 28});
        this._fallback.connect('repaint', () => this._paintFace());
        this._picture = new Clutter.Actor({x: 2.5, y: 0, width: 35, height: 28, visible: false});
        this._face.add_child(this._fallback);
        this._face.add_child(this._picture);
        this._label = new St.Label({style_class: 'coucou-island-label',
            y_align: Clutter.ActorAlign.CENTER, x_expand: true});
        this._signal = new St.Bin({style_class: 'coucou-island-signal',
            y_align: Clutter.ActorAlign.CENTER, x_align: Clutter.ActorAlign.CENTER});
        this._signalText = new St.Label({style_class: 'coucou-island-signal-text',
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        this._dot = new St.Widget({style_class: 'coucou-island-dot',
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        this._signal.child = this._dot;
        this._time = new St.Label({style_class: 'coucou-island-time',
            y_align: Clutter.ActorAlign.CENTER});
        for (const child of [this._face, this._label, this._signal, this._time])
            this._pill.add_child(child);
        this._button.add_child(this._pill);
        Main.panel.addToStatusArea(this.uuid, this._button, 0, 'center');
        this._dateMenu.container.hide();
        // Only anchor the calendar here while explicitly opened. Leaving this
        // button as its source lets GNOME switch to the calendar on pointer enter.
        this._calendarClosedId = this._dateMenu.menu.connect('open-state-changed', (_menu, open) => {
            if (!open) this._restoreCalendarAnchor();
        });
        this._button.connect('button-press-event', (_actor, event) => {
            if (event.get_button() === 3) {
                if (this._lastExpanded) this._requestDismiss();
                this._dateMenu.menu.sourceActor = this._button;
                this._dateMenu.menu.focusActor = this._button;
                this._dateMenu.menu.toggle();
            } else if (event.get_button() === 1) {
                this._dateMenu.menu.close();
                this._restoreCalendarAnchor();
                this._primaryAction();
            } else {
                return Clutter.EVENT_PROPAGATE;
            }
            return Clutter.EVENT_STOP;
        });
        this._button.connect('key-press-event', (_actor, event) => {
            if ([Clutter.KEY_Return, Clutter.KEY_space].includes(event.get_key_symbol())) {
                this._dateMenu.menu.close();
                this._restoreCalendarAnchor();
                this._primaryAction();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        this._monitor = this._statusFile.monitor_file(Gio.FileMonitorFlags.NONE, null);
        this._monitor.connect('changed', () => this._refresh());
        this._frameMonitor = this._frameFile.monitor_file(Gio.FileMonitorFlags.NONE, null);
        this._frameMonitor.set_rate_limit(16);
        this._frameMonitor.connect('changed', () => this._loadFrame());
        this._loadFrame();
        this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._windowCreatedId = global.display.connect('window-created', () => this._refresh());
        this._focusChangedId = global.display.connect('notify::focus-window', () => {
            const window = global.display.focus_window;
            const source = this._surfaceActor?.meta_window;
            this._surfaceModal = Boolean(source && window?.get_transient_for() === source);
            if (this._surfaceModal) {
                this._clearDismissAreas();
                return;
            }
            if (source && window === source) this._refresh();
            if (source && window && window !== source && window.get_transient_for() !== source &&
                GLib.get_monotonic_time() > (this._openingUntil ?? 0)) this._requestDismiss();
        });
        this._refresh();
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        // The monitor's frame clock drives presentation (120 Hz on a 120 Hz
        // screen). Always consume the latest snapshot; never queue old frames.
        this._animation = Clutter.Timeline.new_for_actor(this._face, 1000);
        this._animation.set_repeat_count(-1);
        this._animation.connect('new-frame', () => {
            this._clockTicks++;
            this._animateFace();
            if (this._face.mapped) this._loadPixels();
        });
        this._animation.start();
        // A marker lets Coucou replace its compact window with this panel pill.
        // It contains the shell PID, so an old marker cannot hide Coucou later.
        const [, pidBytes] = GLib.file_get_contents('/proc/self/stat');
        const pid = decoder.decode(pidBytes).split(' ')[0];
        this._activeFile.replace_contents(pid, null, false,
            Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        if (!this._test) {
            try { Gio.Subprocess.new([GLib.find_program_in_path('coucou') ?? 'coucou'], Gio.SubprocessFlags.NONE); }
            catch (error) { console.error(`Coucou: ${error.message}`); }
        }
    }

    _primaryAction() {
        if (this._lastExpanded && !this._lastClosing) {
            this._requestDismiss();
        } else {
            this._dismissRequested = false;
            this._run(this._lastPhase === 'waiting' && !this._lastExpanded ? 'goToAlert' : 'toggleIsland');
        }
    }

    _requestDismiss() {
        if (!this._lastExpanded || this._lastClosing || this._dismissRequested) return;
        this._dismissRequested = true;
        this._clearDismissAreas();
        this._run('closeIsland');
    }

    _capsuleRect() {
        const [x, y] = this._pill.get_transformed_position();
        const [width, height] = this._pill.get_transformed_size();
        return {x, y, width, height};
    }

    _findSurface() {
        return global.get_window_actors().find(actor => actor.meta_window?.get_title() === 'Coucou' &&
            actor.meta_window.get_wm_class()?.toLowerCase() === 'coucou');
    }

    _syncSurface(status) {
        if (!status.motion) {
            this._clearDismissAreas();
            return;
        }
        if (!this._surfaceActor) {
            const actor = this._findSurface();
            if (!actor || !this._pill.has_allocation()) return;
            this._surfaceActor = actor;
            this._originalSurface = {opacity: actor.opacity, scale_x: actor.scale_x,
                scale_y: actor.scale_y, translation_x: actor.translation_x,
                translation_y: actor.translation_y, pivot: actor.get_pivot_point()};
            actor.set_pivot_point(0.5, 0);
            this._surfaceDestroyedId = actor.connect('destroy', () => {
                this._surfaceActor = null;
                this._surfaceDestroyedId = 0;
                this._motionState = null;
                this._clearDismissAreas();
            });
        }
        const actor = this._surfaceActor;
        let rect = actor.meta_window.get_frame_rect();
        if (Number(status.surfaceWidth) > 0 && Number(status.surfaceHeight) > 0)
            this._surfaceSize = {width: status.surfaceWidth, height: status.surfaceHeight};
        const size = this._surfaceSize ?? {width: 640, height: 180};
        const capsule = this._capsuleRect();
        // Move the real window, so visual and native input coordinates agree.
        // Centering a scaled actor alone would leave buttons at the old position.
        const centered = centeredFrame(rect, capsule);
        if (rect.x !== centered.x) {
            actor.meta_window.move_frame(true, centered.x, rect.y);
            rect = actor.meta_window.get_frame_rect();
        }
        const pose = capsulePose(rect, capsule, size);
        const state = status.expanded ? status.closing ? 'closing' : 'open' : 'closed';
        if (state !== this._motionState) {
            const initial = this._motionState === null;
            this._motionState = state;
            actor.remove_all_transitions();
            const duration = St.Settings.get().enable_animations ? 320 : 0;
            if (state === 'open') {
                this._openingUntil = GLib.get_monotonic_time() + duration * 1000;
                this._dismissRequested = false;
                if (initial || actor.opacity === 0) Object.assign(actor, pose, {opacity: 0});
                actor.ease({scale_x: 1, scale_y: 1, translation_x: 0, translation_y: 0,
                    opacity: 255, duration, mode: Clutter.AnimationMode.EASE_IN_OUT_CUBIC});
            } else if (state === 'closing') {
                actor.ease({...pose, opacity: 0, duration,
                    mode: Clutter.AnimationMode.EASE_IN_OUT_CUBIC});
            } else {
                Object.assign(actor, pose, {opacity: 0});
                this._dismissRequested = false;
            }
        }
        // Keep the hidden origin in sync when the clock or monitor moves.
        if (state === 'closed') Object.assign(actor, pose, {opacity: 0});
        if (state === 'open' && !this._dismissRequested && !this._surfaceModal)
            this._syncDismissAreas(surfaceRect(rect, size), capsule);
        else
            this._clearDismissAreas();
    }

    _syncDismissAreas(surface, capsule) {
        const rects = outsideRects(Main.layoutManager.monitors, [surface, capsule]);
        const key = JSON.stringify(rects);
        if (key === this._dismissKey) return;
        this._clearDismissAreas();
        this._dismissKey = key;
        for (const rect of rects) {
            const area = new St.Widget({...rect, reactive: true,
                name: 'coucou-dismiss-area', style: 'background-color: transparent;'});
            area.connect('button-press-event', () => {
                this._requestDismiss();
                return Clutter.EVENT_STOP;
            });
            area.connect('touch-event', (_actor, event) => {
                if (event.type() === Clutter.EventType.TOUCH_BEGIN) this._requestDismiss();
                return Clutter.EVENT_STOP;
            });
            Main.layoutManager.addChrome(area, {trackFullscreen: false});
            this._dismissAreas.push(area);
        }
    }

    _clearDismissAreas() {
        for (const area of this._dismissAreas ?? []) {
            Main.layoutManager.removeChrome(area);
            area.destroy();
        }
        this._dismissAreas = [];
        this._dismissKey = null;
    }

    _restoreCalendarAnchor() {
        this._dateMenu.menu.sourceActor = this._calendarSource;
        this._dateMenu.menu.focusActor = this._calendarFocus;
    }

    _animateFace() {
        if (!this._face) return;
        const [px, py] = global.get_pointer();
        const [fx, fy] = this._face.get_transformed_position();
        const [fw, fh] = this._face.get_transformed_size();
        const dx = px - fx - fw / 2;
        const dy = py - fy - fh / 2;
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const near = Math.hypot(dx, dy) < 220 * scale;
        const pointer = {x: near ? Math.tanh(dx / (80 * scale)) : 0,
            y: near ? -Math.tanh(dy / (80 * scale)) : 0,
            hover: Math.abs(dx) < fw / 2 && Math.abs(dy) < fh / 2,
            visible: this._face.mapped, transport: "rgba120"};
        pointer.x = Math.round(pointer.x * 1000) / 1000;
        pointer.y = Math.round(pointer.y * 1000) / 1000;
        const key = JSON.stringify(pointer);
        const now = GLib.get_real_time() / 1e6;
        if (key !== this._pointerKey || now - this._pointerTime >= 1) {
            this._pointerKey = key;
            this._pointerTime = now;
            try {
                this._pointerFile.replace_contents(JSON.stringify({...pointer, updated: now}), null, false,
                    Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION, null);
            } catch { /* The session's runtime directory may already be closing. */ }
        }
        if (!this._face.mapped) return;
        const tx = near ? Math.max(-2.6, Math.min(2.6, dx / (25 * scale))) : 0;
        const ty = near ? Math.max(-1.6, Math.min(1.6, dy / (30 * scale))) : 0;
        const tick = GLib.get_monotonic_time() / 1e6;
        const blend = 1 - Math.exp(-8 * Math.min(.1, tick - (this._gazeTime ?? tick)));
        this._gazeTime = tick;
        this._gaze.x += (tx - this._gaze.x) * blend;
        this._gaze.y += (ty - this._gaze.y) * blend;
        const seconds = GLib.get_monotonic_time() / 1e6;
        const blink = seconds % 6.4 < 0.14;
        if (Math.abs(tx - this._gaze.x) > 0.01 || Math.abs(ty - this._gaze.y) > 0.01 || blink !== this._blink) {
            this._blink = blink;
            this._fallback.queue_repaint();
        }
        if (this._lastPhase === 'working')
            this._dot.opacity = Math.round(210 + 45 * Math.sin(seconds * 2.4));
        else
            this._dot.opacity = 255;
    }

    _paintFace() {
        const cr = this._fallback.get_context();
        const [width, height] = this._fallback.get_surface_size();
        if (this._frameSurface && Date.now() - this._frameTime < 3000) {
            const scale = Math.min(width / 80, height / 64);
            cr.translate((width - 80 * scale) / 2, (height - 64 * scale) / 2);
            cr.scale(scale, scale);
            cr.setSourceSurface(this._frameSurface, 0, 0);
            cr.paint();
            cr.$dispose();
            return;
        }
        cr.translate((width - height) / 2, 0);
        cr.scale(height / 28, height / 28);
        cr.translate(this._gaze.x * 0.18, this._gaze.y * 0.18);
        cr.setSourceRGBA(0.95, 0.97, 1, 1);
        cr.moveTo(6, 6);
        cr.curveTo(9, 3.6, 19, 3.6, 22, 6);
        cr.curveTo(26, 9, 26, 19, 22, 23);
        cr.curveTo(19, 26, 9, 26, 6, 23);
        cr.curveTo(2, 19, 2, 9, 6, 6);
        cr.fill();
        cr.setSourceRGBA(0.035, 0.04, 0.06, 1);
        for (const x of [10, 19]) {
            const ex = x + this._gaze.x;
            const ey = 14.5 + this._gaze.y;
            if (this._blink) {
                cr.setLineWidth(1.7);
                cr.moveTo(ex - 1.6, ey);
                cr.lineTo(ex + 1.6, ey);
                cr.stroke();
            } else {
                cr.arc(ex, ey, 1.75, 0, 2 * Math.PI);
                cr.fill();
            }
        }
        cr.setSourceRGBA(0.035, 0.04, 0.06, 1);
        cr.arc(24, 5, 4, 0, 2 * Math.PI);
        cr.fill();
        cr.setSourceRGBA(0.42, 0.85, 0.96, 1);
        cr.arc(24, 5, 2.5, 0, 2 * Math.PI);
        cr.fill();
        cr.$dispose();
    }

    _loadPixels() {
        try {
            const [ok, bytes] = this._pixelsFile.load_contents(null);
            if (!ok || bytes.length !== 20496 ||
                ![67,67,70,49].every((b, i) => bytes[i] === b)) return;
            const header = new DataView(bytes.buffer, bytes.byteOffset, 16);
            const captured = header.getFloat64(8, true);
            if (!Number.isFinite(captured) || Math.abs(Date.now() - captured) > 3000) {
                this._picture.hide(); this._fallback.show(); return;
            }
            const sequence = header.getUint32(4, true);
            if (sequence === this._sequence && captured === this._pixelTime) return;
            const pixels = bytes.subarray(16);
            if (!this._texture) {
                const context = Clutter.get_default_backend().get_cogl_context();
                this._texture = Cogl.Texture2D.new_from_data(context, 80, 64,
                    Cogl.PixelFormat.RGBA_8888, 320, pixels);
                this._textureContent = Clutter.TextureContent.new_from_texture(this._texture, null);
                this._picture.content = this._textureContent;
            } else {
                this._texture.set_data(Cogl.PixelFormat.RGBA_8888, 320, pixels, 0);
                this._textureContent.invalidate();
            }
            this._sequence = sequence;
            this._pixelTime = captured;
            this._frameTime = Date.now();
            this._paintedFrames++;
            this._fallback.hide(); this._picture.show();
        } catch (error) {
            if (error.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND)) return;
            if (this._test && !this._pixelError) {
                this._pixelError = error.message;
                console.error(`Coucou pixel transport: ${error.message}`);
            }
        }
    }

    _loadFrame() {
        try {
            const [ok, bytes] = this._frameFile.load_contents(null);
            if (!ok || bytes.length < 33 || bytes.length > 65536 ||
                ![137,80,78,71,13,10,26,10].every((b, i) => bytes[i] === b)) return;
            const next = Cairo.ImageSurface.createFromPNG(this._frameFile.get_path());
            if (next.getWidth() !== 80 || next.getHeight() !== 64) { next.finish(); return; }
            this._frameSurface?.finish();
            this._frameSurface = next;
            this._frameTime = Date.now();
            this._fallback?.queue_repaint();
        } catch { /* First frame has not arrived, or Coucou is restarting. */ }
    }

    _run(action) {
        if (this._test) return;
        try {
            Gio.Subprocess.new([GLib.find_program_in_path('coucou') ?? 'coucou', '--shortcut', action], Gio.SubprocessFlags.NONE);
        } catch (error) {
            console.error(`Coucou shortcut: ${error.message}`);
        }
    }

    _refresh() {
        if (!this._pill) return;
        let status = null;
        try {
            const [ok, contents] = this._statusFile.load_contents(null);
            if (ok) status = JSON.parse(decoder.decode(contents));
        } catch { /* Coucou has not started yet. */ }
        if (!status || Date.now() / 1000 - Number(status.updated) > 5)
            status = {phase: 'idle', expanded: false, waiting: 0, working: 0};
        const phase = ['working', 'waiting', 'error', 'finished'].includes(status.phase) ? status.phase : 'idle';
        this._lastPhase = phase;
        this._lastExpanded = Boolean(status.expanded);
        this._lastClosing = Boolean(status.closing);
        this._syncSurface(status);
        this._pill.set_style_class_name(`coucou-island-pill ${phase}`);
        const now = GLib.DateTime.new_now_local();
        const clock12 = this._interface?.get_string('clock-format') === '12h';
        this._time.text = now.format(clock12 ? '%I:%M %p' : '%H:%M');
        const agent = typeof status.agent === 'string' ? status.agent.slice(0, 28) : '';
        if (phase === 'waiting') {
            this._label.text = agent ? _('%s · Permission').replace('%s', agent) : _('Needs your permission');
            this._signalText.text = String(Math.max(1, Number(status.waiting) || 1));
        } else if (phase === 'working') {
            this._label.text = Number(status.working) > 1 ? _('%s agents working').replace('%s', String(status.working)) : _('%s · Working').replace('%s', agent || 'Coucou');
        } else if (phase === 'error') {
            this._label.text = _('Coucou · Check status');
            this._signalText.text = '!';
        } else if (phase === 'finished') {
            this._label.text = _('Task completed');
            this._signalText.text = '✓';
        } else {
            this._label.text = now.format('%a %e %b');
        }
        this._signal.child = ['working', 'idle'].includes(phase) ? this._dot : this._signalText;
        this._button.accessible_name = `${this._label.text}, ${this._time.text}. ${_('Click: Coucou. Right click: calendar.')}`;
        if (this._test) {
            GLib.file_set_contents(`${this._runtime}/coucou-test-ui.json`, JSON.stringify({
                phase, label: this._label.text, time: this._time.text,
                originalClockVisible: this._dateMenu.container.visible,
                capsuleVisible: this._button.visible,
                liveMascot: Boolean(this._texture || this._frameSurface), frameTime: this._frameTime,
                paintedFrames: this._paintedFrames, clockTicks: this._clockTicks,
                pixelTime: this._pixelTime, pixelError: this._pixelError ?? null,
            }));
        }
    }

    disable() {
        this._clearDismissAreas();
        if (this._windowCreatedId) global.display.disconnect(this._windowCreatedId);
        if (this._focusChangedId) global.display.disconnect(this._focusChangedId);
        this._windowCreatedId = this._focusChangedId = 0;
        if (this._surfaceActor) {
            this._surfaceActor.disconnect(this._surfaceDestroyedId);
            this._surfaceActor.remove_all_transitions();
            const {pivot, ...original} = this._originalSurface;
            Object.assign(this._surfaceActor, original);
            this._surfaceActor.set_pivot_point(...pivot);
            this._surfaceActor = null;
        }
        if (this._timer) GLib.Source.remove(this._timer);
        this._timer = 0;
        this._animation?.stop();
        this._animation = null;
        this._monitor?.cancel();
        this._monitor = null;
        this._frameMonitor?.cancel();
        this._frameMonitor = null;
        this._frameSurface?.finish();
        this._frameSurface = null;
        try { this._pointerFile?.delete(null); } catch { /* Already removed. */ }
        try { this._activeFile?.delete(null); } catch { /* Already removed. */ }
        if (this._dateMenu) {
            if (this._calendarClosedId) this._dateMenu.menu.disconnect(this._calendarClosedId);
            this._calendarClosedId = 0;
            this._dateMenu.menu.close();
            this._restoreCalendarAnchor();
            if (this._dateVisible) this._dateMenu.container.show();
        }
        if (this._signal) this._signal.child = null;
        this._signalText?.destroy();
        this._dot?.destroy();
        this._button?.destroy();
        this._button = null;
        this._pill = null;
        this._face = null;
        this._fallback = this._picture = null;
        this._textureContent = this._texture = null;
        this._pixelsFile = null;
        this._signal = null;
        this._signalText = null;
        this._dot = null;
        this._dateMenu = null;
        this._interface = null;
        this._activeFile = null;
        this._statusFile = null;
        this._frameFile = null;
        this._pointerFile = null;
    }
}
