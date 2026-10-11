package com.coucou.android

import org.junit.Assert.assertEquals
import org.junit.Test

class AttributionTest {
    @Test fun nameAndRepoMatchPermission() {
        assertEquals("Coucou for Android", Attribution.APP_NAME)
        assertEquals("https://github.com/Louis-CFM/coucou", Attribution.REPO_URL)
    }
}
