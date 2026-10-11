package com.coucou.android

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin turns `var x` into `setX`, so a function with that name in the same class is a compile error ("platform
 * declaration clash") that only Gradle shows. Twice it cost a red CI run; this finds it on the JVM.
 */
class JvmNameClashTest {
    @Test fun noFunctionSharesTheNameOfAPropertySetter() {
        val dir = File("src/main/kotlin/com/coucou/android")
        val bad = ArrayList<String>()
        for (f in dir.walkTopDown().filter { it.extension == "kt" }) {
            val text = f.readText()
            // A `private var` or one with `private set` has no setter method, so it cannot clash.
            val lines = text.lines()
            val vars = lines.indices.mapNotNull { i ->
                val m = Regex("""^\s*((?:internal|public|override|lateinit|@\w+)\s+)*var\s+([a-z][A-Za-z0-9]*)\b""").find(lines[i]) ?: return@mapNotNull null
                val privateSet = lines[i].contains("private set") || lines.getOrNull(i + 1)?.trim() == "private set"
                if (privateSet) null else m.groupValues[2]
            }.toSet()
            for (name in vars) {
                val setter = "set" + name.replaceFirstChar { it.uppercase() }
                if (Regex("""\bfun\s+$setter\s*\(""").containsMatchIn(text)) bad.add("${f.name}: var $name and fun $setter")
            }
        }
        assertTrue(bad.toString(), bad.isEmpty())
    }
}
