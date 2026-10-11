package com.coucou.android.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.coucou.android.MainActivity

/**
 * Where our own notification actions and the island's Allow land. It is not exported, so no other app can start it;
 * it passes the request to the app inside the process ([PendingLaunch]) and opens MainActivity with a plain intent.
 */
class LaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val model = (application as CoucouApp).model
        model.launch.request(intent.getStringExtra(Notifications.EXTRA_FP), intent.getBooleanExtra(Notifications.EXTRA_ALLOW, false))
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        finish()
    }
}
