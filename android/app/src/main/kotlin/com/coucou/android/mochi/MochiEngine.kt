package com.coucou.android.mochi

import com.coucou.android.mochi.outfit.Outfit
import com.coucou.android.core.Ease
import com.coucou.android.core.EaseFn
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * Mochi's animation state machine: a port of windows/src/mochi/engine.ts (itself a port of
 * BotEngine.swift). Same constants, tweens, easings and particles. Drawing lives in
 * MochiPainter; this class has no Android dependency so it runs in plain JVM unit tests.
 *
 * Not ported yet: outfits (wardrobe), which the author's assets cover but are a later phase.
 */
fun interface SoundSink { fun play(name: String) }

enum class Prop { YAW, PITCH, ROLL, TILT, OPEN, SX, SY, OY, OX, TINT, MORPH, HANDS, BLUSH, ES, BADGE_S, OUTFIT_PRESENCE }

class TweenKey(val target: Double, val durationMs: Double, val ease: EaseFn)

enum class ParticleType { HEART, STAR, SPARK, SWEAT, Z }

class Particle(
    val type: ParticleType,
    val x: Double, val y: Double, val vx: Double, val vy: Double,
    var age: Double, val life: Double, val rot: Double, val size: Double,
)

private class Tween(
    val prop: Prop,
    val keys: List<TweenKey>,
    var index: Int,
    var from: Double,
    var startMs: Double,
    val onComplete: (() -> Unit)?,
)

private class Scheduled(val dueMs: Double, val action: () -> Unit)

class MochiEngine(
    /** Monotonic clock in milliseconds (performance.now() in the TS port). */
    private val clockMs: () -> Double,
    private val random: Random = Random.Default,
    private val sound: SoundSink = SoundSink { },
) {
    var isMini = false
    /** Solid body colour for mini bots (null = Mochi gradient). */
    var bodyColor: Rgb? = null

    // Animated state (BotEngine `s`)
    var yaw = 0.0; var pitch = 0.0; var roll = 0.0; var tilt = 0.0; var open = 1.0
    var sx = 1.0; var sy = 1.0; var oy = 0.0; var ox = 0.0
    var tint = 0.0; var morph = 0.0; var hands = 0.0; var blush = 0.0; var es = 1.0; var badgeS = 0.0

    // Outfit (the main Mochi only: minis never wear one). `outfit` is what is drawn; it changes only once the previous one has left.
    var outfit: Outfit = Outfit.NONE
        private set
    /** 0 = gone, 1 = fully on. */
    var outfitPresence = 0.0
    private var outfitTarget: Outfit = Outfit.NONE

    // Spring lag of the soft parts (pompoms, hat tips, scarf end), -1..1.
    var physDx = 0.0
    var physDy = 0.0
    private var physVx = 0.0
    private var physVy = 0.0
    private var prevYaw = 0.0
    private var prevOy = 0.0
    private var prevRoll = 0.0

    var tgYaw = 0.0; var tgPitch = 0.0; var tgTilt = 0.0; var tgSy = 1.0; var tgSx = 1.0; var tgEs = 1.0

    /** Extra canvas height above the body so hearts can fly out without clipping. */
    var particleOverhang = 0.0

    // Mouth spring (fraction of R)
    var slotH = 0.0; var slotHTarget = 0.0; var slotHVel = 0.0; var isChewing = false

    var col: Rgb = MochiConst.C_IDLE
    var colT: Rgb = MochiConst.C_IDLE

    var state: BotState = BotState.IDLE
        private set
    var cfg: BotStateCfg = MochiConst.STATES.getValue(BotState.IDLE)
        private set

    var eyeOverride: EyeShape? = null
    var eyeOverrideUntil = 0.0
    var permanentEye: EyeShape? = null
    var permanentEmote: BotEmote? = null
        private set
    var miniNextBehavior = 0.0

    var badge: Badge? = null
        private set
    private var badgeKey = "none"
    private var badgeToken = 0

    private val tweens = LinkedHashMap<Prop, Tween>()
    private val locks = HashSet<Prop>()
    private val scheduled = ArrayList<Scheduled>()
    private var _particles = ArrayList<Particle>()
    val particles: List<Particle> get() = _particles

    var lookX = 0.0
    var lookY = 0.0

    private val t0 = now() - random.nextDouble() * 5
    private var nextBlink = now() + 1.5 + random.nextDouble() * 2
    var waveUntil = 0.0
    var waveStart = 0.0
    private var greetToken = 0
    private var lastAmbient = 0.0
    private var slapTimes = ArrayList<Double>()
    private var miniLookX = 0.0
    private var miniLookY = 0.0
    private var miniLookNextTime = 0.0

    /** Fired when three slaps land inside 1.7 s (dizzy + confused view). */
    var onDizzy: (() -> Unit)? = null

    private fun now(): Double = clockMs() / 1000.0

    private fun get(p: Prop): Double = when (p) {
        Prop.YAW -> yaw; Prop.PITCH -> pitch; Prop.ROLL -> roll; Prop.TILT -> tilt
        Prop.OPEN -> open; Prop.SX -> sx; Prop.SY -> sy; Prop.OY -> oy; Prop.OX -> ox
        Prop.TINT -> tint; Prop.MORPH -> morph; Prop.HANDS -> hands; Prop.BLUSH -> blush
        Prop.ES -> es; Prop.BADGE_S -> badgeS; Prop.OUTFIT_PRESENCE -> outfitPresence
    }

    private fun set(p: Prop, v: Double) {
        when (p) {
            Prop.YAW -> yaw = v; Prop.PITCH -> pitch = v; Prop.ROLL -> roll = v; Prop.TILT -> tilt = v
            Prop.OPEN -> open = v; Prop.SX -> sx = v; Prop.SY -> sy = v; Prop.OY -> oy = v; Prop.OX -> ox = v
            Prop.TINT -> tint = v; Prop.MORPH -> morph = v; Prop.HANDS -> hands = v; Prop.BLUSH -> blush = v
            Prop.ES -> es = v; Prop.BADGE_S -> badgeS = v; Prop.OUTFIT_PRESENCE -> outfitPresence = v
        }
    }

    private fun after(delayMs: Double, action: () -> Unit) {
        scheduled.add(Scheduled(clockMs() + delayMs, action))
    }

    private fun keys(vararg k: Triple<Double, Double, EaseFn>) = k.map { TweenKey(it.first, it.second, it.third) }

    // ── Public API ──────────────────────────────────────────────────────────────

    fun setState(next: BotState, force: Boolean = false) {
        if (state == next && !force) return
        val prev = state
        state = next
        cfg = MochiConst.STATES.getValue(next)
        colT = cfg.color
        if (Prop.TINT !in locks) tint = cfg.tint
        if (Prop.TILT !in locks) tgTilt = cfg.tilt
        setBadge(cfg.badge)

        when (next) {
            BotState.FINISHED -> {
                doRoll(950.0, 1)
                after(500.0) { emit(ParticleType.SPARK, 5) }
            }
            BotState.ERROR -> anim(Prop.OX, keys(
                Triple(0.08, 50.0, Ease.out), Triple(-0.08, 70.0, Ease.inOut),
                Triple(0.05, 70.0, Ease.inOut), Triple(0.0, 90.0, Ease.out),
            ))
            BotState.APPROVAL -> anim(Prop.OY, keys(Triple(-0.2, 150.0, Ease.out), Triple(0.0, 300.0, Ease.back)))
            BotState.DIZZY -> doRoll(1300.0, 2)
            BotState.QUESTION -> blink()
            BotState.RATELIMIT -> emit(ParticleType.SWEAT, 1)
            else -> if (prev != BotState.IDLE || next != BotState.IDLE) blink()
        }
    }

    fun setBadge(b: Badge?) {
        val key = if (b != null) "${b.kind}-${b.color.r},${b.color.g},${b.color.b}" else "none"
        if (key == badgeKey) return
        badgeKey = key
        val tok = ++badgeToken
        anim(Prop.BADGE_S, keys(Triple(0.0, 90.0, Ease.inOut)))
        after(100.0) {
            if (tok != badgeToken) return@after
            badge = b
            if (b != null) anim(Prop.BADGE_S, keys(Triple(1.0, 280.0, Ease.back)))
        }
    }

    fun blink() {
        if (Prop.OPEN in locks) return
        anim(Prop.OPEN, keys(Triple(0.06, 70.0, Ease.inOut), Triple(1.0, 130.0, Ease.out)))
    }

    fun squash() {
        physVy += 0.6
        anim(Prop.SY, keys(Triple(0.78, 70.0, Ease.out), Triple(1.1, 130.0, Ease.out), Triple(1.0, 170.0, Ease.inOut)))
        anim(Prop.SX, keys(Triple(1.16, 70.0, Ease.out), Triple(0.95, 130.0, Ease.out), Triple(1.0, 170.0, Ease.inOut)))
    }

    /** Mailbox swallow: opens the slot, chews, then closes. */
    fun gulp() {
        slotHTarget = 0.42
        after(460.0) {
            slotHTarget = 0.0
            isChewing = true
            after(800.0) { isChewing = false }
        }
        anim(Prop.SY, keys(Triple(0.78, 80.0, Ease.out), Triple(1.18, 130.0, Ease.out), Triple(1.0, 220.0, Ease.back)))
        anim(Prop.SX, keys(Triple(1.28, 80.0, Ease.out), Triple(0.92, 130.0, Ease.out), Triple(1.0, 220.0, Ease.back)))
        blink()
    }

    fun slap() {
        interruptGreet()
        if (state == BotState.DIZZY) return
        val t = now()
        slapTimes = ArrayList(slapTimes.filter { t - it < 1.7 })
        slapTimes.add(t)
        sound.play("slap")
        squash()
        physVy -= 1.2
        physVx += if (random.nextDouble() < 0.5) 0.7 else -0.7
        if (slapTimes.size >= 3) {
            slapTimes = ArrayList()
            onDizzy?.invoke()
        } else {
            eyeOverride = EyeShape.LINE
            eyeOverrideUntil = t + 0.8
            after(60.0) { sound.play("annoyed") }
        }
    }

    fun doRoll(durationMs: Double, turns: Int) {
        roll = 0.0
        anim(Prop.ROLL, keys(Triple(PI * 2 * turns, durationMs, Ease.inOut))) { roll = 0.0 }
    }

    /** Peek wave, the "coucou". Timings from BotEngine.greet(). */
    fun greet() {
        val t = now()
        val tok = ++greetToken
        waveStart = t + 0.45
        waveUntil = t + 1.55
        physVx += 0.2

        eyeOverride = EyeShape.HAPPY
        eyeOverrideUntil = t + 2.0
        anim(Prop.OY, keys(Triple(-0.06, 220.0, Ease.out), Triple(0.0, 220.0, Ease.back)))

        after(250.0) {
            if (greetToken != tok) return@after
            anim(Prop.HANDS, keys(Triple(1.0, 280.0, Ease.out)))
            anim(Prop.SY, keys(Triple(0.95, 100.0, Ease.out), Triple(1.0, 260.0, Ease.back)))
            anim(Prop.SX, keys(Triple(1.04, 100.0, Ease.out), Triple(1.0, 260.0, Ease.back)))
            sound.play("greet")
        }
        after(550.0) { if (greetToken == tok) blink() }
        after(1500.0) { if (greetToken == tok) blink() }
        after(1550.0) {
            if (greetToken != tok) return@after
            waveUntil = 0.0
            anim(Prop.HANDS, keys(Triple(0.0, 200.0, Ease.inOut)))
        }
        after(1750.0) {
            if (greetToken != tok) return@after
            eyeOverride = EyeShape.HAPPY
            eyeOverrideUntil = now() + 0.3
        }
    }

    fun interruptGreet() {
        if (hands <= 0.01 && now() >= waveUntil) return
        greetToken++
        waveUntil = 0.0
        waveStart = 0.0
        anim(Prop.HANDS, keys(Triple(0.0, 150.0, Ease.inOut)))
    }

    fun setPermanentEmote(emote: BotEmote?) {
        permanentEmote = emote
        if (emote == BotEmote.WINK) {
            miniNextBehavior = now() + 0.8 + random.nextDouble() * 1.7
            return
        }
        permanentEye = emote?.let { MochiConst.EMOTE_EYE.getValue(it) }
        if (permanentEye != null) {
            eyeOverride = permanentEye
            eyeOverrideUntil = Double.POSITIVE_INFINITY
        } else if (eyeOverrideUntil == Double.POSITIVE_INFINITY) {
            eyeOverride = null
            eyeOverrideUntil = 0.0
        }
        miniNextBehavior = now() + 0.8 + random.nextDouble() * 1.7
    }

    fun triggerEmote(emote: BotEmote, duration: Double = 1.8) {
        val t = now()
        eyeOverride = MochiConst.EMOTE_EYE.getValue(emote)
        eyeOverrideUntil = t + duration

        when (emote) {
            BotEmote.LOVE -> {
                anim(Prop.BLUSH, keys(
                    Triple(1.0, 300.0, Ease.out), Triple(1.0, (duration - 0.6) * 1000, Ease.lin), Triple(0.0, 300.0, Ease.inOut),
                ))
                emit(ParticleType.HEART, 4)
                anim(Prop.OY, keys(Triple(-0.1, 160.0, Ease.out), Triple(0.0, 300.0, Ease.back)))
            }
            BotEmote.SURPRISED -> {
                anim(Prop.OY, keys(Triple(-0.3, 140.0, Ease.out), Triple(0.0, 380.0, Ease.back)))
                anim(Prop.ES, keys(Triple(1.25, 120.0, Ease.out), Triple(1.0, 500.0, Ease.inOut)))
            }
            BotEmote.PROUD -> {
                emit(ParticleType.STAR, 5)
                anim(Prop.TILT, keys(
                    Triple(-0.14, 220.0, Ease.out), Triple(-0.14, (duration - 0.5) * 1000, Ease.lin), Triple(0.0, 280.0, Ease.inOut),
                ))
                anim(Prop.BLUSH, keys(
                    Triple(0.7, 250.0, Ease.out), Triple(0.7, (duration - 0.5) * 1000, Ease.lin), Triple(0.0, 300.0, Ease.inOut),
                ))
            }
            BotEmote.WINK -> anim(Prop.TILT, keys(
                Triple(0.12, 160.0, Ease.out), Triple(0.12, (duration - 0.4) * 1000, Ease.lin), Triple(0.0, 240.0, Ease.inOut),
            ))
            BotEmote.YAWN -> {
                anim(Prop.SY, keys(Triple(1.12, 500.0, Ease.inOut), Triple(1.0, 500.0, Ease.inOut)))
                anim(Prop.SX, keys(Triple(0.94, 500.0, Ease.inOut), Triple(1.0, 500.0, Ease.inOut)))
                after(700.0) { eyeOverride = EyeShape.CLOSED; emit(ParticleType.Z, 2) }
            }
            BotEmote.HAPPY -> anim(Prop.BLUSH, keys(Triple(0.6, 200.0, Ease.out), Triple(0.0, 600.0, Ease.inOut)))
            BotEmote.ANNOYED -> {
                eyeOverride = EyeShape.LINE
                eyeOverrideUntil = t + 0.8
                after(60.0) { sound.play("annoyed") }
            }
        }
    }

    fun emit(type: ParticleType, count: Int) {
        for (i in 0 until count) {
            val isZ = type == ParticleType.Z
            _particles.add(Particle(
                type = type,
                x = (random.nextDouble() - 0.5) * 0.9 + (if (isZ) 0.55 else 0.0),
                y = -0.7 - random.nextDouble() * 0.2,
                vx = (random.nextDouble() - 0.5) * 0.35 + (if (isZ) 0.18 else 0.0),
                vy = -(0.45 + random.nextDouble() * 0.35),
                age = -i * 0.14,
                life = 1.3 + random.nextDouble() * 0.5,
                rot = random.nextDouble() * PI * 2,
                size = 0.15 + random.nextDouble() * 0.08,
            ))
        }
    }

    fun animateMorph(target: Double, durationMs: Double? = null) {
        val dur = durationMs ?: if (target > 0.5) 550.0 else 650.0
        anim(Prop.MORPH, keys(Triple(target, dur, Ease.inOut)))
    }

    /**
     * Dresses Mochi. Animated: the old outfit leaves (180 ms), the new one drops in (350 ms) and Mochi does a
     * little squash (BotEngine.setOutfit on the Mac, setOutfit in windows/src/mochi/engine.ts).
     */
    fun setOutfit(next: Outfit, animated: Boolean = true) {
        if (next == outfitTarget) return
        outfitTarget = next
        tweens.remove(Prop.OUTFIT_PRESENCE)
        locks.remove(Prop.OUTFIT_PRESENCE)
        val enter = {
            outfit = next
            anim(Prop.OUTFIT_PRESENCE, keys(Triple(1.0, 350.0, Ease.inOut))) { squash() }
        }
        if (!animated) {
            outfit = next
            outfitPresence = if (next != Outfit.NONE) 1.0 else 0.0
        } else if (next == Outfit.NONE) {
            anim(Prop.OUTFIT_PRESENCE, keys(Triple(0.0, 180.0, Ease.inOut))) { outfit = Outfit.NONE }
        } else if (outfit == Outfit.NONE) {
            outfitPresence = 0.0
            enter()
        } else {
            anim(Prop.OUTFIT_PRESENCE, keys(Triple(0.0, 180.0, Ease.inOut))) { enter() }
        }
    }

    /** Wearing something visible: the body then turns as one piece when it rolls. */
    val rigidRoll: Boolean get() = !isMini && outfit != Outfit.NONE && outfitPresence > 0.05

    /** True while anything is still moving, so the host can stop its frame loop. */
    val busy: Boolean
        get() = tweens.isNotEmpty() || scheduled.isNotEmpty() || _particles.isNotEmpty() ||
            cfg.bounces || cfg.scans || cfg.breathes || cfg.zz || cfg.sweat || isMini ||
            abs(tgYaw - yaw) > 0.002 || abs(tgPitch - pitch) > 0.002 || abs(tgTilt - tilt) > 0.002 ||
            abs(tgSy - sy) > 0.002 || abs(tgSx - sx) > 0.002 || abs(tgEs - es) > 0.002 ||
            slotH > 0.001 || abs(slotHVel) > 0.001 ||
            abs(col.r - colT.r) > 0.003 || abs(col.g - colT.g) > 0.003 || abs(col.b - colT.b) > 0.003 ||
            (outfit != Outfit.NONE && (abs(physVx) > 0.01 || abs(physVy) > 0.01))

    // ── Tweens ──────────────────────────────────────────────────────────────────

    fun anim(prop: Prop, keys: List<TweenKey>, onComplete: (() -> Unit)? = null) {
        tweens[prop] = Tween(prop, keys, 0, get(prop), clockMs(), onComplete)
        locks.add(prop)
    }

    // ── Update ──────────────────────────────────────────────────────────────────

    fun update(dt: Double) {
        val n = now()
        val nowMs = clockMs()

        // Timers that setTimeout handled in the TS port.
        if (scheduled.isNotEmpty()) {
            val due = scheduled.filter { it.dueMs <= nowMs }
            scheduled.removeAll(due.toSet())
            due.sortedBy { it.dueMs }.forEach { it.action() }
        }

        for (tw in ArrayList(tweens.values)) {
            val k = tw.keys[tw.index]
            val p = min(1.0, max(0.0, (nowMs - tw.startMs) / k.durationMs))
            set(tw.prop, tw.from + (k.target - tw.from) * k.ease(p))
            if (p >= 1) {
                tw.from = k.target
                tw.index += 1
                tw.startMs = nowMs
                if (tw.index >= tw.keys.size) {
                    tweens.remove(tw.prop)
                    locks.remove(tw.prop)
                    tw.onComplete?.invoke()
                }
            }
        }

        val t = n - t0
        var ty = lookX * 0.62
        var tp = lookY * 0.5

        cfg.look?.let { (lx, ly) ->
            ty = ty * 0.35 + lx * 0.55
            tp = tp * 0.3 + ly * 0.5
        }
        if (cfg.scans) {
            ty = sin(t * 2.6) * 0.6
            tp = -0.06
        }
        if (state == BotState.SLEEPING) { ty = 0.0; tp = -0.14 }
        if (state == BotState.DIZZY) ty = sin(t * 9) * 0.25

        // Mini bots never follow the pointer; they wander.
        if (isMini && cfg.look == null && !cfg.scans && state != BotState.SLEEPING && state != BotState.DIZZY) {
            if (n > miniLookNextTime) {
                miniLookX = -0.88 + random.nextDouble() * 1.76
                miniLookY = -0.55 + random.nextDouble() * 1.0
                miniLookNextTime = n + 0.5 + random.nextDouble() * 1.5
            }
            ty = miniLookX * 0.62
            tp = miniLookY * 0.5
        }

        tgYaw = ty
        tgPitch = tp
        tgTilt = cfg.tilt

        if (n > waveStart && n < waveUntil) {
            val wt = n - waveStart
            tgTilt = -0.06 + sin(2 * PI * 1.2 * wt) * 0.07
        }

        val bounce = if (cfg.bounces) -abs(sin(t * 5.2)) * 0.07 else 0.0
        val kGen = 1 - 0.0008.pow(dt)
        if (Prop.OY !in locks) oy += (bounce - oy) * kGen

        if (cfg.breathes) {
            val amp = if (isMini) 0.07 else 0.035
            tgSy = 1 + sin(t * 1.8) * amp
            tgSx = 1 - sin(t * 1.8) * amp * 0.57
        } else if (isMini) {
            tgSy = 1 + sin(t * 2.2) * 0.04
            tgSx = 1 - sin(t * 2.2) * 0.02
        } else {
            tgSy = 1.0
            tgSx = 1.0
        }

        if (isMini && n > miniNextBehavior) doMiniBehaviorLoop()

        val kLook = 1 - 0.0025.pow(dt)
        if (Prop.YAW !in locks) yaw += (tgYaw - yaw) * kLook
        if (Prop.PITCH !in locks) pitch += (tgPitch - pitch) * kLook
        if (Prop.TILT !in locks) tilt += (tgTilt - tilt) * kGen
        if (Prop.SY !in locks) sy += (tgSy - sy) * kGen
        if (Prop.SX !in locks) sx += (tgSx - sx) * kGen
        if (Prop.ES !in locks) es += (tgEs - es) * kGen

        col = col.mix(colT, 1 - 0.002.pow(dt))

        if (n > nextBlink) {
            if (state != BotState.SLEEPING && state != BotState.DIZZY) {
                blink()
                if (random.nextDouble() < 0.22) after(230.0) { blink() }
            }
            nextBlink = n + 2.2 + random.nextDouble() * 3.2
        }

        if (eyeOverride != null && n > eyeOverrideUntil) {
            eyeOverride = permanentEye
            if (permanentEye != null) eyeOverrideUntil = Double.POSITIVE_INFINITY
        }

        if (n - lastAmbient > 1.3) {
            lastAmbient = n
            if (cfg.zz) emit(ParticleType.Z, 1)
            if (!isMini && cfg.sweat && random.nextDouble() < 0.5) emit(ParticleType.SWEAT, 1)
        }

        _particles.forEach { it.age += dt }
        _particles = ArrayList(_particles.filter { it.age < it.life })

        // Mouth slot spring: w0 = 2*pi/0.25, zeta = 0.6
        val omega = (2 * PI) / 0.25
        val zeta = 0.6
        val acc = omega * omega * (slotHTarget - slotH) - 2 * zeta * omega * slotHVel
        slotHVel += acc * dt
        slotH = max(0.0, slotH + slotHVel * dt)

        // Soft-part spring: lags behind head turns, hops and rolls (stiffness 60, damping 9).
        if (dt > 0) {
            val yawVel = (yaw - prevYaw) / dt
            val oyVel = (oy - prevOy) / dt
            // A finished roll snaps from 2*pi*turns back to 0: that jump is not motion.
            val dRoll = roll - prevRoll
            val rollVel = if (abs(dRoll) > PI) 0.0 else dRoll / dt
            val centrifugal = if (rigidRoll) rollVel * 0.18 else 0.0
            val tDx = (-yawVel * 0.35 - tilt * 2 + centrifugal).coerceIn(-1.0, 1.0)
            val tDy = (oyVel * 0.5).coerceIn(-1.0, 1.0)
            physVx += (60 * (tDx - physDx) - 9 * physVx) * dt
            physVy += (60 * (tDy - physDy) - 9 * physVy) * dt
            physDx += physVx * dt
            physDy += physVy * dt
        }
        prevYaw = yaw
        prevOy = oy
        prevRoll = roll
    }

    private fun doMiniBehaviorLoop() {
        val n = now()
        when (permanentEmote) {
            BotEmote.HAPPY -> {
                if (Prop.OY in locks) { miniNextBehavior = n + 0.4; return }
                anim(Prop.OY, keys(Triple(-0.3, 120.0, Ease.out), Triple(0.03, 200.0, Ease.inOut), Triple(0.0, 160.0, Ease.back)))
                anim(Prop.SY, keys(
                    Triple(0.82, 80.0, Ease.out), Triple(1.18, 130.0, Ease.out),
                    Triple(0.88, 160.0, Ease.inOut), Triple(1.0, 200.0, Ease.back),
                ))
                anim(Prop.SX, keys(
                    Triple(1.15, 80.0, Ease.out), Triple(0.88, 130.0, Ease.out),
                    Triple(1.06, 160.0, Ease.inOut), Triple(1.0, 200.0, Ease.back),
                ))
                miniNextBehavior = n + 2.2 + random.nextDouble() * 1.2
            }
            BotEmote.ANNOYED -> {
                if (Prop.YAW in locks) { miniNextBehavior = n + 0.5; return }
                anim(Prop.YAW, keys(
                    Triple(-0.65, 50.0, Ease.out), Triple(0.65, 90.0, Ease.inOut), Triple(-0.5, 80.0, Ease.inOut),
                    Triple(0.4, 75.0, Ease.inOut), Triple(-0.2, 70.0, Ease.inOut), Triple(0.0, 140.0, Ease.out),
                ))
                miniNextBehavior = n + 3.0 + random.nextDouble() * 2.5
            }
            BotEmote.WINK -> {
                eyeOverride = EyeShape.WINK
                eyeOverrideUntil = n + 0.55
                anim(Prop.TILT, keys(Triple(0.13, 100.0, Ease.out), Triple(0.13, 320.0, Ease.lin), Triple(0.0, 200.0, Ease.inOut)))
                miniNextBehavior = n + 2.2 + random.nextDouble() * 2.0
            }
            BotEmote.LOVE -> {
                emit(ParticleType.HEART, 2)
                anim(Prop.TILT, keys(Triple(-0.1, 180.0, Ease.out), Triple(0.1, 340.0, Ease.inOut), Triple(0.0, 220.0, Ease.inOut)))
                miniNextBehavior = n + 2.6 + random.nextDouble() * 1.5
            }
            else -> miniNextBehavior = n + 3.0 + random.nextDouble() * 2.0
        }
    }
}
