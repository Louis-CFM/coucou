package fr.louisraille.coucou.phone

/** What the question card keeps while the user picks, and what it sends. */
object QuestionAnswers {
    /** One option tapped: a multi-select question toggles it, any other keeps only it. */
    fun toggle(current: List<String>, option: String, multi: Boolean): List<String> = when {
        !multi -> listOf(option)
        option in current -> current - option
        else -> current + option
    }

    /** Every question has at least one pick — or its own words under "Other…". */
    fun complete(
        groups: List<Relay.Question>,
        picked: Map<String, List<String>>,
        other: Map<String, String> = emptyMap(),
    ): Boolean = groups.all { picked[it.q].orEmpty().isNotEmpty() || !other[it.q].isNullOrBlank() }

    /**
     * The answers as the PC's hook takes them: a label for a single choice, the
     * list of labels for a multi-select question, the typed words for "Other…".
     */
    fun toAnswers(
        groups: List<Relay.Question>,
        picked: Map<String, List<String>>,
        other: Map<String, String> = emptyMap(),
    ): Map<String, Any> = groups.mapNotNull { g ->
        val free = other[g.q]?.takeUnless { it.isBlank() }
        val p = picked[g.q].orEmpty()
        when {
            free != null -> g.q to free
            p.isNotEmpty() -> g.q to (if (g.multi) p else p.first())
            else -> null
        }
    }.toMap()

    /** The questions answered in words — the `other` list the PC wants alongside. */
    fun others(groups: List<Relay.Question>, other: Map<String, String>): List<String> =
        groups.filter { !other[it.q].isNullOrBlank() }.map { it.q }
}
