package fr.louisraille.coucou.phone

import android.content.Context

/**
 * Pairing credentials — {worker, id, secret, deviceName, deviceId} — plus the
 * push token the relay last accepted. The secret is a bearer token that can
 * approve permissions on the PC, so it is kept sealed with the Android Keystore
 * (SecretBox.kt); the box only ever stores its SHA-256 (relay/src/index.ts).
 */
object Prefs {
    private const val FILE = "coucou"
    private const val K_WORKER = "worker"
    private const val K_ID = "id"
    private const val K_SECRET = "secret"
    private const val K_NAME = "device_name"
    private const val K_DEVICE_ID = "device_id"
    private const val K_CLAIMED_TOKEN = "claimed_token"
    private const val K_OUTFIT = "mochi_outfit"

    class Pairing(
        val worker: String,
        val id: String,
        val secret: String,
        val deviceName: String,
        val deviceId: String,
    )

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun load(ctx: Context): Pairing? {
        val p = sp(ctx)
        val worker = p.getString(K_WORKER, null) ?: return null
        val id = p.getString(K_ID, null) ?: return null
        val (secret, rewrite) = SecretCodec.read(p.getString(K_SECRET, null), KeystoreSealer)
        if (rewrite != null) p.edit().putString(K_SECRET, rewrite).apply()
        if (secret == null) return null // cannot be opened any more: pair again
        // A pairing made before device ids existed gets one now; the relay
        // takes it with the next claim.
        val deviceId = p.getString(K_DEVICE_ID, null)
            ?: DeviceId.new().also { p.edit().putString(K_DEVICE_ID, it).apply() }
        return Pairing(worker, id, secret, p.getString(K_NAME, null) ?: "Android", deviceId)
    }

    fun save(ctx: Context, pairing: Pairing) {
        sp(ctx).edit()
            .putString(K_WORKER, pairing.worker)
            .putString(K_ID, pairing.id)
            .putString(K_SECRET, SecretCodec.write(pairing.secret, KeystoreSealer))
            .putString(K_NAME, pairing.deviceName)
            .putString(K_DEVICE_ID, pairing.deviceId)
            .apply()
    }

    fun claimedToken(ctx: Context): String? = sp(ctx).getString(K_CLAIMED_TOKEN, null)

    fun setClaimedToken(ctx: Context, token: String) {
        sp(ctx).edit().putString(K_CLAIMED_TOKEN, token).apply()
    }

    /** Mochi's wardrobe pick: "auto" or an outfit id (Wardrobe.SELECTIONS). */
    fun outfit(ctx: Context): String = sp(ctx).getString(K_OUTFIT, null) ?: "auto"

    fun setOutfit(ctx: Context, selection: String) {
        sp(ctx).edit().putString(K_OUTFIT, selection).apply()
    }

    fun clear(ctx: Context) = sp(ctx).edit().clear().apply()
}
