package com.remotescreen.remotescreen

/** Known system scanners may differ from the Activity resolving ACTION_VIEW. */
internal object UpdateInstallGrantPolicy {
    val systemInstallerPackages = listOf(
        "com.miui.packageinstaller",
        "com.miui.global.packageinstaller",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
    )

    fun recipients(resolved: List<String>, installedSystemScanners: List<String>): Set<String> =
        (resolved + installedSystemScanners).filter { it.isNotBlank() }.toSet()
}
