package com.remotescreen.remotescreen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 待命服务：让设备在后台也能收到「观看请求」并直接同意 / 拒绝。
 *
 * 为什么需要它：MIUI 等系统会冻结后台应用（logcat 里能看到 freezeUid ... reason=tobg），
 * 冻结后 Dart 侧的定时器全部停摆，请求就收不到了。前台服务带常驻通知，
 * 系统不会冻结进程，于是这里的原生轮询可以持续工作。
 *
 * 轮询与决策全部在原生层完成，不依赖 Flutter 引擎是否活跃。
 */
class RequestWatchService : Service() {

    companion object {
        private const val TAG = "RS-RequestWatch"
        private const val CHANNEL_STANDBY = "rs_standby_v2"
        private const val CHANNEL_REQUESTS = "rs_requests"
        private const val STANDBY_NOTIFICATION_ID = 1001

        const val ACTION_START = "com.remotescreen.remotescreen.START_WATCH"
        const val ACTION_STOP = "com.remotescreen.remotescreen.STOP_WATCH"
        const val ACTION_APPROVE = "com.remotescreen.remotescreen.APPROVE"
        const val ACTION_DENY = "com.remotescreen.remotescreen.DENY"

        private const val EXTRA_BASE_URL = "baseUrl"
        private const val EXTRA_DEVICE_ID = "deviceId"
        private const val EXTRA_SESSION_TOKEN = "sessionToken"
        private const val EXTRA_REQUEST_ID = "requestId"

        private const val POLL_INTERVAL_MS = 15_000L
        private const val PREFS = "rs_service"

        /** 由 Flutter 侧调用：带上设备凭据启动待命。 */
        fun start(context: Context, baseUrl: String, deviceId: String, sessionToken: String) {
            val intent = Intent(context, RequestWatchService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_BASE_URL, baseUrl)
                putExtra(EXTRA_DEVICE_ID, deviceId)
                putExtra(EXTRA_SESSION_TOKEN, sessionToken)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, RequestWatchService::class.java).apply {
                action = ACTION_STOP
            })
        }

        /** 通知栏「同意 / 拒绝」按钮的回调。 */
        fun actionIntent(context: Context, action: String, requestId: String): PendingIntent {
            val intent = Intent(context, RequestActionReceiver::class.java).apply {
                this.action = action
                putExtra(EXTRA_REQUEST_ID, requestId)
            }
            return PendingIntent.getBroadcast(
                context,
                (requestId + action).hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }

    @Volatile private var running = false
    private var worker: Thread? = null
    private lateinit var prefs: SharedPreferences
    private val notifiedRequests = mutableSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                running = false
                worker?.interrupt()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val baseUrl = intent.getStringExtra(EXTRA_BASE_URL)
                val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
                val sessionToken = intent.getStringExtra(EXTRA_SESSION_TOKEN)
                if (!baseUrl.isNullOrEmpty() && !deviceId.isNullOrEmpty() && !sessionToken.isNullOrEmpty()) {
                    // 落盘一份，进程被杀后重启还能继续待命
                    prefs.edit()
                        .putString(EXTRA_BASE_URL, baseUrl)
                        .putString(EXTRA_DEVICE_ID, deviceId)
                        .putString(EXTRA_SESSION_TOKEN, sessionToken)
                        .apply()
                }
            }
        }

        startForeground(STANDBY_NOTIFICATION_ID, standbyNotification())
        startPolling()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        super.onDestroy()
    }

    // MARK: - 轮询

    private fun startPolling() {
        if (running) return
        running = true
        worker = Thread {
            while (running) {
                try {
                    pollOnce()
                } catch (error: Throwable) {
                    Log.w(TAG, "轮询失败：${error.message}")
                }
                try {
                    Thread.sleep(POLL_INTERVAL_MS)
                } catch (interrupted: InterruptedException) {
                    break
                }
            }
        }.also { it.start() }
    }

    private fun pollOnce() {
        val baseUrl = prefs.getString(EXTRA_BASE_URL, null) ?: return
        val deviceId = prefs.getString(EXTRA_DEVICE_ID, null) ?: return
        val sessionToken = prefs.getString(EXTRA_SESSION_TOKEN, null) ?: return

        val body = JSONObject().put("sessionToken", sessionToken).toString()
        val response = request(
            "$baseUrl/v1/devices/$deviceId/heartbeat",
            "POST",
            body,
        ) ?: return

        val pending = response.optJSONArray("pendingRequests") ?: return
        for (index in 0 until pending.length()) {
            val item = pending.optJSONObject(index) ?: continue
            val requestId = item.optString("requestId")
            if (requestId.isEmpty() || notifiedRequests.contains(requestId)) continue
            notifiedRequests.add(requestId)
            notifyRequest(requestId, item.optString("viewerName", "未知设备"))
        }
    }

    // MARK: - 通知

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)

        // 前台服务必须挂通知，但把它压到最低优先级：
        // 状态栏无图标、不响铃、不打扰，通知栏里也只收在「静默」分组。
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_STANDBY, "待命状态", NotificationManager.IMPORTANCE_MIN).apply {
                description = "保持设备在线，随时接收观看请求（后台常驻，无提示）"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            },
        )
        // 清理上一版遗留的可见渠道，避免用户看到多余的开关
        manager.deleteNotificationChannel("rs_standby")
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_REQUESTS, "观看请求", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "有人请求观看本机屏幕时需要你确认"
            },
        )
    }

    private fun standbyNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_STANDBY)
            .setContentTitle("RemoteScreen 待命中")
            .setContentText("在线，可接收观看请求")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(open)
            .setOngoing(true)
            // 不显示时间、不显示角标，尽量不打扰（静音由渠道优先级控制）
            .setShowWhen(false)
            .setPriority(Notification.PRIORITY_MIN)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .build()
    }

    private fun notifyRequest(requestId: String, viewerName: String) {
        val content = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val approve = actionIntent(this, ACTION_APPROVE, requestId)
        val deny = actionIntent(this, ACTION_DENY, requestId)

        val notification = Notification.Builder(this, CHANNEL_REQUESTS)
            .setContentTitle("收到观看请求")
            .setContentText("「$viewerName」请求观看本机屏幕")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(content)
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, "同意", approve).build())
            .addAction(Notification.Action.Builder(null, "拒绝", deny).build())
            .build()

        getSystemService(NotificationManager::class.java)
            .notify(requestId.hashCode(), notification)
    }

    // MARK: - 网络

    private fun request(url: String, method: String, body: String?): JSONObject? {
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 10_000
                readTimeout = 10_000
                doOutput = body != null
                setRequestProperty("Content-Type", "application/json")
            }
            if (body != null) {
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            if (connection.responseCode >= 400) {
                Log.w(TAG, "$url → HTTP ${connection.responseCode}")
                null
            } else {
                val text = connection.inputStream.bufferedReader().use { it.readText() }
                if (text.isBlank()) JSONObject() else JSONObject(text)
            }
        } catch (error: Throwable) {
            Log.w(TAG, "请求 $url 失败：${error.message}")
            null
        } finally {
            connection?.disconnect()
        }
    }
}

/** 通知栏按钮回调：把决定发给服务端，并撤掉通知。 */
class RequestActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra("requestId") ?: return
        val approve = intent.action == RequestWatchService.ACTION_APPROVE
        val pending = goAsync()

        Thread {
            try {
                val prefs = context.getSharedPreferences("rs_service", Context.MODE_PRIVATE)
                val baseUrl = prefs.getString("baseUrl", null)
                val sessionToken = prefs.getString("sessionToken", null)
                if (baseUrl != null && sessionToken != null) {
                    val body = JSONObject()
                        .put("sessionToken", sessionToken)
                        .put("approve", approve)
                        .toString()
                    val connection = (URL("$baseUrl/v1/connect-requests/$requestId/decision")
                        .openConnection() as HttpURLConnection).apply {
                        requestMethod = "POST"
                        connectTimeout = 10_000
                        readTimeout = 10_000
                        doOutput = true
                        setRequestProperty("Content-Type", "application/json")
                    }
                    connection.outputStream.use { it.write(body.toByteArray()) }
                    Log.i("RS-RequestWatch", "决策已提交 approve=$approve → HTTP ${connection.responseCode}")
                    connection.disconnect()
                }
            } catch (error: Throwable) {
                Log.w("RS-RequestWatch", "提交决策失败：${error.message}")
            } finally {
                val manager = context.getSystemService(NotificationManager::class.java)
                manager.cancel(requestId.hashCode())
                pending.finish()
            }
        }.start()
    }
}
