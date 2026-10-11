package com.coucou.android

import java.io.File

/** Locates the desktop reference sources (windows/src/...) so tests can compare against them. */
object ReferenceFiles {
    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            if (File(dir, "windows/src/core/pills.ts").exists()) return dir
            dir = dir.parentFile
        }
        error("repo root with windows/src not found from ${System.getProperty("user.dir")}")
    }

    fun read(path: String): String = File(repoRoot(), path).readText()
    fun file(path: String): File = File(repoRoot(), path)
}
