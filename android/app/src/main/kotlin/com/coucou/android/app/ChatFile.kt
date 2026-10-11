package com.coucou.android.app

import com.coucou.android.core.TextFile
import java.io.File

/**
 * The chat history file, in the app's private storage (not backed up: allowBackup is off). Written
 * to a temporary file first so a crash never leaves half a history.
 */
class ChatFile(private val file: File) : TextFile {
    override fun read(): String? = try { if (file.isFile) file.readText() else null } catch (_: Exception) { null }

    override fun write(text: String) {
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) { file.writeText(text); tmp.delete() }
        } catch (_: Exception) {
            // A history that cannot be saved is not worth stopping the chat for.
        }
    }

    override fun delete() { runCatching { file.delete() } }
}
