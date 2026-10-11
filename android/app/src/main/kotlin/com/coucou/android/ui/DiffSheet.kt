package com.coucou.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.DiffState
import com.coucou.android.core.IslandSurface
import com.coucou.android.core.TypeScale
import com.coucou.android.link.DiffRow

/** What the file-change sheet draws a row in: the colour of its text and of the tint behind it. */
internal object DiffLook {
    val ADDED = Color(0xFF34D399)
    val REMOVED = Color(0xFFFF8D97)

    fun text(kind: Char): Color = when (kind) {
        '+' -> ADDED
        '-' -> REMOVED
        '@' -> Color(IslandSurface.TEXT_DIM)
        else -> Color(IslandSurface.TEXT)
    }

    fun tint(kind: Char): Color = when (kind) {
        '+' -> ADDED.copy(alpha = 0.12f)
        '-' -> REMOVED.copy(alpha = 0.12f)
        else -> Color.Transparent
    }

    /** What is said besides the colour, so the change is not carried by colour alone. */
    fun marker(kind: Char): String = when (kind) {
        '+' -> "+"
        '-' -> "−"
        '@' -> ""
        else -> " "
    }
}

/**
 * What an agent changed in one file, as the computer sent it when asked: up to 200 lines, added and removed lines
 * coloured and also marked with + and −. Held in memory while this is open; nothing is stored.
 */
@Composable
fun DiffSheet(model: AppModel) {
    val state = model.diffState
    if (state is DiffState.Idle) return
    val white = Color(IslandSurface.TEXT)
    val dim = Color(IslandSurface.TEXT_DIM)
    BottomSheetHost(onDismiss = { model.closeDiff() }) {
        val name = when (state) {
            is DiffState.Loading -> state.name
            is DiffState.Ready -> state.diff.name
            is DiffState.Failed -> state.name
            DiffState.Idle -> ""
        }
        Text(name, style = TypeScale.TITLE.style(white), maxLines = 2, overflow = TextOverflow.Ellipsis)
        when (state) {
            is DiffState.Loading -> Text(stringResource(R.string.file_loading), Modifier.padding(vertical = 16.dp), style = TypeScale.BODY.style(dim))
            is DiffState.Failed -> Text(stringResource(R.string.file_failed), Modifier.padding(vertical = 16.dp), style = TypeScale.BODY.style(dim))
            is DiffState.Ready -> {
                val d = state.diff
                Text(stringResource(R.string.file_summary, d.added, d.removed), Modifier.padding(top = 2.dp, bottom = 10.dp), style = TypeScale.SECONDARY.style(dim))
                val note = when {
                    d.gone -> R.string.file_gone
                    d.tooLarge -> R.string.file_too_large
                    d.rows.isEmpty() -> R.string.file_empty
                    else -> null
                }
                if (note != null) Text(stringResource(note), Modifier.padding(bottom = 12.dp), style = TypeScale.BODY.style(dim))
                else {
                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                        itemsIndexed(d.rows) { _, row -> DiffLine(row) }
                    }
                    if (d.truncated) Text(stringResource(R.string.file_truncated), Modifier.padding(top = 8.dp), style = TypeScale.SECONDARY.style(dim))
                }
            }
            DiffState.Idle -> {}
        }
        PillButton(stringResource(R.string.file_close), { model.closeDiff() }, Modifier.fillMaxWidth().padding(top = 12.dp), onDark = true)
    }
}

@Composable
private fun DiffLine(row: DiffRow) {
    val mono = TypeScale.MONO.style(DiffLook.text(row.kind))
    Row(Modifier.fillMaxWidth().background(DiffLook.tint(row.kind)).padding(horizontal = 6.dp, vertical = 1.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(DiffLook.marker(row.kind), style = mono.copy(fontFamily = FontFamily.Monospace))
        Text(row.text, Modifier.weight(1f), style = mono.copy(fontFamily = FontFamily.Monospace))
    }
}
