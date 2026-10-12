package com.coucou.android.core

/** A run of text with the few styles a chat answer needs. */
data class MdSpan(val text: String, val bold: Boolean = false, val code: Boolean = false)

sealed interface MdBlock {
    data class Para(val spans: List<MdSpan>) : MdBlock
    data class Bullet(val spans: List<MdSpan>) : MdBlock
    data class Code(val text: String) : MdBlock
}

/**
 * The light Markdown the computer's chat asks the models for: short paragraphs, bullet lists, **bold**,
 * `inline code` and fenced code blocks. Anything else (links, images, HTML, tables) stays plain text, so an
 * answer can never make the app open or load something. Safe on half an answer: a fence or a marker that has
 * not closed yet is shown as it is until the rest arrives.
 */
object MarkdownLite {
    fun parse(text: String): List<MdBlock> {
        val blocks = mutableListOf<MdBlock>()
        val para = mutableListOf<String>()
        fun flush() {
            if (para.isNotEmpty()) blocks.add(MdBlock.Para(inline(para.joinToString("\n")))); para.clear()
        }
        val lines = text.replace("\r\n", "\n").split("\n")
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            val trimmed = line.trimStart()
            when {
                trimmed.startsWith("```") -> {
                    flush()
                    val code = mutableListOf<String>()
                    i++
                    // An unfinished fence (the answer is still arriving) runs to the end.
                    while (i < lines.size && !lines[i].trimStart().startsWith("```")) code.add(lines[i++])
                    blocks.add(MdBlock.Code(code.joinToString("\n")))
                }
                line.isBlank() -> flush()
                isBullet(trimmed) -> { flush(); blocks.add(MdBlock.Bullet(inline(trimmed.substring(2).trimStart()))) }
                trimmed.startsWith("#") && trimmed.dropWhile { it == '#' }.startsWith(" ") -> {
                    // A heading is a bold line: the chat window is small, so no big titles.
                    flush(); blocks.add(MdBlock.Para(listOf(MdSpan(trimmed.dropWhile { it == '#' }.trim(), bold = true))))
                }
                else -> para.add(line)
            }
            i++
        }
        flush()
        return blocks
    }

    private fun isBullet(t: String) = t.length > 2 && (t[0] == '-' || t[0] == '*' || t[0] == '•') && t[1] == ' '

    /** **bold** and `code`; a marker with no partner is left as the characters it is. */
    fun inline(text: String): List<MdSpan> {
        val out = mutableListOf<MdSpan>()
        val plain = StringBuilder()
        fun emitPlain() { if (plain.isNotEmpty()) out.add(MdSpan(plain.toString())); plain.clear() }
        var i = 0
        while (i < text.length) {
            if (text.startsWith("**", i)) {
                val end = text.indexOf("**", i + 2)
                if (end > i + 2) { emitPlain(); out.add(MdSpan(text.substring(i + 2, end), bold = true)); i = end + 2; continue }
            }
            if (text[i] == '`') {
                val end = text.indexOf('`', i + 1)
                if (end > i + 1) { emitPlain(); out.add(MdSpan(text.substring(i + 1, end), code = true)); i = end + 1; continue }
            }
            plain.append(text[i]); i++
        }
        emitPlain()
        return out
    }
}

/** The codes the computer (or this app) gives for an answer that did not complete. */
object ChatReasons {
    val KNOWN = listOf(
        "off", "not_allowed", "busy", "rate", "too_long", "empty", "no_key", "unreachable", "auth", "provider",
        "canceled", "internal", "connection", "interrupted",
    )

    /** A code this version does not know is shown as a general problem. */
    fun key(code: String?): String = if (code != null && code in KNOWN) code else "internal"
}
