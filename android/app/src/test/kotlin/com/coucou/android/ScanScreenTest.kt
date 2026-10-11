package com.coucou.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-level guards for scanning the pairing code (the camera and Compose cannot run in a JVM test). */
class ScanScreenTest {
    private fun file(path: String) = File(path).readText()
    private fun src(name: String) = file("src/main/kotlin/com/coucou/android/$name")
    private val kotlinFiles get() = File("src/main/kotlin").walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    @Test fun theCameraIsReleasedWhenTheScreenIsLeftAndAfterAnAcceptedCode() {
        val ui = src("ui/ScanScreen.kt")
        val dispose = ui.substring(ui.lastIndexOf("onDispose {")).substringBefore("\n        }")
        assertTrue(dispose.contains("provider?.unbindAll()"))
        assertTrue(dispose.contains("analysis?.clearAnalyzer()"))
        assertTrue(dispose.contains("executor.shutdown()"))
        assertTrue("released at once when a code is accepted", ui.contains("done.set(true)") && ui.contains("provider?.unbindAll() }"))
        assertTrue("every frame is closed", ui.contains("image.close()"))
        assertTrue("bound to the screen's own lifecycle", ui.contains("bindToLifecycle(owner"))
    }

    @Test fun noPictureIsKeptOrSent() {
        val ui = src("ui/ScanScreen.kt") + src("scan/QrDecoder.kt")
        for (bad in listOf("ImageCapture", "VideoCapture", "\\bBitmap\\b", "compress\\(", "FileOutputStream", "openFileOutput", "MediaStore", "\\bURL\\(", "HttpURLConnection", "\\bSocket\\(")) {
            assertFalse("the scanner must not use $bad", Regex(bad).containsMatchIn(ui))
        }
        assertTrue("only the brightness plane is read", ui.contains("image.planes[0]"))
    }

    @Test fun theCameraIsAskedForOnlyOnTheScanScreenAfterTheUserTappedScan() {
        val ui = src("ui/ScanScreen.kt")
        assertTrue(ui.contains("launcher.launch(Manifest.permission.CAMERA)"))
        for (f in kotlinFiles.filter { it.name != "ScanScreen.kt" }) {
            assertFalse("${f.name} must not ask for the camera", f.readText().contains("Manifest.permission.CAMERA"))
        }
        assertTrue("a short reason is shown first", ui.contains("R.string.scan_why"))
        assertTrue("a way out when it is refused for good", ui.contains("ACTION_APPLICATION_DETAILS_SETTINGS") && ui.contains("R.string.scan_paste_instead"))
    }

    @Test fun theManifestAsksForTheCameraButDoesNotRequireOne_andKeepsTheCameraAppLink() {
        val m = file("src/main/AndroidManifest.xml")
        assertTrue(m.contains("android.permission.CAMERA"))
        assertTrue(Regex("""uses-feature\s+android:name="android.hardware.camera"\s+android:required="false"""").containsMatchIn(m))
        // the camera app's own scanner opens coucou://pair
        assertTrue(m.contains("""android:scheme="coucou" android:host="pair""""))
        assertTrue(m.contains("android.intent.category.BROWSABLE") && m.contains("android.intent.action.VIEW"))
    }

    @Test fun aLinkFromTheCameraAppAsksBeforeItPairs() {
        val main = src("MainActivity.kt")
        val handle = main.substringAfter("private fun handle(").substringBefore("val fp = i.getStringExtra")
        assertTrue(handle.contains("model.requestPairing("))
        assertFalse("a link must never pair without the user's OK", handle.contains("model.pair("))
        assertTrue(main.contains("model.pairRequest?.let { PairConfirm(model, it) }"))
        // and the confirmation names the computer, never the secret
        val confirm = src("ui/PairConfirm.kt")
        assertFalse(confirm.contains(".token") || confirm.contains("certSha256"))
        assertTrue(confirm.contains("model.confirmPairing()"))
    }

    @Test fun aScannedCodeGoesThroughTheSamePairingPathAsAPastedOne() {
        val model = src("app/AppModel.kt")
        val confirm = model.substringAfter("fun confirmPairing()").substringBefore("fun cancelPairing")
        assertTrue(confirm.contains("pair(link)"))
        assertTrue(src("core/PairingScan.kt").contains("PairingPayload.parse(t)"))
        assertTrue(src("MainActivity.kt").contains("onText = { text -> model.requestPairing(text)"))
    }

    @Test fun neitherTheTokenNorTheFingerprintNorTheScannedTextIsEverLogged() {
        val secrets = Regex("""\b(token|certSha256|fingerprint|pairRequest|pairing\.|payload|link|text)\b""")
        for (f in kotlinFiles) {
            f.readLines().filter { it.contains("Log.") || it.contains("println(") }.forEach { line ->
                // the arguments of the log call, without the tag
                val msg = line.substringAfter("Log.", "").substringAfter("(", "")
                assertFalse("${f.name}: $line", secrets.containsMatchIn(msg.substringAfter(",", msg)))
            }
        }
    }

    @Test fun theNewLibrariesAreCameraXAndZxingCoreOnly_noPlayServicesNoMlKit() {
        val g = file("build.gradle.kts")
        assertTrue(g.contains("androidx.camera:camera-core") && g.contains("com.google.zxing:core:"))
        for (bad in listOf("com.google.android.gms", "play-services", "mlkit", "firebase", "admob", "billingclient", "crashlytics", "camera-mlkit")) {
            assertFalse("build.gradle.kts must not mention $bad", g.contains(bad, ignoreCase = true))
        }
        assertTrue(File("../../.github/workflows/phone-link.yml").readText().contains("mlkit"))
    }

    @Test fun theScanButtonIsTheMainActionOfThePairingScreenAndPastingStays() {
        val ui = src("ui/PairingScreen.kt")
        assertTrue(ui.indexOf("R.string.scan_button") < ui.indexOf("R.string.pair_paste_short"))
        assertTrue(ui.contains("PillKind.PRIMARY") && ui.contains("R.string.demo_try"))
        assertTrue("paste lives in a sheet, with the clipboard shortcut", ui.contains("PasteSheet(") && ui.contains("R.string.pair_clipboard"))
        // a pasted link is checked by the same parser before anything is paired
        assertTrue(ui.contains("if (PairingPayload.parse(link) != null) { model.pair(link)"))
        assertTrue(src("MainActivity.kt").contains("if (model.mode == Mode.NONE) PairingScreen("))
    }
}
