package fr.louisraille.coucou.phone

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The iOS glassCard(): a rounded card at white-11% with an optional tint edge. */
@Composable
fun CoucouCard(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = Coucou.CornerCard,
    tint: Color? = null,
    content: @Composable () -> Unit,
) {
    Box(
        modifier
            .clip(RoundedCornerShape(cornerRadius))
            .background(Coucou.Card)
            .then(
                if (tint != null) Modifier.border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(cornerRadius))
                else Modifier.border(1.dp, Coucou.CardStroke, RoundedCornerShape(cornerRadius))
            )
    ) { content() }
}

/**
 * The iOS ApprovalChoiceButtons: Allow is a bright white capsule with dark
 * text, Deny a quiet white-14% capsule. Both shrink under the finger, springing
 * back like system buttons.
 */
@Composable
fun PillButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    filled: Boolean = false,
    enabled: Boolean = true,
    container: Color? = null,
    ink: Color? = null,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        if (pressed) 0.96f else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessHigh),
        label = "press",
    )
    val alpha by animateFloatAsState(
        if (pressed) 0.85f else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessHigh),
        label = "pressAlpha",
    )
    Box(
        modifier
            .graphicsLayer { scaleX = scale; scaleY = scale; this.alpha = alpha * if (enabled) 1f else 0.6f }
            .clip(CircleShape)
            .background(container ?: if (filled) Color.White else Color.White.copy(alpha = 0.14f))
            .clickable(interactionSource, indication = null, enabled = enabled, role = Role.Button) { onClick() }
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            color = ink ?: if (filled) Color.Black else Color.White,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
    }
}

/** The dark rounded input used on the pairing screen — no outline, white-8% fill. */
@Composable
fun CoucouField(
    value: String,
    onValueChange: (String) -> Unit,
    hint: String,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    Box(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(Coucou.Field)
            .padding(horizontal = 16.dp, vertical = 15.dp),
    ) {
        if (value.isEmpty()) {
            Text(hint, color = Coucou.Tertiary, fontSize = 15.sp)
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = TextStyle(color = Coucou.Ink, fontSize = 15.sp),
            cursorBrush = SolidColor(Coucou.Ink),
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/**
 * Apple Pay's "Done": a green ring draws itself, then the checkmark. Ported
 * from AppleStyle.swift's DrawnCheckmark.
 */
@Composable
fun DrawnCheckmark(size: Dp = 56.dp, modifier: Modifier = Modifier) {
    val ring = remember { Animatable(0f) }
    val tick = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { ring.animateTo(1f, tween(450, easing = FastOutSlowInEasing)) }
        launch {
            delay(350)
            tick.animateTo(1f, tween(300, easing = FastOutSlowInEasing))
        }
    }
    Canvas(modifier.size(size)) {
        val stroke = size.toPx() * 0.07f
        // Ring trims in.
        drawArc(
            Coucou.Done,
            startAngle = -90f,
            sweepAngle = 360f * ring.value,
            useCenter = false,
            topLeft = Offset(stroke / 2, stroke / 2),
            size = Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
        // Then the checkmark — same shape as iOS CheckShape.
        if (tick.value > 0f) {
            val w = this.size.width
            val h = this.size.height
            val inset = w * 0.28f
            val r = Rect(inset, inset, w - inset, h - inset)
            val check = Path().apply {
                moveTo(r.left, r.top + r.height * 0.55f)
                lineTo(r.left + r.width * 0.38f, r.bottom - r.height * 0.12f)
                lineTo(r.right, r.top + r.height * 0.12f)
            }
            val measure = PathMeasure().apply { setPath(check, false) }
            val trimmed = Path()
            measure.getSegment(0f, measure.length * tick.value, trimmed)
            drawPath(
                trimmed, Coucou.Done,
                style = Stroke(width = w * 0.08f, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

/**
 * iOS' "Allow asks for Face ID": `run` fires only after a biometric/PIN
 * confirmation. Where the device can't authenticate (no hardware, nothing
 * enrolled) the tap passes straight through — a missing gate must never block
 * the user, and it must never silently skip either: the system prompt is the
 * gate when Android can offer one.
 */
fun gateWithBiometrics(context: android.content.Context, run: () -> Unit) {
    val activity = context as? FragmentActivity ?: return run()
    val kinds = BiometricManager.Authenticators.BIOMETRIC_STRONG or
        BiometricManager.Authenticators.DEVICE_CREDENTIAL
    val manager = BiometricManager.from(context)
    if (manager.canAuthenticate(kinds) != BiometricManager.BIOMETRIC_SUCCESS) return run()
    val prompt = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(context),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                run()
            }
        },
    )
    prompt.authenticate(
        BiometricPrompt.PromptInfo.Builder()
            .setTitle("Confirm it's you")
            .setSubtitle("Approve this request on your PC")
            .setAllowedAuthenticators(kinds)
            .build(),
    )
}

/** Selected/unselected option row for question cards — a whole tappable row. */
@Composable
fun OptionRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    role: Role = Role.RadioButton,
) {
    Row(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Coucou.Question.copy(alpha = 0.16f) else Coucou.Field)
            .then(
                if (selected) Modifier.border(1.dp, Coucou.Question.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
                else Modifier
            )
            .clickable(role = role) { onClick() }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Radio dot
        Canvas(Modifier.size(18.dp)) {
            drawCircle(if (selected) Coucou.Question else Coucou.Tertiary, radius = size.minDimension / 2f, style = Stroke(1.5.dp.toPx()))
            if (selected) drawCircle(Coucou.Question, radius = size.minDimension / 2f - 5.dp.toPx())
        }
        Text(
            label,
            color = if (selected) Coucou.Ink else Coucou.Secondary,
            fontSize = 15.sp,
            fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
            modifier = Modifier.padding(start = 12.dp),
        )
    }
}


