package com.coucou.android.core

/** What the always-visible Chat tab shows. */
enum class ChatTabState { NOT_PAIRED, NOT_CONNECTED, CHAT_OFF, NO_MODELS, READY }

object ChatTab {
    /**
     * In order of what the user can do about it: no computer paired, the computer not reachable, the computer not offering
     * chat (its switch is off), offering it with no model allowed, or ready.
     */
    fun state(paired: Boolean, connected: Boolean, offered: Boolean, modelCount: Int): ChatTabState = when {
        !paired -> ChatTabState.NOT_PAIRED
        !connected -> ChatTabState.NOT_CONNECTED
        !offered -> ChatTabState.CHAT_OFF
        modelCount <= 0 -> ChatTabState.NO_MODELS
        else -> ChatTabState.READY
    }

    /** Where the empty state's button leads: pairing (Home shows it when nothing is paired) or Settings. Null: no button, the hint is the answer. */
    fun action(state: ChatTabState): Screen? = when (state) {
        ChatTabState.NOT_PAIRED -> Screen.HOME
        ChatTabState.NOT_CONNECTED -> Screen.SETTINGS
        else -> null
    }
}

/**
 * Does the bottom bar fit at a given font size? Each item gets a third of the bar; a label needs roughly 0.6 em per
 * character plus the item's side padding. A rough rule, but it catches "Settings" at 2.0x on a narrow phone, and the Compose code
 * also keeps every label on one line.
 */
object BarFit {
    const val BAR_SIDE_MARGIN_DP = 24
    const val BAR_PADDING_DP = 6
    const val ITEM_GAP_DP = 4
    const val ITEM_SIDE_PADDING_DP = 4
    const val LABEL_SP = 12
    private const val EM_PER_CHAR = 0.6

    fun itemWidthDp(screenWidthDp: Int, items: Int): Double =
        (screenWidthDp - 2.0 * BAR_SIDE_MARGIN_DP - 2.0 * BAR_PADDING_DP - ITEM_GAP_DP * (items - 1)) / items

    fun labelWidthDp(label: String, fontScale: Double): Double = label.length * LABEL_SP * fontScale * EM_PER_CHAR + 2.0 * ITEM_SIDE_PADDING_DP

    fun fits(screenWidthDp: Int, labels: List<String>, fontScale: Double): Boolean {
        val w = itemWidthDp(screenWidthDp, labels.size)
        return labels.all { labelWidthDp(it, fontScale) <= w }
    }
}
