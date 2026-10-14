package com.remotescreen.remotescreen

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class BackgroundServiceNotificationTest {
    @Test fun serviceStatusReplacesLegacyStandbyWithoutChangingChatOrCallChannels() {
        val context=RuntimeEnvironment.getApplication()
        val manager=context.getSystemService(NotificationManager::class.java)
        for(id in listOf("rs_messaging_status","rs_standby_v2","rs_messages_v2","rs_calls_v3"))
            manager.createNotificationChannel(NotificationChannel(id,id,NotificationManager.IMPORTANCE_HIGH))
        val first=BackgroundServiceNotification.create(context)
        manager.notify(BackgroundServiceNotification.ID,first)
        manager.notify(BackgroundServiceNotification.ID,BackgroundServiceNotification.create(context))
        assertEquals(1,manager.activeNotifications.size)
        assertEquals(BackgroundServiceNotification.CHANNEL,first.channelId)
        assertNull(manager.getNotificationChannel("rs_messaging_status"))
        assertNull(manager.getNotificationChannel("rs_standby_v2"))
        assertEquals(NotificationManager.IMPORTANCE_HIGH,manager.getNotificationChannel("rs_messages_v2").importance)
        assertEquals(NotificationManager.IMPORTANCE_HIGH,manager.getNotificationChannel("rs_calls_v3").importance)
        val channel=manager.getNotificationChannel(BackgroundServiceNotification.CHANNEL)
        assertEquals(NotificationManager.IMPORTANCE_MIN,channel.importance)
        assertNull(channel.sound);assertFalse(channel.shouldVibrate());assertFalse(channel.canShowBadge())
    }
}
