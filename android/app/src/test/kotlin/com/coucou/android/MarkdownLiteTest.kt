package com.coucou.android

import com.coucou.android.core.MarkdownLite
import com.coucou.android.core.MdBlock
import com.coucou.android.core.MdSpan
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownLiteTest {
    private fun plain(vararg t: String) = t.map { MdSpan(it) }

    @Test fun paragraphsAreSeparatedByBlankLines() {
        val b = MarkdownLite.parse("First line\nstill first\n\nSecond")
        assertEquals(listOf(MdBlock.Para(plain("First line\nstill first")), MdBlock.Para(plain("Second"))), b)
    }

    @Test fun boldAndInlineCode() {
        assertEquals(
            listOf(MdSpan("Use "), MdSpan("soft reset", bold = true), MdSpan(" with "), MdSpan("git reset", code = true), MdSpan(".")),
            MarkdownLite.inline("Use **soft reset** with `git reset`."),
        )
    }

    @Test fun anUnfinishedMarkerStaysAsTheCharactersItIs() {
        // Half an answer: "**bol" has no partner yet.
        assertEquals(plain("a **bol"), MarkdownLite.inline("a **bol"))
        assertEquals(plain("a `co"), MarkdownLite.inline("a `co"))
        assertEquals(plain("****"), MarkdownLite.inline("****"))
        assertEquals(plain("``"), MarkdownLite.inline("``"))
    }

    @Test fun bulletsWithDashStarOrDot() {
        val b = MarkdownLite.parse("- one\n* two **b**\n• three\n-not a bullet")
        assertEquals(MdBlock.Bullet(plain("one")), b[0])
        assertEquals(MdBlock.Bullet(listOf(MdSpan("two "), MdSpan("b", bold = true))), b[1])
        assertEquals(MdBlock.Bullet(plain("three")), b[2])
        assertEquals(MdBlock.Para(plain("-not a bullet")), b[3])
    }

    @Test fun fencedCodeIsKeptAsItIsAndNothingInsideIsStyled() {
        val b = MarkdownLite.parse("Before\n```kotlin\nval a = **x**\n  indented\n```\nAfter")
        assertEquals(
            listOf(MdBlock.Para(plain("Before")), MdBlock.Code("val a = **x**\n  indented"), MdBlock.Para(plain("After"))),
            b,
        )
    }

    @Test fun anUnfinishedFenceRunsToTheEndWhileTheAnswerIsStillArriving() {
        assertEquals(listOf(MdBlock.Code("line1\nline2")), MarkdownLite.parse("```\nline1\nline2"))
    }

    @Test fun headingsBecomeBoldLines() {
        assertEquals(listOf(MdBlock.Para(listOf(MdSpan("Title", bold = true)))), MarkdownLite.parse("## Title"))
        assertEquals(listOf(MdBlock.Para(plain("#hashtag"))), MarkdownLite.parse("#hashtag"))
    }

    @Test fun linksImagesAndHtmlStayPlainText() {
        val text = "[x](https://evil.example) ![i](http://a/b.png) <script>alert(1)</script>"
        assertEquals(listOf(MdBlock.Para(plain(text))), MarkdownLite.parse(text))
    }

    @Test fun windowsLineEndingsAndEmptyInput() {
        assertEquals(listOf(MdBlock.Para(plain("a\nb"))), MarkdownLite.parse("a\r\nb"))
        assertEquals(emptyList<MdBlock>(), MarkdownLite.parse(""))
        assertEquals(emptyList<MdBlock>(), MarkdownLite.parse("\n\n  \n"))
    }

    @Test fun neverThrowsOnOddInput() {
        for (s in listOf("```", "``` ```", "**", "`", "- ", "-", "#", "# ", "\u0000", "a".repeat(100_000))) MarkdownLite.parse(s)
        assertTrue(true)
    }
}
