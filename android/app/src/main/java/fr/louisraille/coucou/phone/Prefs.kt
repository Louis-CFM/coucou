package fr.louisraille.coucou.phone

import android.content.Context

/**
 * Pairing credentials — {worker, id, secret, deviceName} — kept in plain
 * SharedPreferences on purpose: the secret is a bearer token the user pasted
 * from the PC itself, the app holds no account and nothing else derives from
 * it. The box only ever stores its SHA-256 (see relay/src/index.ts).
 */
object Prefs {
    private const val FILE = "coucou"
    private const val K_WORKER = "worker"
    private const val K_ID = "id"
    private const val K_SECRET = "secret"
    private const val K_NAME = "device_name"

    class Pairing(
        val worker: String,
        val id: String,
        val secret: String,
        val deviceName: String,
    )

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun load(ctx: Context): Pairing? {
        val p = sp(ctx)
        val worker = p.getString(K_WORKER, null) ?: return null
        val id = p.getString(K_ID, null) ?: return null
        val secret = p.getString(K_SECRET, null) ?: return null
        return Pairing(worker, id, secret, p.getString(K_NAME, null) ?: "Android")
    }

    fun save(ctx: Context, pairing: Pairing) {
        sp(ctx).edit()
            .putString(K_WORKER, pairing.worker)
            .putString(K_ID, pairing.id)
            .putString(K_SECRET, pairing.secret)
            .putString(K_NAME, pairing.deviceName)
            .apply()
    }

    fun clear(ctx: Context) = sp(ctx).edit().clear().apply()
}
