package com.remotescreen.remotescreen

import android.content.Context
import android.os.PowerManager

/** Keep the existing foreground sync loop alive while the screen is off.
 * Every acquisition expires: a hung worker cannot leave the CPU held indefinitely.
 */
internal class ScreenOffSyncLease(context: Context) {
    private val power = context.getSystemService(PowerManager::class.java)
    private val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "RemoteScreen:message-sync").apply {
        setReferenceCounted(false)
    }
    @Synchronized fun update(active: Boolean) {
        if (active && !power.isInteractive) lock.acquire(60_000L)
        else release()
    }
    @Synchronized fun release() { if (lock.isHeld) lock.release() }
    val held: Boolean get() = lock.isHeld
}
