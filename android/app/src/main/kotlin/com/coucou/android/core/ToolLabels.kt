package com.coucou.android.core

/**
 * What the agent is doing, in words a person reads. The desktop sends the last step as the agent
 * reported it, often a raw tool name ("ask_question", "Bash", "Read"). Known tools get a plain
 * sentence; an unknown one is only cleaned (no underscores, first letter capital); free text such
 * as "Running npm test" is left alone. Used by the Home card and the island, so both say the same.
 */
object ToolLabels {
    /** Tool name (lower case, no separators) to the key of its sentence; the English is in [KNOWN_ENGLISH]. */
    private val KNOWN = mapOf(
        "askuserquestion" to "tool_asking",
        "askquestion" to "tool_asking",
        "bash" to "tool_running",
        "shell" to "tool_running",
        "runshellcommand" to "tool_running",
        "execcommand" to "tool_running",
        "read" to "tool_reading",
        "readfile" to "tool_reading",
        "readmanyfiles" to "tool_reading",
        "edit" to "tool_editing",
        "multiedit" to "tool_editing",
        "write" to "tool_editing",
        "writefile" to "tool_editing",
        "notebookedit" to "tool_editing",
        "applypatch" to "tool_editing",
        "grep" to "tool_searching",
        "glob" to "tool_searching",
        "ls" to "tool_looking",
        "websearch" to "tool_web_search",
        "googlewebsearch" to "tool_web_search",
        "webfetch" to "tool_web_page",
        "task" to "tool_subagent",
        "todowrite" to "tool_planning",
        "exitplanmode" to "tool_planning",
    )

    /** The sentences, one per key; the same texts are in i18n/app-strings.json (a test keeps them in step). */
    private val KNOWN_ENGLISH = mapOf(
        "tool_asking" to "Asking a question",
        "tool_running" to "Running a command",
        "tool_reading" to "Reading files",
        "tool_editing" to "Editing files",
        "tool_searching" to "Searching files",
        "tool_looking" to "Looking at files",
        "tool_web_search" to "Searching the web",
        "tool_web_page" to "Reading a web page",
        "tool_subagent" to "Running a sub-agent",
        "tool_planning" to "Planning",
    )

    private fun known(name: String): String? = KNOWN[key(name)]?.let { Texts.t(it, KNOWN_ENGLISH.getValue(it)) }

    /** The same tools as an action after "wants to" or "Allowed:": "run a command", "edit files". */
    private val ACTIONS = mapOf(
        "askuserquestion" to "tool_action_ask",
        "askquestion" to "tool_action_ask",
        "bash" to "tool_action_run",
        "shell" to "tool_action_run",
        "runshellcommand" to "tool_action_run",
        "execcommand" to "tool_action_run",
        "read" to "tool_action_read",
        "readfile" to "tool_action_read",
        "readmanyfiles" to "tool_action_read",
        "edit" to "tool_action_edit",
        "multiedit" to "tool_action_edit",
        "write" to "tool_action_edit",
        "writefile" to "tool_action_edit",
        "notebookedit" to "tool_action_edit",
        "applypatch" to "tool_action_edit",
        "grep" to "tool_action_search",
        "glob" to "tool_action_search",
        "ls" to "tool_action_look",
        "websearch" to "tool_action_web_search",
        "googlewebsearch" to "tool_action_web_search",
        "webfetch" to "tool_action_web_page",
        "task" to "tool_action_subagent",
    )

    private val ACTIONS_ENGLISH = mapOf(
        "tool_action_ask" to "ask a question",
        "tool_action_run" to "run a command",
        "tool_action_read" to "read files",
        "tool_action_edit" to "edit files",
        "tool_action_search" to "search files",
        "tool_action_look" to "look at files",
        "tool_action_web_search" to "search the web",
        "tool_action_web_page" to "read a web page",
        "tool_action_subagent" to "run a sub-agent",
    )

    private fun actionOf(name: String): String? = ACTIONS[key(name)]?.let { Texts.t(it, ACTIONS_ENGLISH.getValue(it)) }

    /** What a request is for, as an action ("run a command"); an unknown tool is cleaned and lower-cased. */
    fun action(tool: String): String {
        val name = tool.trim()
        if (name.isEmpty()) return Texts.t("tool_action_other", "do something")
        return actionOf(name) ?: clean(name).lowercase()
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
        // A file name where a tool's name should be ("SessionScreen.kt"): never cleaned into words, only "A file".
        if (looksLikeAFile(head)) return Texts.t("tool_a_file", "A file")
        // An unknown word shows only if it can be a tool's name: a key or a token pasted in its place never does.
        if (known(head) == null && !plausibleToolName(head)) return ""
        val tool = known(head) ?: clean(head)
        val program = if (rest.isNotEmpty()) SafeText.requestLabel(head, rest).substringAfter(SEP, "") else ""
        return if (program.isNotEmpty()) "$tool$SEP$program" else tool
    }

    private val FILE_EXTENSIONS = setOf(
        "kt", "kts", "java", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "swift", "go", "rb", "php", "c", "h", "cpp", "hpp", "cs",
        "md", "txt", "json", "xml", "html", "css", "scss", "yml", "yaml", "toml", "lock", "gradle", "sh", "bat", "ps1", "sql", "svg", "png", "jpg", "jpeg", "pdf",
    )

    /** "SessionScreen.kt": a name, one dot, then a known file extension (a tool name such as "mcp.server" is not one). */
    private fun looksLikeAFile(s: String): Boolean {
        val dot = s.lastIndexOf('.')
        if (dot <= 0 || dot == s.length - 1) return false
        return s.substring(dot + 1).lowercase() in FILE_EXTENSIONS
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
