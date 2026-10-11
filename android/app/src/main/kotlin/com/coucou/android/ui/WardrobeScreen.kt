package com.coucou.android.ui

import android.os.SystemClock
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.coucou.android.R
import com.coucou.android.app.AppModel
import com.coucou.android.core.IconKind
import com.coucou.android.core.Radii
import com.coucou.android.core.Spacing
import com.coucou.android.core.TypeScale
import com.coucou.android.mochi.MochiEngine
import com.coucou.android.mochi.MochiView
import com.coucou.android.mochi.outfit.ComposeGfx
import com.coucou.android.mochi.outfit.Ctx2D
import com.coucou.android.mochi.outfit.Outfit
import com.coucou.android.mochi.outfit.Wardrobe
import com.coucou.android.mochi.outfit.drawIconMochi
import java.time.LocalDate

/** The name of a wardrobe value, in the app's words. */
@StringRes
fun outfitLabelRes(id: String): Int = when (id) {
    "auto" -> R.string.outfit_auto
    "none" -> R.string.outfit_none
    "partyHat" -> R.string.outfit_partyHat
    "beanie" -> R.string.outfit_beanie
    "crown" -> R.string.outfit_crown
    "sunglasses" -> R.string.outfit_sunglasses
    "roundGlasses" -> R.string.outfit_roundGlasses
    "bow" -> R.string.outfit_bow
    "scarf" -> R.string.outfit_scarf
    "witchHat" -> R.string.outfit_witchHat
    "pumpkin" -> R.string.outfit_pumpkin
    "santaHat" -> R.string.outfit_santaHat
    else -> R.string.outfit_bunnyEars
}

/** A little Mochi wearing [outfit], the PC's wardrobe icon (drawn by the same code as the big one). */
@Composable
fun OutfitIcon(outfit: Outfit, size: Dp, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) {
        drawIntoCanvas { c ->
            c.save()
            val k = this.size.width / 40f
            c.scale(k, k)
            drawIconMochi(Ctx2D(ComposeGfx(c, Rect(0f, 0f, 40f, 40f))), 40.0, outfit)
            c.restore()
        }
    }
}

/** "None": a crossed-out circle, like the PC's. */
@Composable
private fun NoOutfitIcon(size: Dp) {
    val color = tokens().textDim.c()
    Canvas(Modifier.size(size)) {
        val r = this.size.width * 0.26f
        val c = Offset(this.size.width / 2, this.size.height / 2)
        val stroke = Stroke(width = this.size.width * 0.035f, cap = StrokeCap.Round)
        drawCircle(color, r, c, style = stroke)
        drawLine(color, Offset(c.x - r * 0.68f, c.y + r * 0.68f), Offset(c.x + r * 0.68f, c.y - r * 0.68f), strokeWidth = stroke.width, cap = StrokeCap.Round)
    }
}

/**
 * Settings > Mochi's wardrobe: what Mochi wears on this phone. Either the same as on the computer (the default),
 * or one of the PC's thirteen choices ("Auto" follows the seasons on this phone's calendar). A preview on top.
 */
@Composable
fun WardrobeScreen(model: AppModel, onBack: () -> Unit) {
    val t = tokens()
    val s = model.settings
    val clock = remember { { SystemClock.elapsedRealtimeNanos() / 1e6 } }
    val preview = remember { MochiEngine(clock) }
    val worn = model.dress()
    val first = remember { androidx.compose.runtime.mutableStateOf(true) }
    LaunchedEffect(worn) {
        preview.setOutfit(worn, animated = !first.value)
        first.value = false
    }
    val following = s.outfit == Wardrobe.FOLLOW
    val today = LocalDate.now()
    val seasonal = Wardrobe.seasonal(today)
    LazyColumn(Modifier.padding(horizontal = Gutter), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = BarClearance), verticalArrangement = Arrangement.spacedBy(Gap)) {
        item { ScreenTitle(stringResource(R.string.wardrobe_title), onBack) }
        item {
            Panel {
                Column(Modifier.fillMaxWidth().padding(Spacing.INSIDE.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    MochiView(preview, Modifier.size(120.dp))
                    Text(stringResource(outfitLabelRes(model.outfitSelection)), style = TypeScale.TITLE.style(t.text.c()), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(stringResource(R.string.wardrobe_note), style = TypeScale.SECONDARY.style(t.textDim.c()), textAlign = TextAlign.Center)
                }
            }
        }
        item {
            Panel {
                ListRow(
                    stringResource(R.string.wardrobe_follow), hint = stringResource(R.string.wardrobe_follow_hint),
                    modifier = Modifier.clickable(role = Role.RadioButton) { model.updateSettings(s.copy(outfit = Wardrobe.FOLLOW)) }
                        .semantics { selected = following },
                    trailing = { if (following) CoucouIcon(IconKind.CHECK, tint = t.online.c(), size = 22.dp) },
                )
            }
        }
        items(Wardrobe.SELECTIONS.chunked(3)) { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(Gap), modifier = Modifier.fillMaxWidth()) {
                for (id in row) {
                    val chosen = !following && s.outfit == id
                    val label = stringResource(outfitLabelRes(id))
                    Box(Modifier.weight(1f)) {
                        OutfitCell(label, chosen, onClick = { model.updateSettings(s.copy(outfit = id)) }) {
                            when (id) {
                                "none" -> NoOutfitIcon(56.dp)
                                "auto" -> Box(contentAlignment = Alignment.BottomCenter) {
                                    OutfitIcon(seasonal, 56.dp)
                                    Text(
                                        stringResource(R.string.wardrobe_auto_tag), Modifier.background(androidx.compose.ui.graphics.Color(0x99000000), RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 1.dp),
                                        style = TypeScale.LABEL.style(androidx.compose.ui.graphics.Color.White), maxLines = 1,
                                    )
                                }
                                else -> OutfitIcon(Wardrobe.outfitOf(id), 56.dp)
                            }
                        }
                    }
                }
                // A short last row keeps its cells the same width as the others.
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        item { Spacer(Modifier.height(Gutter)) }
    }
}

@Composable
private fun OutfitCell(label: String, chosen: Boolean, onClick: () -> Unit, icon: @Composable () -> Unit) {
    val t = tokens()
    val shape = RoundedCornerShape(Radii.PANEL.dp)
    val selectedText = stringResource(R.string.wardrobe_selected)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(t.panel.c()).border(if (chosen) 2.dp else 1.dp, if (chosen) t.text.c() else t.line.c(), shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { selected = chosen; contentDescription = if (chosen) "$label, $selectedText" else label }
            .padding(vertical = 12.dp, horizontal = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        icon()
        Text(label, style = TypeScale.LABEL.style(t.text.c()), maxLines = 2, textAlign = TextAlign.Center, overflow = TextOverflow.Ellipsis)
    }
}
