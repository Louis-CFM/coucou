package com.coucou.android.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.coucou.android.MainActivity
import com.coucou.android.core.LaunchScreen

/**
 * Where our own notification actions, the island's Allow and the widget rows and buttons land. It is not exported, so no other app can start it;
 * it passes the request to the app inside the process ([PendingLaunch]) and opens MainActivity with a plain intent.
 */
class LaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val model = (application as CoucouApp).model
        val session = intent.getStringExtra(EXTRA_SESSION)
        // A widget row asks for a session to open, a widget button for a screen of the closed list, a notification for an
        // Allow. Each has its own slot, and one never clears the other. A screen that is not in the list is ignored: the
        // app just opens.
        when {
            session != null -> model.launch.requestSession(session)
            intent.hasExtra(EXTRA_SCREEN) -> LaunchScreen.parse(intent.getStringExtra(EXTRA_SCREEN))?.let { model.launch.requestScreen(it) }
            else -> model.launch.request(intent.getStringExtra(Notifications.EXTRA_FP), intent.getBooleanExtra(Notifications.EXTRA_ALLOW, false))
        }
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        finish()
    }

    companion object {
        /** The pill id of the session a widget row opens. */
        const val EXTRA_SESSION = "session"

        /** The key of the [LaunchScreen] a widget button opens. */
        const val EXTRA_SCREEN = "screen"
    }
}
