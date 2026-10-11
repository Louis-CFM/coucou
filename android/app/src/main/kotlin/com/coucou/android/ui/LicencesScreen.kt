package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.Licences
import com.coucou.android.core.TypeScale

/**
 * Settings > About > Licences: who made what, the full MIT text of Coucou's code, the notice for the artwork, and the Apache 2.0 text with
 * the libraries it covers. The words are legal text in files under assets/licenses, shown as they are (nothing here is translated).
 */
@Composable
fun LicencesScreen(onBack: () -> Unit) {
    val t = tokens()
    val assets = LocalContext.current.assets
    val paragraphs = remember {
        Licences.FILES.joinToString("\n\n") { name ->
            runCatching { assets.open("licenses/$name").bufferedReader().use { it.readText() } }.getOrDefault("")
        }.let(Licences::paragraphs)
    }
    LazyColumn(
        Modifier.padding(horizontal = Gutter), contentPadding = PaddingValues(bottom = BarClearance),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item { ScreenTitle(stringResource(R.string.licences_title), onBack) }
        item { Text(stringResource(R.string.licences_intro), Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.textDim.c())) }
        items(paragraphs) { p ->
            Text(p, Modifier.padding(horizontal = 4.dp), style = TypeScale.SECONDARY.style(t.text.c()).copy(fontFamily = FontFamily.Monospace))
        }
    }
}
