package com.coucou.android.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.coucou.android.link.PairingPayload
import com.coucou.android.link.PairingCodec
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps the pairing (which holds the secret token) encrypted with an AES-GCM key that never
 * leaves the Android Keystore. Backups are off (allowBackup=false), so it stays on this device.
 */
class SecureStore(context: Context) {
    private val prefs = context.getSharedPreferences("coucou_link", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    fun savePairing(p: PairingPayload) {
        // K and the relay's access key are inside the same Keystore-encrypted blob as the token: never in clear on the disk.
        val plain = PairingCodec.encode(p)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(PREF, Base64.encodeToString(c.iv + ct, Base64.NO_WRAP)).apply()
    }

    fun loadPairing(): PairingPayload? {
        val blob = prefs.getString(PREF, null) ?: return null
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, IV_BYTES))
            }
            PairingCodec.decode(String(c.doFinal(raw, IV_BYTES, raw.size - IV_BYTES), Charsets.UTF_8)) ?: error("unreadable pairing")
        } catch (_: Exception) {
            clearPairing() // unreadable (key lost, corrupted): start clean instead of crashing
            null
        }
    }

    fun clearPairing() = prefs.edit().remove(PREF).apply()

    private companion object {
        const val ALIAS = "coucou_pairing_key"
        const val PREF = "pairing"
        const val IV_BYTES = 12
    }
}
