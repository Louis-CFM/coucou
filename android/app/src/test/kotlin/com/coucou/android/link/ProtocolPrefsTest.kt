package com.coucou.android.link

import com.coucou.android.mochi.outfit.Wardrobe
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolPrefsTest {
    @Test fun everyWardrobeValueIsRead() {
        for (v in Wardrobe.SELECTIONS) {
            assertEquals(ServerMsg.Prefs(v), Wire.decodeServer("""{"type":"prefs","outfit":"$v"}"""))
        }
    }

    @Test fun aValueThisBuildDoesNotKnowIsDroppedNotGuessed() {
        for (bad in listOf("topHat", "", "Beanie", "beanie ", "../x")) {
            assertNull(bad, Wire.decodeServer("""{"type":"prefs","outfit":"$bad"}"""))
        }
        assertNull(Wire.decodeServer("""{"type":"prefs"}"""))
        assertNull(Wire.decodeServer("""{"type":"prefs","outfit":5}"""))
        assertNull(Wire.decodeServer("""{"type":"prefs","outfit":null}"""))
    }

    @Test fun theHelloAsksForPrefs() {
        assertTrue(Protocol.CAP_PREFS in Protocol.CAPABILITIES)
        val o = JSONObject(Wire.encode(ClientMsg.Hello(1, "T".repeat(20), "Phone", Protocol.CAPABILITIES)))
        assertTrue(o.getJSONArray("caps").toString().contains("prefs"))
    }

    @Test fun nothingIsSentBackAboutIt() {
        assertFalse(Wire.encode(ClientMsg.Ping).contains("prefs"))
    }
}
