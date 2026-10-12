package com.remotescreen.remotescreen

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

/** Keeps explicitly enabled call capture usable after the activity is hidden. */
class CallMediaService : Service() {
    companion object {
        private const val CHANNEL = "rs_call_media"
        private const val NOTIFICATION = 1003
        private data class Capture(val microphone: Boolean, val camera: Boolean, val active: Boolean)
        private val sessions = mutableMapOf<String, Capture>()
        private val pending = mutableMapOf<Int, MethodChannel.Result>()
        private var nextRequest = 0
        private data class Lease(val account: String, val client: String)
        @Volatile private var lease: Lease? = null
        fun clientForAccount(account: String): String? {
            val current = lease
            return MessagingPolicy.mediaClientForAccount(current?.account, current?.client, account)
        }

        fun update(context: Context, id: String, microphone: Boolean, camera: Boolean,
                   result: MethodChannel.Result, active: Boolean = false, callId: String? = null,
                   accountId: String? = null, clientId: String? = null, peerName: String? = null) {
            val candidate = sessions.toMutableMap()
            if (microphone || camera || active) candidate[id] = Capture(microphone, camera, active) else candidate.remove(id)
            if (candidate.isEmpty()) {
                sessions.clear()
                clearLease(context)
                context.stopService(Intent(context, CallMediaService::class.java))
                result.success(null)
                return
            }
            val request = ++nextRequest
            pending[request] = result
            val intent = Intent(context, CallMediaService::class.java).apply {
                putExtra("request", request)
                putExtra("id", id)
                putExtra("microphone", microphone)
                putExtra("camera", camera)
                putExtra("active", active)
                putExtra("callId", callId); putExtra("accountId", accountId)
                putExtra("clientId", clientId); putExtra("peerName", peerName)
                putExtra("anyMicrophone", candidate.values.any { it.microphone })
                putExtra("anyCamera", candidate.values.any { it.camera })
                putExtra("anyActive", candidate.values.any { it.active })
            }
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: Exception) {
                pending.remove(request)?.error("call_service_failed",
                    "请回到应用前台开启麦克风或摄像头，再切到后台继续通话", null)
            }
        }

        private fun clearLease(context: Context) {
            lease = null
            context.getSharedPreferences(MessagingService.PREFS, Context.MODE_PRIVATE).edit()
                .remove("activeCallId").remove("activeCallAccount").remove("activeCallClient").apply()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        val result = pending.remove(intent.getIntExtra("request", -1))
        try {
            val microphone = intent.getBooleanExtra("anyMicrophone", false)
            val camera = intent.getBooleanExtra("anyCamera", false)
            if (Build.VERSION.SDK_INT >= 26) {
                getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel(CHANNEL, "通话设备", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(this, 1003,
                Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra("messagingAction", "call")
                    putExtra("messagingCall", intent.getStringExtra("callId"))
                    putExtra("messagingAccount", intent.getStringExtra("accountId"))
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
                          else Notification.Builder(this)
            val notification = builder.setSmallIcon(android.R.drawable.ic_menu_call)
                .setContentTitle(intent.getStringExtra("peerName")?.let { "与 $it 通话中" } ?: "RemoteScreen 通话进行中")
                .setContentText(if (microphone && camera) "麦克风和摄像头已开启"
                    else if (camera) "摄像头已开启" else if (microphone) "麦克风已开启" else "点击返回通话")
                .setOngoing(true).setContentIntent(open).build()
            if (Build.VERSION.SDK_INT >= 29) {
                var types = if (intent.getBooleanExtra("anyActive", false)) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0
                if (microphone) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (camera) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                startForeground(NOTIFICATION, notification, types)
            } else startForeground(NOTIFICATION, notification)
            val id = intent.getStringExtra("id")!!
            val mic = intent.getBooleanExtra("microphone", false)
            val cam = intent.getBooleanExtra("camera", false)
            val active = intent.getBooleanExtra("active", false)
            if (mic || cam || active) sessions[id] = Capture(mic, cam, active) else sessions.remove(id)
            if (active) {
                val account = intent.getStringExtra("accountId")
                val client = intent.getStringExtra("clientId")
                val call = intent.getStringExtra("callId")
                if (!account.isNullOrBlank() && !client.isNullOrBlank() && !call.isNullOrBlank()) {
                    lease = Lease(account, client)
                    getSharedPreferences(MessagingService.PREFS, MODE_PRIVATE).edit()
                        .putString("activeCallId", call).putString("activeCallAccount", account)
                        .putString("activeCallClient", client).apply()
                }
            } else if (sessions.values.none { it.active }) clearLease(this)
            result?.success(null)
        } catch (error: Exception) {
            result?.error("call_service_failed",
                "后台通话服务启动失败，请回到应用前台检查麦克风和摄像头权限", null)
            if (sessions.isEmpty()) stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        sessions.clear()
        clearLease(this)
        super.onDestroy()
    }
}
