package com.remotescreen.remotescreen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Both foreground services share one system-owned, separately blockable status. */
internal object BackgroundServiceNotification {
    const val ID = 49000
    const val CHANNEL = "rs_background_status"

    fun create(context: Context): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "后台运行状态", NotificationManager.IMPORTANCE_MIN).apply {
            description = "仅显示后台运行状态；关闭此分类不会关闭聊天、来电或设备连接提醒"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        })
        // Full-package upgrades restart these services before using the shared ID.
        manager.cancel(1001)
        manager.deleteNotificationChannel("rs_messaging_status")
        manager.deleteNotificationChannel("rs_standby_v2")
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle("RemoteScreen")
            .setContentText("后台接收消息、来电和设备连接提醒")
            .setContentIntent(open).setOngoing(true).setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .setPriority(Notification.PRIORITY_MIN)
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_DEFERRED)
        return builder.build()
    }
}
