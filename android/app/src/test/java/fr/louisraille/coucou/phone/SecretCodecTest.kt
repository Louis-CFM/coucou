package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SecretCodecTest {
    /** Stands in for the Keystore: reversible, and visibly not the plain text. */
    private val fake = object : Sealer {
        override fun seal(plain: String) = plain.reversed()
        override fun open(sealed: String) = if (sealed == "broken") null else sealed.reversed()
    }

    @Test
    fun aSealedSecretReadsBackWithNothingToRewrite() {
        val stored = SecretCodec.write("f".repeat(64), fake)
        assertEquals("f".repeat(64) to null, SecretCodec.read(stored, fake))
    }

    @Test
    fun aPlainSecretFromAnOlderBuildIsReadAndMigrated() {
        val (secret, rewrite) = SecretCodec.read("abc123", fake)
        assertEquals("abc123", secret)
        assertEquals(SecretCodec.write("abc123", fake), rewrite)
    }

    @Test
    fun aSecretThatCannotBeOpenedMeansPairAgain() {
        assertEquals(null to null, SecretCodec.read("ks1:broken", fake))
        assertNull(SecretCodec.read(null, fake).first)
    }
}
