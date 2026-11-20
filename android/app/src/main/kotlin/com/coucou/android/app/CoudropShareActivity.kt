package com.coucou.android.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import com.coucou.android.MainActivity
import com.coucou.android.link.LinkState

/**
 * Android system share sheet handler for Coudrop.
 * Receives ACTION_SEND or ACTION_SEND_MULTIPLE for files, images, docs,
 * and streams them directly to the paired desktop over the TLS link.
 */
class CoudropShareActivity : Activity() {
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as CoucouApp
        val model = app.model
        val sharedIntent = intent

        val uris = mutableListOf<Uri>()

        if (sharedIntent != null) {
            val action = sharedIntent.action
            if (Intent.ACTION_SEND == action) {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    sharedIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    sharedIntent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) {
                    uris.add(uri)
                }
            } else if (Intent.ACTION_SEND_MULTIPLE == action) {
                val list: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    sharedIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    sharedIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (list != null) {
                    uris.addAll(list)
                }
            }

            // Fallback to ClipData
            if (uris.isEmpty() && sharedIntent.clipData != null) {
                val clip = sharedIntent.clipData
                if (clip != null) {
                    for (i in 0 until clip.itemCount) {
                        clip.getItemAt(i).uri?.let { uris.add(it) }
                    }
                }
            }
        }

        if (uris.isEmpty()) {
            Toast.makeText(this, "No files selected to share", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        if (model.linkState == LinkState.CONNECTED) {
            model.coudropManager.sendUris(uris)
            Toast.makeText(this, "Sending to ${model.desktopName ?: "computer"}...", Toast.LENGTH_SHORT).show()
            val mainIntent = Intent(this, MainActivity::class.java)
                .putExtra("screen", "coudrop")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            startActivity(mainIntent)
        } else {
            Toast.makeText(this, "Computer offline. Open Coucou on your PC first.", Toast.LENGTH_LONG).show()
            val mainIntent = Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            startActivity(mainIntent)
        }

        finish()
    }
}
