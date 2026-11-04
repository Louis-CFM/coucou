package com.coucou.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.core.Spacing
import com.coucou.android.core.TeamChoice
import com.coucou.android.core.TypeScale

/**
 * The Team widget's choice screen: a checkbox per agent, up to [TeamChoice.MAX], then Save. [initial] is what the widget shows now
 * (empty for a new one). The rule of what can be picked is [TeamChoice]; this only draws it.
 */
@Composable
fun TeamConfigScreen(modifier: Modifier, initial: List<String>, onSave: (List<String>) -> Unit) {
    var chosen by rememberSaveable { mutableStateOf(initial) }
    Column(modifier.fillMaxSize().padding(horizontal = Gutter), verticalArrangement = Arrangement.spacedBy(Gap)) {
        ScreenTitle(stringResource(R.string.team_config_title), null)
        Text(
            stringResource(R.string.team_config_hint, TeamChoice.MAX), Modifier.padding(horizontal = 4.dp),
            style = TypeScale.SECONDARY.style(tokens().textDim.c()),
        )
        Panel(Modifier.weight(1f)) {
            LazyColumn(Modifier.fillMaxWidth()) {
                items(TeamChoice.candidates, key = { it.id }) { pill ->
                    val on = pill.id in chosen
                    val enabled = TeamChoice.canToggle(chosen, pill.id)
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = Spacing.MIN_TOUCH.dp).alpha(if (enabled) 1f else 0.4f)
                            .toggleable(value = on, enabled = enabled, role = Role.Checkbox) { chosen = TeamChoice.toggle(chosen, pill.id) }
                            .padding(horizontal = Spacing.INSIDE.dp),
                        horizontalArrangement = Arrangement.spacedBy(Spacing.GAP.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = on, onCheckedChange = null)
                        Text(TeamChoice.nameOf(pill.id), Modifier.weight(1f), style = TypeScale.BODY.style(tokens().text.c()))
                    }
                }
            }
        }
        PillButton(stringResource(R.string.team_config_save), { onSave(chosen) }, Modifier.fillMaxWidth().padding(bottom = Gutter), PillKind.PRIMARY)
    }
}
