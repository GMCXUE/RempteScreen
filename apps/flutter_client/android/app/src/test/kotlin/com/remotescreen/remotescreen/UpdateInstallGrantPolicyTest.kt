package com.remotescreen.remotescreen

import org.junit.Assert.*
import org.junit.Test

class UpdateInstallGrantPolicyTest {
    @Test fun miuiScannerReceivesGrantEvenWhenAnotherInstallerActivityResolves() {
        val targets = UpdateInstallGrantPolicy.recipients(
            listOf("com.android.packageinstaller"), listOf("com.miui.packageinstaller"))
        assertEquals(setOf("com.android.packageinstaller", "com.miui.packageinstaller"), targets)
    }
    @Test fun onlyDiscoveredAndInstalledPackagesAreUsedWithoutEmptyOrDuplicateRecipients() {
        val targets = UpdateInstallGrantPolicy.recipients(
            listOf("com.google.android.packageinstaller", ""),
            listOf("com.google.android.packageinstaller"))
        assertEquals(setOf("com.google.android.packageinstaller"), targets)
        assertFalse(targets.contains("com.miui.packageinstaller"))
    }
}
