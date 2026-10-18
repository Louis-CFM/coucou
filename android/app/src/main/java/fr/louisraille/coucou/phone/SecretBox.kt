package fr.louisraille.coucou.phone

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Turns a secret into what may sit in SharedPreferences, and back. */
interface Sealer {
    fun seal(plain: String): String

    /** Null when it cannot be opened (the key is gone): the phone pairs again. */
    fun open(sealed: String): String?
}

/**
 * AES-256-GCM with a key that never leaves the Android Keystore: the relay
 * secret can approve permissions on the PC, so it is not kept as plain text.
 */
object KeystoreSealer : Sealer {
    private const val ALIAS = "coucou-pairing"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun seal(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val data = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(data, Base64.NO_WRAP)
    }

    override fun open(sealed: String): String? = runCatching {
        val (iv, data) = sealed.split(':', limit = 2).let { it[0] to it[1] }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8)
    }.getOrNull()
}

/** The stored form of the secret: `ks1:` + what the sealer made of it. */
object SecretCodec {
    private const val PREFIX = "ks1:"

    fun write(secret: String, sealer: Sealer): String = PREFIX + sealer.seal(secret)

    /**
     * The secret from what is stored, and what to store instead when it was
     * still plain text (a pairing made by an older build): (secret, rewrite).
     */
    fun read(stored: String?, sealer: Sealer): Pair<String?, String?> = when {
        stored == null -> null to null
        stored.startsWith(PREFIX) -> sealer.open(stored.removePrefix(PREFIX)) to null
        else -> stored to write(stored, sealer)
    }
}
