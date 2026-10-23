package com.coucou.android

import com.coucou.android.core.LaunchScreen
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The launcher shortcuts (long-press the icon): each one only opens a screen of the closed [LaunchScreen] list, through LaunchActivity
 * (ours, not exported). They never carry a session, a fingerprint or an Allow, and MainActivity still reads no extras.
 */
class ShortcutsTest {
    private val ns = "http://schemas.android.com/apk/res/android"
    private val res = "src/main/res/"
    private fun read(p: String) = File(p).readText()

    private class Shortcut(val id: String, val icon: String, val short: String, val long: String, val target: String, val extras: Map<String, String>)

    private val shortcuts: List<Shortcut> by lazy {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(File(res + "xml/shortcuts.xml"))
        val list = doc.getElementsByTagName("shortcut")
        (0 until list.length).map { i ->
            val e = list.item(i) as Element
            val intent = e.getElementsByTagName("intent").item(0) as Element
            val extras = intent.getElementsByTagName("extra")
            Shortcut(
                e.getAttributeNS(ns, "shortcutId"), e.getAttributeNS(ns, "icon"), e.getAttributeNS(ns, "shortcutShortLabel"),
                e.getAttributeNS(ns, "shortcutLongLabel"), intent.getAttributeNS(ns, "targetClass"),
                (0 until extras.length).associate { j -> (extras.item(j) as Element).let { it.getAttributeNS(ns, "name") to it.getAttributeNS(ns, "value") } },
            )
        }
    }

    @Test fun thereAreThreeAndTheLauncherShowsAtLeastFour() {
        assertEquals(listOf("chat", "recent", "pair"), shortcuts.map { it.id })
        assertTrue(shortcuts.size <= 4)
        assertEquals(shortcuts.size, shortcuts.map { it.id }.toSet().size)
    }

    @Test fun eachOneOpensAScreenOfTheClosedListAndNothingElse() {
        for (s in shortcuts) {
            assertEquals(s.id, "com.coucou.android.app.LaunchActivity", s.target)
            assertEquals(s.id, setOf("screen"), s.extras.keys)
            val screen = LaunchScreen.parse(s.extras.getValue("screen"))
            assertTrue("${s.id}: ${s.extras} is not in the closed list", screen != null)
        }
        assertEquals(listOf(LaunchScreen.CHAT, LaunchScreen.RECENT, LaunchScreen.PAIR), shortcuts.map { LaunchScreen.parse(it.extras["screen"]) })
    }

    @Test fun noShortcutCanDecideOrOpenASession() {
        val xml = read(res + "xml/shortcuts.xml")
        for (word in listOf("session", "fingerprint", "allow", "fp", "decide", "deny")) {
            assertFalse("shortcuts.xml mentions $word", Regex("""android:name="$word"""", RegexOption.IGNORE_CASE).containsMatchIn(xml))
        }
        assertFalse(xml.contains("MainActivity"))
    }

    @Test fun theLaunchActivityStaysPrivateAndIsTheOnlyTarget() {
        val m = read("src/main/AndroidManifest.xml")
        assertTrue(m.substringAfter("""android:name=".app.LaunchActivity"""").substringBefore("/>").contains("""android:exported="false""""))
        assertTrue(m.contains("""android:name="android.app.shortcuts" android:resource="@xml/shortcuts""""))
        // The shortcuts are declared on the launcher activity.
        assertTrue(m.substringAfter("""android:name=".MainActivity"""").substringBefore("</activity>").contains("@xml/shortcuts"))
    }

    @Test fun everyLabelAndIconExistsAndFitsTheLauncher() {
        val strings = Regex("""<string name="(\w+)">(.*?)</string>""").findAll(read(res + "values/strings.xml")).associate { it.groupValues[1] to it.groupValues[2] }
        for (s in shortcuts) {
            val short = strings.getValue(s.short.removePrefix("@string/"))
            val long = strings.getValue(s.long.removePrefix("@string/"))
            assertTrue("${s.id}: the short label '$short' is long", short.length <= 12)
            assertTrue("${s.id}: the long label '$long' is long", long.length <= 40)
            assertTrue(File(res + "drawable/" + s.icon.removePrefix("@drawable/") + ".xml").exists())
        }
    }

    @Test fun everyLanguageTranslatesTheLabels() {
        for (f in File("../i18n/translations").listFiles()!!.filter { it.extension == "json" }) {
            val text = f.readText()
            for (k in listOf("shortcut_chat_short", "shortcut_chat_long", "shortcut_recent_short", "shortcut_recent_long", "shortcut_pair_short", "shortcut_pair_long")) {
                assertTrue("${f.name} lacks $k", text.contains("\"$k\""))
            }
        }
    }
}
