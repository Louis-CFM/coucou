# R8 rules for the release build (minify and shrink are on; see app/build.gradle.kts).
#
# Why there are almost none: the app uses no reflection, no serialization library and no JNI. Everything the system starts (activities,
# services, receivers, the widget and the tile) is named in AndroidManifest.xml, which the build keeps by itself; Compose, CameraX,
# AndroidX and the Kotlin runtime bring their own consumer rules; ZXing is plain Java; the protocol is read with org.json by hand.
# What the app reads by name (settings keys, the protocol's field names, the sound table) is a string, not a class or member name.

# No debug logs in a release build. The Log calls are removed with their arguments, so the tags and messages are not in the APK
# (verifyReleaseNoLogs in build.gradle.kts checks that on every CI run). Nothing the app logs is a secret; this is for size and quiet.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}

# A crash trace is still readable with the mapping file (app/build/outputs/mapping/release/mapping.txt; keep it with the build you ship).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
