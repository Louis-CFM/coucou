import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing comes from the environment or from Gradle properties (-P on the command line, or ~/.gradle/gradle.properties), never
// from a file in this repository. Without all of them the release build is made unsigned (it cannot be installed) rather than
// signed with a debug key.
fun signingValue(name: String): String? = (System.getenv(name) ?: providers.gradleProperty(name).orNull)?.takeIf { it.isNotBlank() }
val releaseKeystore = signingValue("COUCOU_KEYSTORE_FILE")
val releaseStorePassword = signingValue("COUCOU_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("COUCOU_KEY_ALIAS")
val releaseKeyPassword = signingValue("COUCOU_KEY_PASSWORD") ?: releaseStorePassword

android {
    namespace = "com.coucou.android"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.coucou.android"
        minSdk = 30
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0"
        // English only: libraries' other languages are left out of the app too.
        resourceConfigurations += listOf("en")
    }
    signingConfigs {
        val keystore = releaseKeystore
        val storePass = releaseStorePassword
        val alias = releaseKeyAlias
        if (keystore != null && storePass != null && alias != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = storePass
                keyAlias = alias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            // Shrink, obfuscate and optimise with R8; unused resources go too. The rules (and why there are so few) are in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") // null: unsigned
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets["main"].java.srcDirs("src/main/kotlin")
    sourceSets["debug"].java.srcDirs("src/debug/kotlin") // the Widgets preview receiver: debug builds only
    sourceSets["test"].java.srcDirs("src/test/kotlin")
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    // Scanning the pairing QR code. CameraX (androidx) shows the camera; zxing-core (Apache 2.0, pure Java) reads the
    // code. Neither talks to any server; the reasoning is in the commit message.
    val cameraX = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraX")
    implementation("androidx.camera:camera-camera2:$cameraX")
    implementation("androidx.camera:camera-lifecycle:$cameraX")
    implementation("androidx.camera:camera-view:$cameraX")
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303") // android.jar stubs org.json in JVM tests
}

// Proves the release build in CI without a workflow change: CI runs `lint`, and lint now needs a release build that R8 has processed and
// whose code no longer carries the debug logs (the Log calls are removed by the rules, so their tags and messages must not be in the dex).
val verifyReleaseNoLogs by tasks.registering {
    group = "verification"
    description = "Builds the release APK and fails if a debug log tag or message is still in it."
    dependsOn("assembleRelease")
    val apkDir = layout.buildDirectory.dir("outputs/apk/release")
    doLast {
        val apks = apkDir.get().asFile.walkTopDown().filter { it.extension == "apk" }.toList()
        check(apks.size == 1) { "expected one release APK, found ${apks.size}" }
        val leftovers = listOf("CoucouOverlay", "CoucouLaunch", "CoucouDiscovery", "CoucouIsland", "island failed", "cannot browse", "ignored an early tap")
        ZipFile(apks.single()).use { zip ->
            for (entry in zip.entries().asSequence().filter { it.name.endsWith(".dex") }) {
                val text = String(zip.getInputStream(entry).readBytes(), Charsets.ISO_8859_1)
                for (word in leftovers) check(!text.contains(word)) { "'$word' is still in ${entry.name}: the debug logs were not stripped" }
            }
        }
    }
}
tasks.matching { it.name == "lint" }.configureEach { dependsOn(verifyReleaseNoLogs) }
