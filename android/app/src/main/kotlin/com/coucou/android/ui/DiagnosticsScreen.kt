package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.link.DiagResult
import com.coucou.android.link.DiagStep

/**
 * Settings > Computer > "Can't connect?": runs the checks one after another (Wi-Fi, the saved address, discovery, the pinned
 * certificate, the pairing code and version, the relay) and says which one fails and what to try. The report it copies hides the
 * pairing code, the certificate fingerprint, the computer's name and the full address.
 */
@Composable
fun DiagnosticsScreen(model: AppModel, onBack: () -> Unit) {
    val t = tokens()
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { if (model.diagResults.isEmpty() && !model.diagRunning) model.runDiagnostics() }
    LazyColumn(
        Modifier.padding(horizontal = Gutter), contentPadding = PaddingValues(bottom = BarClearance),
        verticalArrangement = Arrangement.spacedBy(Gap),
    ) {
        item { ScreenTitle(stringResource(R.string.diag_title), onBack) }
        item { Text(stringResource(R.string.diag_intro), Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c())) }
        item {
            Panel {
                model.diagResults.forEachIndexed { i, (step, result) ->
                    if (i > 0) RowDivider()
                    DiagRow(step, result)
                }
                if (model.diagRunning) Text(stringResource(R.string.diag_running), Modifier.padding(Spacing.INSIDE.dp), style = TypeScale.SECONDARY.style(t.textDim.c()))
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(stringResource(R.string.diag_run), { copied = false; model.runDiagnostics() }, Modifier.weight(1f), enabled = !model.diagRunning)
                PillButton(
                    stringResource(R.string.diag_copy),
                    { clipboard.setText(AnnotatedString(model.diagnosticsReport())); copied = true },
                    Modifier.weight(1f), PillKind.PRIMARY, enabled = model.diagResults.isNotEmpty() && !model.diagRunning,
                )
            }
        }
        if (copied) item { Text(stringResource(R.string.diag_copied), Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c())) }
    }
}

/** One check: a dot, its name with a word (so colour is not the only signal), what was found, and what to try. */
@Composable
private fun DiagRow(step: DiagStep, result: DiagResult) {
    val t = tokens()
    val word: String
    val dot: Color
    val detail: String
    var hint = ""
    when (result) {
        is DiagResult.Ok -> { word = stringResource(R.string.diag_ok); dot = StatusColors.online; detail = result.detail }
        is DiagResult.Problem -> { word = stringResource(R.string.diag_problem); dot = Color(t.danger); detail = result.problem; hint = result.hint }
        is DiagResult.Skipped -> { word = stringResource(R.string.diag_skipped); dot = Color(t.textFaint); detail = result.why }
    }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = Spacing.INSIDE.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp), verticalAlignment = Alignment.Top,
    ) {
        StateDot(dot, Modifier.padding(top = 6.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("${step.title} · $word", style = TypeScale.BODY.style(t.text.c()))
            Text(detail, style = TypeScale.SECONDARY.style(t.textDim.c()))
            if (hint.isNotEmpty()) Text(hint, style = TypeScale.SECONDARY.style(t.text.c()))
        }
    }
}
