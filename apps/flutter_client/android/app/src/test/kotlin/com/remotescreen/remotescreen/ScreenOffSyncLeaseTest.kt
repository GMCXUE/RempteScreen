package com.remotescreen.remotescreen

import android.app.Application
import android.os.PowerManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class ScreenOffSyncLeaseTest {
    private val context get()=RuntimeEnvironment.getApplication()
    private val power get()=shadowOf(context.getSystemService(PowerManager::class.java))
    @Test fun screenOffActiveSyncHoldsCpuAndScreenOnOrStopReleasesIt() {
        val lease=ScreenOffSyncLease(context)
        power.setIsInteractive(false);lease.update(false);assertFalse(lease.held)
        lease.update(true);assertTrue(lease.held)
        power.setIsInteractive(true);lease.update(true);assertFalse(lease.held)
        power.setIsInteractive(false);lease.update(true);assertTrue(lease.held)
        lease.release();assertFalse(lease.held)
        lease.release();assertFalse(lease.held)
    }
    @Test fun unresponsiveWorkerCannotKeepCpuHeldPastItsLeaseAndRenewalExtendsIt() {
        power.setIsInteractive(false)
        val lease=ScreenOffSyncLease(context);lease.update(true)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(50));lease.update(true)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(20));assertTrue(lease.held)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(41));assertFalse(lease.held)
    }
}
