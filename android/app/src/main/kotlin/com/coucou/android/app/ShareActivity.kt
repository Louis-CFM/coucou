package com.coucou.android.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.coucou.android.MainActivity
import com.coucou.android.R
import com.coucou.android.core.ShareDraft

/**
 * "Share to Coucou": a text shared from another app opens the chat with the text in the box. It is exported (that is how the share sheet finds
 * it), so it treats what it gets as plain typed text: one string, cleaned and cut by [ShareDraft.clean], put in the box and never sent. It hands
 * the draft to the app inside the process (the main screen opens on Chat while a draft waits) and opens MainActivity with a plain intent; it does not
 * use the slots of LaunchActivity, which only that private activity may fill. Pictures, files and
 * links to other content are not accepted, only text/plain.
 */
class ShareActivity : Activity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val model = (application as CoucouApp).model
        val shared = intent
        val text = if (shared?.action == Intent.ACTION_SEND && shared.type?.startsWith("text/plain") == true) {
            // A malformed extra from another app must not crash us.
            runCatching { shared.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() }.getOrNull()
        } else {
            null
        }
        val clean = ShareDraft.clean(text)
        when (ShareDraft.decide(clean != null, model.chatTabState)) {
            ShareDraft.Outcome.KEEP_AND_OPEN_CHAT -> {
                model.offerShare(clean)
                startActivity(
                    Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                )
            }
            ShareDraft.Outcome.NOT_PAIRED -> Toast.makeText(this, R.string.share_not_paired, Toast.LENGTH_LONG).show()
            ShareDraft.Outcome.CHAT_UNAVAILABLE -> Toast.makeText(this, R.string.share_chat_off, Toast.LENGTH_LONG).show()
            ShareDraft.Outcome.NOTHING_TO_SHARE -> {}
        }
        finish()
    }
}
