package com.coucou.android.core

/**
 * What may be shown about a command or a step on a surface that can be seen without a deliberate tap (Home, the
 * island, notifications, cards, the lock screen): a short label and at most the program's name. Never an argument, a
 * flag, an environment variable, a path, a URL or anything that could hold a secret. The full command exists only on
 * the approval sheet behind "Show exact command" and in the lock prompt that follows a deliberate tap on Allow.
 */
object SafeText {
    const val PROGRAM_MAX = 20

    private val PROGRAM_CHARS = Regex("[A-Za-z0-9._+-]+")
    private val ENV_ASSIGNMENT = Regex("[A-Za-z_][A-Za-z0-9_]*=.*")

    /**
     * The first word of a command, if it is a plain program name: leading NAME=value words are skipped, a path is
     * reduced to its file name, flags and anything with unusual characters give null, at most [PROGRAM_MAX] characters.
     */
    fun program(command: String?): String? {
        val words = command.orEmpty().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        var i = 0
        while (i < words.size && ENV_ASSIGNMENT.matches(words[i])) i++ // FOO=bar TOKEN=x npm test: the variables are never shown
        var word = words.getOrNull(i) ?: return null
        word = word.trim('"', '\'', '`', '(', ')', '{', '}')
        if (word.isEmpty() || word.startsWith("-") || word.contains("://") || word.contains('@') || word.contains('=')) return null
        word = word.substringAfterLast('/').substringAfterLast('\\') // "no paths": only the file name
        if (word.isEmpty() || word.startsWith("-") || !PROGRAM_CHARS.matches(word)) return null
        return word.take(PROGRAM_MAX)
    }

    private val SHELLS = setOf("bash", "shell", "runshellcommand", "execcommand", "exec", "sh", "terminal", "powershell", "cmd")

    private fun isShell(tool: String) = tool.lowercase().filter { it.isLetterOrDigit() } in SHELLS

    /** "Running a command · npm" for a shell tool, "Editing files" for the others: the label of a request. */
    fun requestLabel(tool: String, command: String?): String {
        val label = ToolLabels.label(tool).ifEmpty { "Working" }
        val program = if (isShell(tool)) program(command) else null
        return if (program != null) "$label · $program" else label
    }

    /**
     * Prose the agent wrote (its last message) for a surface that is not behind a tap: every word that looks like a
     * path, a URL, an address with a user name, a NAME=value pair or a long token is replaced with an ellipsis.
     */
    fun prose(text: String): String {
        val kept = text.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.map { word ->
            val core = word.trim('.', ',', ';', ':', '!', '?', '"', '\'', '(', ')', '[', ']')
            when {
                core.contains('/') || core.contains('\\') || core.contains("://") || core.contains('@') -> "…"
                core.contains('=') -> "…"
                core.length > 32 -> "…"
                Regex("[A-Za-z]:\\\\.*").matches(core) -> "…"
                else -> word
            }
        }
        // "… … …" says nothing: collapse runs of ellipses.
        val out = ArrayList<String>()
        for (w in kept) if (!(w == "…" && out.lastOrNull() == "…")) out.add(w)
        return out.joinToString(" ")
    }
}
