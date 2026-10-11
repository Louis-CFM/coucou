package com.coucou.android.core

/**
 * The licence texts the app shows (Settings > About > Licences). They are files under assets/licenses so the exact words ship in the app:
 * NOTICES (who owns what, and the libraries), then the MIT text of Coucou's code, then the Apache 2.0 text.
 */
object Licences {
    /** In the order they are shown. */
    val FILES = listOf("NOTICES.txt", "MIT.txt", "Apache-2.0.txt")

    /** The text cut into blocks at blank lines, so a long licence is a list the screen can scroll without laying it all out at once. */
    fun paragraphs(text: String): List<String> =
        text.replace("\r\n", "\n").split(Regex("\n\\s*\n")).map { it.trim('\n') }.filter { it.isNotBlank() }
}
