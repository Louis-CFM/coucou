package com.coucou.android.core

/**
 * What the agent is doing, in words a person reads. The desktop sends the last step as the agent
 * reported it, often a raw tool name ("ask_question", "Bash", "Read"). Known tools get a plain
 * sentence; an unknown one is only cleaned (no underscores, first letter capital); free text such
 * as "Running npm test" is left alone. Used by the Home card and the island, so both say the same.
 */
object ToolLabels {
    private val KNOWN = mapOf(
        "askuserquestion" to "Asking a question",
        "askquestion" to "Asking a question",
        "bash" to "Running a command",
        "shell" to "Running a command",
        "runshellcommand" to "Running a command",
        "execcommand" to "Running a command",
        "read" to "Reading files",
        "readfile" to "Reading files",
        "readmanyfiles" to "Reading files",
        "edit" to "Editing files",
        "multiedit" to "Editing files",
        "write" to "Editing files",
        "writefile" to "Editing files",
        "notebookedit" to "Editing files",
        "applypatch" to "Editing files",
        "grep" to "Searching files",
        "glob" to "Searching files",
        "ls" to "Looking at files",
        "websearch" to "Searching the web",
        "googlewebsearch" to "Searching the web",
        "webfetch" to "Reading a web page",
        "task" to "Running a sub-agent",
        "todowrite" to "Planning",
        "exitplanmode" to "Planning",
    )

    /** The same tools as an action after "wants to" or "Allowed:": "run a command", "edit files". */
    private val ACTIONS = mapOf(
        "askuserquestion" to "ask a question", "askquestion" to "ask a question",
        "bash" to "run a command", "shell" to "run a command", "runshellcommand" to "run a command", "execcommand" to "run a command",
        "read" to "read files", "readfile" to "read files", "readmanyfiles" to "read files",
        "edit" to "edit files", "multiedit" to "edit files", "write" to "edit files", "writefile" to "edit files",
        "notebookedit" to "edit files", "applypatch" to "edit files",
        "grep" to "search files", "glob" to "search files", "ls" to "look at files",
        "websearch" to "search the web", "googlewebsearch" to "search the web", "webfetch" to "read a web page",
        "task" to "run a sub-agent",
    )

    /** What a request is for, as an action ("run a command"); an unknown tool is cleaned and lower-cased. */
    fun action(tool: String): String {
        val name = tool.trim()
        if (name.isEmpty()) return "do something"
        return ACTIONS[key(name)] ?: clean(name).lowercase()
    }

    private const val SEP = " · "

    /** "ask_question" and "AskQuestion" both reduce to "askquestion". */
    private fun key(s: String) = s.lowercase().filter { it.isLetterOrDigit() }

    private fun looksLikeAName(s: String) = s.isNotEmpty() && s.all { it.isLetterOrDigit() || it == '_' || it == '-' || it == '.' || it == ':' }

    /**
     * The words for a step on a surface that is seen without a tap. The tool is named in plain words; of a shell
     * command only the program's name follows ([SafeText.program]); the file, the arguments and any free text the
     * agent wrote are never shown here. Free text that is not a tool name gives "" so the screen falls back to the
     * state's own word.
     */
    fun label(raw: String): String {
        val text = raw.trim().removeSuffix("·").trim()
        if (text.isEmpty()) return ""
        // "Bash · npm test": the tool is named, the rest is what it does (and stays out of sight).
        val at = text.indexOf(SEP)
        val head = if (at > 0) text.substring(0, at).trim() else text
        val rest = if (at > 0) text.substring(at + SEP.length).trim() else ""
        if (!looksLikeAName(head)) return ""
        // An unknown word shows only if it can be a tool's name: a key or a token pasted in its place never does.
        if (KNOWN[key(head)] == null && !plausibleToolName(head)) return ""
        val tool = KNOWN[key(head)] ?: clean(head)
        val program = if (rest.isNotEmpty()) SafeText.requestLabel(head, rest).substringAfter(SEP, "") else ""
        return if (program.isNotEmpty()) "$tool$SEP$program" else tool
    }

    private val DIGIT_RUN = Regex("[0-9]{3,}")

    private fun plausibleToolName(s: String): Boolean =
        s.length <= 40 && !DIGIT_RUN.containsMatchIn(s) && (s.length <= 24 || s.any { it == '_' || it == '-' || it == '.' || it == ':' })

    private val SEPARATORS = Regex("[_\\-.:]+")
    private val CAMEL = Regex("(?<=[a-z0-9])(?=[A-Z])")

    /** "mcp__github__list_issues" to "Mcp github list issues"; "FooBar" to "Foo bar". */
    fun clean(name: String): String =
        name.replace(SEPARATORS, " ").replace(CAMEL, " ").trim().lowercase().replaceFirstChar { it.uppercaseChar() }
}
