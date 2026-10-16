# Phase 4 — Android companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- The phone keeps its push token on the relay (C3) and handles pushes inside FCM's time window.
- Stale approval buttons expire, and Allow needs an unlocked phone (C12).
- Multi-select questions can be answered (C8).
- The pairing secret is encrypted at rest.
- Session urgency matches the Mac.
- Chat follows new lines, off-screen Mochis stop asking for frames, and the screen survives process death.

**Architecture:** Logic that decides something moves into small pure Kotlin objects (`TokenSync`, `DeviceId`, `QuestionAnswers`, `Urgency`, `SecretCodec`) covered by JVM unit tests. Framework glue (FCM service, notification, Keystore, Compose) stays thin and is verified on a device with the checks listed per task.

**Tech Stack:** Kotlin 2.2, Jetpack Compose (BOM 2025.08), AndroidX core 1.17, OkHttp 4.12, Firebase Messaging, Android Keystore, JUnit 4 (test only).

**Spec:** `README.md` in this folder (findings C3, C8, C12, A2–A9, V7–V10; contracts 1–3).

## Global Constraints

See `README.md` → Global Constraints. For this phase:
- The only new dependency is `testImplementation("junit:junit:4.13.2")`, which is test-only and never ships.
- Don't restyle anything: question options keep `OptionRow`'s look (only its accessibility role changes for multi-select), and the notification keeps its layout.
- Phase 1 must be deployed on your relay before Task 4.1 ships. The phone then sends `device` (contract 3), and Task 4.4 sends list answers (contract 2).
- Run from `android/`: `./gradlew :app:testDebugUnitTest` (`gradlew.bat` on Windows). This needs the Android SDK configured (`local.properties`).

## Review Focus

See `README.md`. This phase owns the device check in Task 4.3: an approval notification left alone disappears after 108 s, and its Allow asks to unlock a locked phone.

---

### Task 4.1: The relay always has this phone's current push token, and knows which phone it is (C3, contract 3)

Today:
- `CoucouMessagingService.kt:19-21` swallows a failed `claim` with the comment "next claim attempt happens on app open".
- `claim` is only called from `pair()` (`CoucouViewModel.kt:141`).
- So one failed token refresh silences every alert until the phone is paired again.

**Files:**
- Modify: `android/app/build.gradle.kts` (test dependency)
- Create: `android/app/src/main/java/fr/louisraille/coucou/phone/TokenSync.kt`
- Create: `android/app/src/test/java/fr/louisraille/coucou/phone/TokenSyncTest.kt`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Prefs.kt`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Relay.kt` (`claim`)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt` (`onForeground`, new `syncToken`, `pair`)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/CoucouMessagingService.kt` (`onNewToken`)

**Interfaces:**
- Produces:
  - `object DeviceId { fun new(random: SecureRandom = SecureRandom()): String }`
  - `object TokenSync { fun shouldClaim(lastClaimed: String?, current: String?): Boolean }`
  - `Prefs.Pairing.deviceId: String`
  - `Prefs.claimedToken(ctx): String?` and `Prefs.setClaimedToken(ctx, token)`

- [ ] **Step 1: Add JUnit for unit tests**

In `android/app/build.gradle.kts`, add inside `dependencies { … }`:

```kotlin
    // JVM unit tests (src/test) — never shipped.
    testImplementation("junit:junit:4.13.2")
```

- [ ] **Step 2: Write the failing tests**

Create `android/app/src/test/java/fr/louisraille/coucou/phone/TokenSyncTest.kt`:

```kotlin
package fr.louisraille.coucou.phone

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenSyncTest {
    @Test
    fun aNewOrChangedTokenIsClaimed() {
        assertTrue(TokenSync.shouldClaim(null, "t1"))
        assertTrue(TokenSync.shouldClaim("t0", "t1"))
    }

    @Test
    fun theSameTokenIsNotClaimedTwice() {
        assertFalse(TokenSync.shouldClaim("t1", "t1"))
    }

    @Test
    fun noTokenIsNothingToClaim() {
        assertFalse(TokenSync.shouldClaim("t1", null))
        assertFalse(TokenSync.shouldClaim(null, ""))
    }

    @Test
    fun deviceIdsAre32LowercaseHexAndDiffer() {
        val a = DeviceId.new()
        val b = DeviceId.new()
        assertTrue(a, a.matches(Regex("[0-9a-f]{32}")))
        assertNotEquals(a, b)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "fr.louisraille.coucou.phone.TokenSyncTest"`
Expected: FAIL to compile, `Unresolved reference: TokenSync`.

- [ ] **Step 4: Write minimal implementation**

Create `android/app/src/main/java/fr/louisraille/coucou/phone/TokenSync.kt`:

```kotlin
package fr.louisraille.coucou.phone

import java.security.SecureRandom

/**
 * This phone's id on the relay, made once per pairing: a paired box only takes
 * a new push token from the phone that claimed it (relay DEVICE_RE).
 */
object DeviceId {
    fun new(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(16).also { random.nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

/** When the relay must hear about this phone's FCM token. */
object TokenSync {
    /** The current token differs from the last one a claim got through with. */
    fun shouldClaim(lastClaimed: String?, current: String?): Boolean =
        !current.isNullOrBlank() && current != lastClaimed
}
```

Replace `Prefs.kt` with:

```kotlin
package fr.louisraille.coucou.phone

import android.content.Context

/**
 * Pairing credentials — {worker, id, secret, deviceName, deviceId} — plus the
 * push token the relay last accepted. The box only ever stores the secret's
 * SHA-256 (see relay/src/index.ts).
 */
object Prefs {
    private const val FILE = "coucou"
    private const val K_WORKER = "worker"
    private const val K_ID = "id"
    private const val K_SECRET = "secret"
    private const val K_NAME = "device_name"
    private const val K_DEVICE_ID = "device_id"
    private const val K_CLAIMED_TOKEN = "claimed_token"

    class Pairing(
        val worker: String,
        val id: String,
        val secret: String,
        val deviceName: String,
        val deviceId: String,
    )

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun load(ctx: Context): Pairing? {
        val p = sp(ctx)
        val worker = p.getString(K_WORKER, null) ?: return null
        val id = p.getString(K_ID, null) ?: return null
        val secret = p.getString(K_SECRET, null) ?: return null
        // A pairing made before device ids existed gets one now; the relay
        // takes it with the next claim.
        val deviceId = p.getString(K_DEVICE_ID, null)
            ?: DeviceId.new().also { p.edit().putString(K_DEVICE_ID, it).apply() }
        return Pairing(worker, id, secret, p.getString(K_NAME, null) ?: "Android", deviceId)
    }

    fun save(ctx: Context, pairing: Pairing) {
        sp(ctx).edit()
            .putString(K_WORKER, pairing.worker)
            .putString(K_ID, pairing.id)
            .putString(K_SECRET, pairing.secret)
            .putString(K_NAME, pairing.deviceName)
            .putString(K_DEVICE_ID, pairing.deviceId)
            .apply()
    }

    fun claimedToken(ctx: Context): String? = sp(ctx).getString(K_CLAIMED_TOKEN, null)

    fun setClaimedToken(ctx: Context, token: String) {
        sp(ctx).edit().putString(K_CLAIMED_TOKEN, token).apply()
    }

    fun clear(ctx: Context) = sp(ctx).edit().clear().apply()
}
```

In `Relay.kt`, replace `claim` with:

```kotlin
    fun claim(p: Prefs.Pairing, fcmToken: String) {
        val body = auth(p).put("token", fcmToken).put("name", p.deviceName)
        if (p.deviceId.isNotEmpty()) body.put("device", p.deviceId)
        post(p.worker, "claim", body)
    }
```

In `CoucouViewModel.kt`:

1. Replace `onForeground` with:

```kotlin
    fun onForeground() {
        val p = Prefs.load(getApplication()) ?: return
        syncToken(p)
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            while (isActive) {
                refresh()
                delay(3000)
            }
        }
    }

    /**
     * Claims the box again when FCM rotated this phone's token since the last
     * claim that got through: a refresh the service could not deliver (offline,
     * relay down) is caught up the next time the app comes forward.
     */
    private fun syncToken(p: Prefs.Pairing) {
        viewModelScope.launch {
            try {
                val token = withContext(Dispatchers.IO) { Tasks.await(FirebaseMessaging.getInstance().token) }
                if (!TokenSync.shouldClaim(Prefs.claimedToken(getApplication()), token)) return@launch
                withContext(Dispatchers.IO) { Relay.claim(p, token) }
                Prefs.setClaimedToken(getApplication(), token)
            } catch (e: Relay.Http) {
                if (e.code == 409) lineError = "Another phone has taken this box over — pair again from the PC."
            } catch (_: Exception) {
                // Offline or no Play services: tried again next time the app comes forward.
            }
        }
    }
```

2. In `pair()`:
   - Change `val pairing = Prefs.Pairing(workerUrl, id.lowercase(), secret.lowercase(), name)` to `val pairing = Prefs.Pairing(workerUrl, id.lowercase(), secret.lowercase(), name, DeviceId.new())`.
   - After `Prefs.save(getApplication(), pairing)`, add `Prefs.setClaimedToken(getApplication(), token)`.

In `CoucouMessagingService.kt`, replace `onNewToken` with:

```kotlin
    override fun onNewToken(token: String) {
        // Called on FCM's background thread, with time to finish: no Thread{}
        // the system may freeze before the claim goes out.
        val p = Prefs.load(this) ?: return
        try {
            Relay.claim(p, token)
            Prefs.setClaimedToken(this, token)
        } catch (_: Exception) {
            // The app claims it the next time it comes forward (TokenSync).
        }
    }
```

- [ ] **Step 5: Run tests and build**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "fr.louisraille.coucou.phone.TokenSyncTest" && ./gradlew :app:assembleDebug`
Expected: PASS, and the build succeeds.

- [ ] **Step 6: Device check**

Pair the phone, then run `adb shell pm clear com.google.android.gms`, or reinstall the app keeping its data, to force a new FCM token. Open the app once, then trigger a permission on the PC: the notification arrives.

- [ ] **Step 7: Commit**

```bash
git add android/app/build.gradle.kts android/app/src/main/java/fr/louisraille/coucou/phone/TokenSync.kt android/app/src/test/java/fr/louisraille/coucou/phone/TokenSyncTest.kt android/app/src/main/java/fr/louisraille/coucou/phone/Prefs.kt android/app/src/main/java/fr/louisraille/coucou/phone/Relay.kt android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt android/app/src/main/java/fr/louisraille/coucou/phone/CoucouMessagingService.kt
git commit -m "Android: re-claim a rotated push token on app open; send a device id"
```

---

### Task 4.2: Push work happens inside FCM's window (A2, A5)

`onMessageReceived` starts a raw `Thread {}` and returns at once (`CoucouMessagingService.kt:24-35`), so the system may freeze the process before the fetch and notification finish. `FirebaseMessagingService` already calls it on a background thread with about 20 s to work. Also, `DecisionReceiver` only calls `pending.finish()` when nothing throws first (`DecisionReceiver.kt:20-26`).

**Files:**
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/CoucouMessagingService.kt` (`onMessageReceived`)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/DecisionReceiver.kt`

- [ ] **Step 1: Write the change**

There is nothing a JVM test can drive here. In `CoucouMessagingService.kt`, replace `onMessageReceived` with:

```kotlin
    override fun onMessageReceived(message: RemoteMessage) {
        // Already on FCM's background thread, which waits for us: returning
        // early (a Thread{}) let the system freeze the app mid-fetch.
        val p = Prefs.load(this) ?: return
        try {
            val card = Relay.fetch(p).pending
            if (card != null) Notifier.showCard(this, card) else Notifier.cancelCard(this)
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) Log.w("CoucouPush", "fetch failed", e)
        }
    }
```

In `DecisionReceiver.kt`, replace the `Thread { … }.start()` with:

```kotlin
        Thread {
            try {
                Relay.decide(p, requestId, decision, null)
            } catch (_: Exception) {
                // A stale card is simply ignored by the PC.
            } finally {
                Notifier.cancelCard(context)
                pending.finish()
            }
        }.start()
```

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: success.

- [ ] **Step 3: Device check**

Enable Doze (`adb shell dumpsys deviceidle force-idle`), trigger a permission on the PC, and confirm the notification appears with the card's text. Then `adb shell dumpsys deviceidle unforce`.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/CoucouMessagingService.kt android/app/src/main/java/fr/louisraille/coucou/phone/DecisionReceiver.kt
git commit -m "Android: handle pushes inside FCM's window; always finish the decision broadcast"
```

---

### Task 4.3: Approval notifications expire with the PC's wait, and Allow needs an unlocked phone (C12)

The heads-up notification outlives the PC's 108 s wait (`pipe.rs:40`), leaving buttons that cannot land anymore. Its Allow action (`Notifier.kt:52`) also runs from the lock screen with no unlock, while the in-app Allow asks for a fingerprint (`Components.kt:210`).

**Files:**
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Notifier.kt`

- [ ] **Step 1: Write the change**

In `Notifier.kt`, add inside `object Notifier`:

```kotlin
    /** The PC holds a card for 108 s (pipe.rs DECISION_TIMEOUT); after that its buttons do nothing. */
    private const val CARD_TTL_MS = 108_000L
```

In `showCard`, add `.setTimeoutAfter(CARD_TTL_MS)` to the builder chain (after `.setContentIntent(tap)`), and replace the two `b.addAction(…)` lines with:

```kotlin
        if (!card.isQuestion) {
            // Allow first unlocks the phone, as the in-app Allow asks for the
            // fingerprint (gateWithBiometrics). Deny stays a plain tap there too.
            b.addAction(
                NotificationCompat.Action.Builder(0, ctx.getString(R.string.allow), decisionPending(ctx, card, "allow", 1))
                    .setAuthenticationRequired(true)
                    .build(),
            )
            b.addAction(0, ctx.getString(R.string.deny), decisionPending(ctx, card, "deny", 2))
        }
```

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: success.

- [ ] **Step 3: Device check**

1. Lock the phone (with a PIN set) and trigger a permission on the PC. Tap Allow on the lock-screen notification: the phone asks to unlock first.
2. Leave another card alone: the notification disappears after about 108 s.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/Notifier.kt
git commit -m "Android: approval notifications expire with the PC's wait; Allow needs an unlocked phone"
```

---

### Task 4.4: Multi-select questions can be answered from the phone (C8, contracts 1–2)

`QuestionOptions` (`Screens.kt:640-668`) keeps one label per question, but the PC's hook only accepts a list for a multi-select question (`windows/hook/src/reply.rs:150-158`). Phase 1 Task 1.5 and Phase 3 Task 3.2 now carry `multi` to the phone.

**Files:**
- Create: `android/app/src/main/java/fr/louisraille/coucou/phone/QuestionAnswers.kt`
- Create: `android/app/src/test/java/fr/louisraille/coucou/phone/QuestionAnswersTest.kt`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Relay.kt` (`Question.multi`, `parseCard`, `decide`)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt` (`decide` signature)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Components.kt` (`OptionRow` gets `role`)
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt` (`QuestionOptions`)

**Interfaces:**
- Produces:
  - `data class Relay.Question(val q: String, val options: List<String>, val multi: Boolean = false)`
  - `object QuestionAnswers { toggle; complete; toAnswers }`
  - `Relay.decide(p, requestId, decision, answers: Map<String, Any>?)` and `CoucouViewModel.decide(card, decision, answers: Map<String, Any>? = null)`

- [ ] **Step 1: Write the failing tests**

Create `android/app/src/test/java/fr/louisraille/coucou/phone/QuestionAnswersTest.kt`:

```kotlin
package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuestionAnswersTest {
    private val single = Relay.Question("Which one?", listOf("A", "B"))
    private val multi = Relay.Question("Extras?", listOf("Tests", "Docs"), multi = true)

    @Test
    fun aSingleChoiceKeepsOnlyTheLastTap() {
        assertEquals(listOf("B"), QuestionAnswers.toggle(listOf("A"), "B", multi = false))
    }

    @Test
    fun aMultiChoiceTogglesEachOption() {
        var p = emptyList<String>()
        p = QuestionAnswers.toggle(p, "Tests", multi = true)
        p = QuestionAnswers.toggle(p, "Docs", multi = true)
        assertEquals(listOf("Tests", "Docs"), p)
        p = QuestionAnswers.toggle(p, "Tests", multi = true)
        assertEquals(listOf("Docs"), p)
    }

    @Test
    fun answersAreALabelOrAListAsTheHookTakesThem() {
        val picked = mapOf("Which one?" to listOf("B"), "Extras?" to listOf("Tests", "Docs"))
        assertTrue(QuestionAnswers.complete(listOf(single, multi), picked))
        assertEquals(
            mapOf("Which one?" to "B", "Extras?" to listOf("Tests", "Docs")),
            QuestionAnswers.toAnswers(listOf(single, multi), picked),
        )
        assertFalse(QuestionAnswers.complete(listOf(single, multi), mapOf("Which one?" to listOf("B"))))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "fr.louisraille.coucou.phone.QuestionAnswersTest"`
Expected: FAIL to compile. `QuestionAnswers` is missing, and `Question` has no `multi`.

- [ ] **Step 3: Write minimal implementation**

Create `android/app/src/main/java/fr/louisraille/coucou/phone/QuestionAnswers.kt`:

```kotlin
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
```

In `Relay.kt`:
- Change the `Question` declaration to `data class Question(val q: String, val options: List<String>, val multi: Boolean = false)`.
- In `parseCard`, change `Question(q.optString("q"), q.optJSONArray("options").toStrings())` to `Question(q.optString("q"), q.optJSONArray("options").toStrings(), q.optBoolean("multi"))`.
- Replace `decide` with:

```kotlin
    fun decide(p: Prefs.Pairing, requestId: String, decision: String, answers: Map<String, Any>?) {
        val body = auth(p).put("requestId", requestId).put("decision", decision)
        if (answers != null) {
            body.put("answers", JSONObject().apply {
                answers.forEach { (k, v) -> put(k, if (v is List<*>) JSONArray(v) else v) }
            })
        }
        post(p.worker, "decide", body)
    }
```

In `CoucouViewModel.kt`, change the `decide` signature to `fun decide(card: Relay.Card, decision: String, answers: Map<String, Any>? = null)`. The body is unchanged.

In `Components.kt`, give `OptionRow` a role parameter, with its look unchanged:

```kotlin
@Composable
fun OptionRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    role: Role = Role.RadioButton,
) {
```

and change `.clickable(role = Role.RadioButton) { onClick() }` to `.clickable(role = role) { onClick() }`.

In `Screens.kt`, add `import androidx.compose.ui.semantics.Role` and replace `QuestionOptions` with:

```kotlin
@Composable
private fun QuestionOptions(card: Relay.Card, vm: CoucouViewModel) {
    val picked = remember(card.requestId) { mutableStateMapOf<String, List<String>>() }
    val groups = card.questions.ifEmpty { listOf(Relay.Question(card.title, card.options)) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        groups.forEach { q ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (q.q.isNotBlank() && q.q != card.title) {
                    Text(q.q, color = Coucou.Ink, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                }
                q.options.forEach { opt ->
                    OptionRow(
                        label = opt,
                        selected = opt in picked[q.q].orEmpty(),
                        onClick = { picked[q.q] = QuestionAnswers.toggle(picked[q.q].orEmpty(), opt, q.multi) },
                        role = if (q.multi) Role.Checkbox else Role.RadioButton,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        PillButton(
            "Answer",
            onClick = { vm.decide(card, "answer", QuestionAnswers.toAnswers(groups, picked)) },
            filled = true,
            enabled = QuestionAnswers.complete(groups, picked),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
```

- [ ] **Step 4: Run tests and build**

Run: `cd android && ./gradlew :app:testDebugUnitTest && ./gradlew :app:assembleDebug`
Expected: PASS and success.

- [ ] **Step 5: Device check**

In Claude Code, ask for an AskUserQuestion with `multiSelect: true` (for example, "ask me which of tests/docs/lint to run, several allowed"). On the phone, tick two options and tap Answer. Claude Code receives both, and the terminal does not ask again.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/QuestionAnswers.kt android/app/src/test/java/fr/louisraille/coucou/phone/QuestionAnswersTest.kt android/app/src/main/java/fr/louisraille/coucou/phone/Relay.kt android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt android/app/src/main/java/fr/louisraille/coucou/phone/Components.kt android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt
git commit -m "Android: answer multi-select questions with several options"
```

---

### Task 4.5: Session urgency ranks like the Mac's

`Screens.kt:335-339` ranks `ratelimit` below `error`, and treats `dizzy` as idle. The Mac's `MochiActivityState.urgency` (`MochiActivityState.swift:31-40`) puts error, ratelimit and dizzy together, right after a question.

**Files:**
- Create: `android/app/src/main/java/fr/louisraille/coucou/phone/Urgency.kt`
- Create: `android/app/src/test/java/fr/louisraille/coucou/phone/UrgencyTest.kt`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt` (delete the private `urgencyOf`)

**Interfaces:**
- Produces: `internal fun urgencyOf(state: String): Int` (higher = more urgent; unchanged callers at `Screens.kt:276` and `:746`).

- [ ] **Step 1: Write the failing test**

Create `android/app/src/test/java/fr/louisraille/coucou/phone/UrgencyTest.kt`:

```kotlin
package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UrgencyTest {
    @Test
    fun rankedLikeTheMacsLiveActivity() {
        val order = listOf("approval", "question", "error", "working", "finished", "idle")
        val ranks = order.map(::urgencyOf)
        assertEquals(ranks.sortedDescending(), ranks)
        assertEquals(urgencyOf("error"), urgencyOf("ratelimit"))
        assertEquals(urgencyOf("error"), urgencyOf("dizzy"))
        assertEquals(urgencyOf("working"), urgencyOf("thinking"))
        assertEquals(urgencyOf("working"), urgencyOf("searching"))
        assertTrue(urgencyOf("question") >= 4) // still bold in the list (Screens.kt)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "fr.louisraille.coucou.phone.UrgencyTest"`
Expected: FAIL. `urgencyOf` is private in `Screens.kt`, so this is an unresolved reference.

- [ ] **Step 3: Write minimal implementation**

Create `android/app/src/main/java/fr/louisraille/coucou/phone/Urgency.kt`:

```kotlin
package fr.louisraille.coucou.phone

/**
 * How urgent a session's state is, higher first — the same order as the Mac's
 * MochiActivityState.urgency (which counts the other way, 0 = most urgent):
 * waiting for an OK, a question, something wrong (error, rate limit, dizzy),
 * working, finished, then everything else.
 */
internal fun urgencyOf(state: String): Int = when (state) {
    "approval" -> 5
    "question" -> 4
    "error", "ratelimit", "dizzy" -> 3
    "working", "thinking", "searching" -> 2
    "finished" -> 1
    else -> 0
}
```

Delete `private fun urgencyOf(state: String): Int = when (state) { … }` from `Screens.kt` (lines 335-339).

- [ ] **Step 4: Run tests**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/Urgency.kt android/app/src/test/java/fr/louisraille/coucou/phone/UrgencyTest.kt android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt
git commit -m "Android: session urgency ranks like the Mac"
```

---

### Task 4.6: The chat follows new lines; a Mochi out of sight stops asking for frames (V7, V10)

Two problems today:
- `Screens.kt:790` keys auto-scroll on `lines.size`, but the transcript is capped at 40 lines, so once full it never scrolls to a new line.
- `Mochi.kt:115-127` keeps `withFrameNanos` running every vsync while `!visible`, and only skips the state write.

**Files:**
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt:790`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Mochi.kt:111-128`

- [ ] **Step 1: Write the change**

There is nothing a JVM test can drive (Compose runtime). In `Screens.kt`, replace:

```kotlin
    LaunchedEffect(lines.size) {
```

with:

```kotlin
    // The transcript is capped at 40 lines: once full its size stays the same
    // while new lines arrive, so the newest line's text is part of the key.
    LaunchedEffect(lines.size, lines.lastOrNull()?.text) {
```

In `Mochi.kt`, replace the `if (animate) { LaunchedEffect(visible) { … } }` block with:

```kotlin
    if (animate) {
        LaunchedEffect(visible) {
            // Out of sight, no frame is asked for at all; back in sight, the
            // pose carries on from where it stopped.
            if (!visible) return@LaunchedEffect
            val base = time
            val start = System.nanoTime()
            var last = 0L
            while (isActive) {
                withFrameNanos { now ->
                    // ~30 fps is plenty for a tile; also cheap on 120 Hz screens.
                    if (now - last >= 33_000_000L) {
                        last = now
                        time = base + (now - start) / 1e9f
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: success.

- [ ] **Step 3: Device check**

1. Open a CLI session with more than 40 lines in Chat and send a message: the list scrolls to the new answer.
2. With the Home list scrolled so no Mochi tile is visible, Android Studio's profiler shows no frames being drawn.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/Screens.kt android/app/src/main/java/fr/louisraille/coucou/phone/Mochi.kt
git commit -m "Android: chat follows new lines; hidden Mochis stop asking for frames"
```

---

### Task 4.7: The pairing secret is encrypted at rest with the Android Keystore (A3)

`Prefs.kt` keeps the relay secret in plain SharedPreferences. That secret lets its holder approve permissions and run prompts on the PC, and CLAUDE.md says secrets live in secure storage.

**Files:**
- Create: `android/app/src/main/java/fr/louisraille/coucou/phone/SecretBox.kt`
- Create: `android/app/src/test/java/fr/louisraille/coucou/phone/SecretCodecTest.kt`
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Prefs.kt` (`load`, `save`)

**Interfaces:**
- Produces:
  - `interface Sealer { fun seal(plain: String): String; fun open(sealed: String): String? }`
  - `object KeystoreSealer : Sealer`
  - `object SecretCodec { fun read(stored: String?, sealer: Sealer): Pair<String?, String?>; fun write(secret: String, sealer: Sealer): String }`

- [ ] **Step 1: Write the failing tests**

Create `android/app/src/test/java/fr/louisraille/coucou/phone/SecretCodecTest.kt`:

```kotlin
package fr.louisraille.coucou.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SecretCodecTest {
    /** Stands in for the Keystore: reversible, and visibly not the plain text. */
    private val fake = object : Sealer {
        override fun seal(plain: String) = plain.reversed()
        override fun open(sealed: String) = if (sealed == "broken") null else sealed.reversed()
    }

    @Test
    fun aSealedSecretReadsBackWithNothingToRewrite() {
        val stored = SecretCodec.write("f".repeat(64), fake)
        assertEquals("f".repeat(64) to null, SecretCodec.read(stored, fake))
    }

    @Test
    fun aPlainSecretFromAnOlderBuildIsReadAndMigrated() {
        val (secret, rewrite) = SecretCodec.read("abc123", fake)
        assertEquals("abc123", secret)
        assertEquals(SecretCodec.write("abc123", fake), rewrite)
    }

    @Test
    fun aSecretThatCannotBeOpenedMeansPairAgain() {
        assertEquals(null to null, SecretCodec.read("ks1:broken", fake))
        assertNull(SecretCodec.read(null, fake).first)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests "fr.louisraille.coucou.phone.SecretCodecTest"`
Expected: FAIL to compile, `Unresolved reference: Sealer`.

- [ ] **Step 3: Write minimal implementation**

Create `android/app/src/main/java/fr/louisraille/coucou/phone/SecretBox.kt`:

```kotlin
package fr.louisraille.coucou.phone

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Turns a secret into what may sit in SharedPreferences, and back. */
interface Sealer {
    fun seal(plain: String): String
    /** Null when it cannot be opened (the key is gone): the phone pairs again. */
    fun open(sealed: String): String?
}

/**
 * AES-256-GCM with a key that never leaves the Android Keystore: the relay
 * secret can approve permissions on the PC, so it is not kept as plain text.
 */
object KeystoreSealer : Sealer {
    private const val ALIAS = "coucou-pairing"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun seal(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val data = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(data, Base64.NO_WRAP)
    }

    override fun open(sealed: String): String? = runCatching {
        val (iv, data) = sealed.split(':', limit = 2).let { it[0] to it[1] }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8)
    }.getOrNull()
}

/** The stored form of the secret: `ks1:` + what the sealer made of it. */
object SecretCodec {
    private const val PREFIX = "ks1:"

    fun write(secret: String, sealer: Sealer): String = PREFIX + sealer.seal(secret)

    /**
     * The secret from what is stored, and what to store instead when it was
     * still plain text (a pairing made by an older build): (secret, rewrite).
     */
    fun read(stored: String?, sealer: Sealer): Pair<String?, String?> = when {
        stored == null -> null to null
        stored.startsWith(PREFIX) -> sealer.open(stored.removePrefix(PREFIX)) to null
        else -> stored to write(stored, sealer)
    }
}
```

In `Prefs.kt`:
- Change the doc comment's first sentence to say the secret is kept sealed with the Android Keystore (`SecretBox.kt`).
- In `load`, replace `val secret = p.getString(K_SECRET, null) ?: return null` with:

```kotlin
        val (secret, rewrite) = SecretCodec.read(p.getString(K_SECRET, null), KeystoreSealer)
        if (rewrite != null) p.edit().putString(K_SECRET, rewrite).apply()
        if (secret == null) return null // cannot be opened any more: pair again
```

- In `save`, change `.putString(K_SECRET, pairing.secret)` to `.putString(K_SECRET, SecretCodec.write(pairing.secret, KeystoreSealer))`.

- [ ] **Step 4: Run tests and build**

Run: `cd android && ./gradlew :app:testDebugUnitTest && ./gradlew :app:assembleDebug`
Expected: PASS and success.

- [ ] **Step 5: Device check**

1. Install over a build that has a plain-text pairing: the app still works.
2. `adb shell run-as fr.louisraille.coucou.phone cat shared_prefs/coucou.xml` now shows `secret` starting with `ks1:`, and no 64-hex value.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/SecretBox.kt android/app/src/test/java/fr/louisraille/coucou/phone/SecretCodecTest.kt android/app/src/main/java/fr/louisraille/coucou/phone/Prefs.kt
git commit -m "Android: keep the relay secret sealed with the Android Keystore"
```

---

### Task 4.8: The open screen survives process death (A6)

`CoucouViewModel.screen` and `pickerAgent` live only in memory (`CoucouViewModel.kt:23,26`), so a process killed in the background reopens on Home.

**Files:**
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt`

- [ ] **Step 1: Write the change**

There is nothing a JVM test can drive (it needs the SavedState registry). Change the class header and the two fields, and route every change of them through `saved`:

```kotlin
class CoucouViewModel(app: Application, private val saved: SavedStateHandle) : AndroidViewModel(app) {

    enum class Screen { PAIR, HOME, PICKER, CHAT }

    var screen by mutableStateOf(initialScreen(app))
        private set
    /** Agent the PICKER screen lists sessions for ("devin", "claude", …). */
    var pickerAgent by mutableStateOf(saved.get<String>(K_AGENT) ?: "devin")
        private set

    private fun initialScreen(app: Application): Screen {
        val paired = Prefs.load(app) != null
        val restored = saved.get<String>(K_SCREEN)?.let { runCatching { Screen.valueOf(it) }.getOrNull() }
        return when {
            !paired -> Screen.PAIR
            restored != null && restored != Screen.PAIR -> restored
            else -> Screen.HOME
        }
    }

    private fun show(to: Screen) {
        screen = to
        saved[K_SCREEN] = to.name
    }

    private companion object {
        const val K_SCREEN = "screen"
        const val K_AGENT = "pickerAgent"
    }
```

Add `import androidx.lifecycle.SavedStateHandle`. Then replace every direct `screen = X` in the class with `show(X)`: in `navigate`, `openPicker`, `refresh` (Forbidden), `pair` (success) and `unpair`. In `openPicker` and `pickAgent`, add `saved[K_AGENT] = agent` after `pickerAgent = agent`. `MainActivity`'s `by viewModels()` already supplies a `SavedStateHandle` to this constructor shape.

- [ ] **Step 2: Build**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: success.

- [ ] **Step 3: Device check**

Open Chat, press Home, then run `adb shell am kill fr.louisraille.coucou.phone` and reopen the app from Recents: it opens on Chat.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/CoucouViewModel.kt
git commit -m "Android: the open screen survives process death"
```

---

## Phase 4 done when

- [ ] `cd android && ./gradlew :app:testDebugUnitTest` passes (4 test classes).
- [ ] `cd android && ./gradlew :app:assembleDebug` succeeds.
- [ ] The device checks in Tasks 4.1–4.4, 4.6, 4.7 and 4.8 pass on a phone paired with a relay that already runs Phase 1.
