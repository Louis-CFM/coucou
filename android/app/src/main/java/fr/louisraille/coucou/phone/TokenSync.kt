package fr.louisraille.coucou.phone

import java.security.SecureRandom

/**
 * This phone's id on the relay, made once per pairing: a paired box only takes
 * a new push token from the phone that claimed it (relay DEVICE_RE).
 */
object DeviceId {
    fun new(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(16).also { random.nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

/** When the relay must hear about this phone's FCM token. */
object TokenSync {
    /** The current token differs from the last one a claim got through with. */
    fun shouldClaim(lastClaimed: String?, current: String?): Boolean =
        !current.isNullOrBlank() && current != lastClaimed
}
