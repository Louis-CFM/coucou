package com.coucou.android.app

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.coucou.android.ui.CoucouTheme
import com.coucou.android.ui.TeamConfigScreen

/**
 * Where the user picks the agents of a Team widget: when the widget is added, and from its long-press menu (reconfigure). The launcher starts
 * it, so it is exported; it therefore trusts nothing it is given. It works only on a widget id that belongs to a Team widget on this home
 * screen, and the only thing it can do is store a choice of catalog agents ([TeamStore] drops anything else). It answers CANCELED until the user
 * taps Save, so backing out never adds the widget by accident.
 */
class TeamConfigActivity : ComponentActivity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(Activity.RESULT_CANCELED)
        widgetId = runCatching { intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID) }.getOrNull()
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        val mine = AppWidgetManager.getInstance(this).getAppWidgetIds(ComponentName(this, TeamWidget::class.java))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID || widgetId !in mine) {
            finish()
            return
        }
        val model = (application as CoucouApp).model
        val store = TeamStore(this)
        enableEdgeToEdge()
        setContent {
            CoucouTheme(model.settings.theme, model.settings.dynamicColour) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    TeamConfigScreen(Modifier.windowInsetsPadding(WindowInsets.safeDrawing), store.get(widgetId)) { chosen ->
                        store.set(widgetId, chosen)
                        WidgetHub.refreshAll(this@TeamConfigActivity)
                        setResult(Activity.RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
                        finish()
                    }
                }
            }
        }
    }
}
