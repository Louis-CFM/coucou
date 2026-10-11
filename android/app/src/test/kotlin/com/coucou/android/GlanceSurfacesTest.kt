package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source guards for the widget, the tile and the ongoing notification (Compose and Android classes only compile in CI). */
class GlanceSurfacesTest {
    private fun read(path: String) = File(path).readText()
    private val manifest get() = read("src/main/AndroidManifest.xml")
    private val widget get() = read("src/main/kotlin/com/coucou/android/app/GlanceWidget.kt")
    private val tile get() = read("src/main/kotlin/com/coucou/android/app/GlanceTile.kt")
    private val notifications get() = read("src/main/kotlin/com/coucou/android/app/Notifications.kt")
    private val model get() = read("src/main/kotlin/com/coucou/android/app/AppModel.kt")

    @Test fun theWidgetAndTheTileAreRegistered() {
        assertTrue(manifest.contains("""android:name=".app.GlanceWidget""""))
        assertTrue(manifest.contains("android.appwidget.action.APPWIDGET_UPDATE"))
        assertTrue(manifest.contains("@xml/coucou_widget_info"))
        assertTrue(manifest.contains("""android:name=".app.GlanceTile""""))
        assertTrue(manifest.contains("""android:permission="android.permission.BIND_QUICK_SETTINGS_TILE""""))
        assertTrue(manifest.contains("android.service.quicksettings.action.QS_TILE"))
    }

    @Test fun theWidgetNeverWakesOnATimer() {
        val info = read("src/main/res/xml/coucou_widget_info.xml")
        assertTrue(info.contains("""android:updatePeriodMillis="0""""))
        assertTrue(info.contains("""android:widgetCategory="home_screen""""))
    }

    @Test fun noSurfaceAddsAnythingBeyondTheGlance() {
        // They draw the Glance and nothing else: no step text, no command, no final answer.
        for ((name, src) in listOf("widget" to widget, "tile" to tile)) {
            for (word in listOf("statusText", "finalLine", "steps", ".command", "files")) assertFalse("$name uses $word", src.contains(word))
        }
        assertFalse(notifications.substringAfter("private fun ongoing(g: Glance?)").substringBefore("fun updateOngoing").contains("statusText"))
    }

    @Test fun theOngoingNotificationIsPrivateOnTheLockScreen() {
        val body = notifications.substringAfter("private fun ongoing(g: Glance?)").substringBefore("fun updateOngoing")
        assertTrue(body.contains("VISIBILITY_PRIVATE"))
        assertTrue(body.contains("setPublicVersion"))
    }

    @Test fun theTileOnlyOpensTheApp() {
        assertTrue(tile.contains("startActivityAndCollapse"))
        for (word in listOf("decide", "allow", "answer", "unpair")) assertFalse("tile uses $word", tile.contains(word, ignoreCase = true))
    }

    @Test fun everyChangeOfThePictureReachesTheSurfaces() {
        assertTrue(model.substringAfter("private fun refreshIsland()").take(200).contains("pushGlance()"))
        val push = model.substringAfter("private fun pushGlance()").substringBefore("private fun refreshIsland()")
        for (call in listOf("notifier.updateOngoing", "GlanceWidget.update", "GlanceTile.requestUpdate")) assertTrue(call, push.contains(call))
    }
}
