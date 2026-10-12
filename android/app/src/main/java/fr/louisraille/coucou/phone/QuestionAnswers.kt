package fr.louisraille.coucou.phone

/** What the question card keeps while the user picks, and what it sends. */
object QuestionAnswers {
    /** One option tapped: a multi-select question toggles it, any other keeps only it. */
    fun toggle(current: List<String>, option: String, multi: Boolean): List<String> = when {
        !multi -> listOf(option)
        option in current -> current - option
        else -> current + option
    }

    /** Every question has at least one pick. */
    fun complete(groups: List<Relay.Question>, picked: Map<String, List<String>>): Boolean =
        groups.all { picked[it.q].orEmpty().isNotEmpty() }

    /**
     * The answers as the PC's hook takes them: a label for a single choice, the
     * list of labels for a multi-select question.
     */
    fun toAnswers(groups: List<Relay.Question>, picked: Map<String, List<String>>): Map<String, Any> =
        groups.mapNotNull { g ->
            val p = picked[g.q].orEmpty()
            if (p.isEmpty()) null else g.q to (if (g.multi) p else p.first())
        }.toMap()
}
