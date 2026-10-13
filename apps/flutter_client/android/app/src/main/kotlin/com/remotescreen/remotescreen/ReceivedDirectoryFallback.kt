package com.remotescreen.remotescreen

/** A denied directory launch must still fall back to the system downloads UI. */
internal object ReceivedDirectoryFallback {
    fun open(directory: () -> Unit, downloads: () -> Unit): Boolean {
        for (launch in listOf(directory, downloads)) {
            try {
                launch()
                return true
            } catch (_: RuntimeException) {
                // OEM handlers can reject either the URI or the activity itself.
            }
        }
        return false
    }
}
