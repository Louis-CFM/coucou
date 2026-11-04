package com.coucou.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source guards for the Team widget and its choice screen (Android classes only compile in CI). */
class TeamWidgetSourceTest {
    private val main = "src/main/kotlin/com/coucou/android/"
    private fun read(p: String) = File(p).readText()
    private val config = read(main + "app/TeamConfigActivity.kt")
    private val widget = read(main + "app/TeamWidget.kt")
    private val store = read(main + "app/TeamStore.kt")
    private val info = read("src/main/res/xml/coucou_team_widget_info.xml")
    private val manifest = read("src/main/AndroidManifest.xml")

    @Test fun theProviderLetsTheUserSkipTheChoiceAndChangeItLater() {
        assertTrue(info.contains("""android:widgetFeatures="configuration_optional|reconfigurable""""))
        assertTrue(info.contains("""android:configure="com.coucou.android.app.TeamConfigActivity""""))
        assertTrue(info.contains("""android:updatePeriodMillis="0""""))
        assertTrue(info.contains("""android:targetCellWidth="4"""") && info.contains("""android:targetCellHeight="2""""))
        // Three cells wide at the least.
        assertTrue(Regex("""minResizeWidth="(\d+)dp"""").find(info)!!.groupValues[1].toInt() >= 180)
    }

    @Test fun theChoiceScreenAnswersTheLauncherAndTrustsNothing() {
        val block = manifest.substringAfter("""android:name=".app.TeamConfigActivity"""").substringBefore("</activity>")
        assertTrue(block.contains("""android:exported="true""""))
        assertTrue(block.contains("android.appwidget.action.APPWIDGET_CONFIGURE"))
        // Canceled until Save; the id must be a Team widget of this home screen; a malformed extra does not crash it.
        assertTrue(config.contains("setResult(Activity.RESULT_CANCELED)"))
        assertTrue(config.contains("getAppWidgetIds(ComponentName(this, TeamWidget::class.java))"))
        assertTrue(config.contains("widgetId !in mine"))
        assertTrue(config.contains("runCatching { intent?.getIntExtra"))
        assertEquals("one Save, one OK", 1, Regex("RESULT_OK").findAll(config).count())
        // It stores a choice and redraws; it reads no other extra, starts nothing and sends nothing.
        for (word in listOf("startActivity", "sendBroadcast", "getStringExtra", "getParcelableExtra", "getStringArrayExtra", "link.", "model.send")) assertFalse(word, config.contains(word))
    }

    @Test fun theChoiceIsPerWidgetKeptOnThePhoneAndGoesWithTheWidget() {
        assertTrue(store.contains("getSharedPreferences(\"widget_team\""))
        assertTrue(store.contains("TeamChoice.decode(") && store.contains("TeamChoice.encode("))
        assertTrue(widget.contains("override fun onDeleted") && widget.contains("TeamStore(context).remove(ids)"))
        // Nothing is backed up.
        assertTrue(read("src/main/res/xml/data_extraction_rules.xml").contains("""<exclude domain="sharedpref" />"""))
    }

    @Test fun theWidgetOnlyOpensThingsThroughTheHub() {
        assertTrue(widget.contains("WidgetHub.openSession("))
        assertTrue(widget.contains("WidgetHub.openApp("))
        assertFalse(widget.contains("PendingIntent.get"))
        assertFalse(widget.contains("LaunchScreen"))
        // A copy is drawn from its own choice.
        assertTrue(widget.contains("TeamStore(context).get(widgetId)"))
        assertTrue(read(main + "app/WidgetHub.kt").contains("Kind(TeamWidget::class.java, each ="))
    }

    @Test fun theLayoutShowsFourCellsAndAnEmptyState() {
        val layout = read("src/main/res/layout/widget_team.xml")
        for (i in 0..3) for (part in listOf("cell", "face", "name", "dot", "state")) assertTrue("team_$part$i", layout.contains("@+id/team_$part$i"))
        for (id in listOf("team_root", "team_tint", "team_grid", "team_empty", "team_empty_face", "team_empty_title", "team_empty_line")) assertTrue(id, layout.contains("@+id/$id"))
        assertFalse(layout.contains("Button"))
    }
}
