package com.remotescreen.remotescreen

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Account messaging survives page changes and Dart background timer suspension. */
class MessagingService : Service() {
    companion object {
        @Volatile private var instance: MessagingService? = null
        private val notices = java.util.concurrent.ConcurrentLinkedQueue<Map<String,String>>()
        fun diagnostics(context:Context):Map<String,Any> {
            val p=context.getSharedPreferences(PREFS,MODE_PRIVATE)
            val manager=context.getSystemService(NotificationManager::class.java)
            val audio=context.getSystemService(android.media.AudioManager::class.java)
            return mapOf("running" to (instance?.running==true),"notifications" to manager.areNotificationsEnabled(),
                "ringerMode" to audio.ringerMode,"lastPoll" to p.getLong("lastPoll",0),"error" to (p.getString("pollError","")?:""),
                "vibrator" to context.getSystemService(android.os.Vibrator::class.java).hasVibrator(),
                "dnd" to (manager.currentInterruptionFilter!=NotificationManager.INTERRUPTION_FILTER_ALL),
                "batteryUnrestricted" to context.getSystemService(android.os.PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName),
                "callAlerts" to ((manager.getNotificationChannel("rs_calls_v3")?:manager.getNotificationChannel("rs_calls_v2"))?.importance?:0),
                "messageAlerts" to (manager.getNotificationChannel("rs_messages_v2")?.importance?:0),
                "fullScreenCalls" to (Build.VERSION.SDK_INT<34 || manager.canUseFullScreenIntent()),
                "deliveryError" to (p.getString("deliveryError","")?:""),
                "lastNotificationAt" to p.getLong("lastNotificationAt",0))
        }
        fun test(context:Context,kind:String) {
            require(kind=="message"||kind=="call")
            context.startForegroundService(Intent(context,MessagingService::class.java).putExtra("testAlert",kind))
        }
        fun viewed(context:Context,account:String,peer:String,seq:Long) {
            val p=context.getSharedPreferences(PREFS,MODE_PRIVATE)
            if(p.getString("account","")!=account || peer.isEmpty())return
            val key="viewed:$account:$peer"
            p.edit().putLong(key,maxOf(p.getLong(key,0),seq,p.getLong("seen:$account:$peer",0))).apply()
            ChatNotifications.clearPeer(context.getSystemService(NotificationManager::class.java),account,peer)
            ChatNotifications.refreshSummary(context,account,JSONObject(settings(context)).optBoolean("messagePreview",true))
        }
        fun dismissed(context:Context,account:String,peer:String) {
            val p=context.getSharedPreferences(PREFS,MODE_PRIVATE)
            if(p.getString("account","")!=account)return
            val manager=context.getSystemService(NotificationManager::class.java)
            if(peer.isEmpty())ChatNotifications.children(manager,account).forEach {manager.cancel(it.tag,it.id)}
            // Swiping one child removes only that message; it is already in the delivery cursor.
            ChatNotifications.refreshSummary(context,account,JSONObject(settings(context)).optBoolean("messagePreview",true))
        }
        fun takeNotice(): Map<String,String>? = notices.poll()
        fun stopRing(id: String) { instance?.let { service ->
            synchronized(service.callNotificationLock) {
                service.stopped.add(id); service.manager.cancel("rs-call",id.hashCode())
                service.ringing.remove(id)
            }
            service.handler.post { if (service.ringId == id) service.silence() }
        } }
        fun settings(context: Context, value: String? = null): String {
            val prefs=context.getSharedPreferences(PREFS, MODE_PRIVATE)
            val key="alerts:"+prefs.getString("account", "")
            if(value!=null) { prefs.edit().putString(key,value).apply(); if(!JSONObject(value).optBoolean("messagePreview",true)) {
                val manager=context.getSystemService(NotificationManager::class.java);manager.activeNotifications.filter {ChatNotifications.isMessage(it.tag)||it.tag==ChatNotifications.SUMMARY_TAG}.forEach {manager.cancel(it.tag,it.id)}
            }; instance?.let { service -> service.handler.post {
                val config=JSONObject(value);val muted=config.optJSONArray("mutedPeers")?.let { list -> (0 until list.length()).any {list.getString(it)==service.ringPeer} } ?: false
                if(!config.optBoolean("callSound",true)||muted) service.silence()
            } } }
            return prefs.getString(key, "{\"messageSound\":true,\"callSound\":true,\"mutedPeers\":[]}")!!
        }
        const val PREFS = "rs_messaging"
        private const val STANDBY = 49000
        fun start(context: Context, baseUrl: String, token: String, account: String) {
            val prefs = context.getSharedPreferences(PREFS, MODE_PRIVATE)
            if (prefs.getString("account", "") != account) {
                clearNotifications(context); notices.clear(); instance?.handler?.post { instance?.silence() }
            }
            prefs.edit().putString("baseUrl", baseUrl).putString("token", token)
                .putString("account", account).apply()
            context.startForegroundService(Intent(context, MessagingService::class.java))
        }
        fun stop(context: Context) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove("token").remove("account").remove("peer").apply()
            notices.clear()
            clearNotifications(context)
            context.stopService(Intent(context, MessagingService::class.java))
        }
        private fun clearNotifications(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.activeNotifications.filter { ChatNotifications.isMessage(it.tag) || it.tag == "rs-call" || it.tag == "rs-friend" || it.tag == "rs-message-summary" }
                .forEach { manager.cancel(it.tag, it.id) }
        }
    }
    @Volatile private var running = false
    private var worker: Thread? = null
    private val prefs by lazy { getSharedPreferences(PREFS, MODE_PRIVATE) }
    private val manager by lazy { getSystemService(NotificationManager::class.java) }
    private val ringing = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val stopped = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val callNotificationLock = Any()
    @Volatile private var ringId = ""
    @Volatile private var ringPeer = ""
    private fun silence() {
        if(ringId.isNotEmpty()) {
            manager.cancel(if(ringId.startsWith("test-")) "rs-test" else "rs-call",ringId.hashCode())
            ringing.remove(ringId)
        }
        ringId="";ringPeer=""
    }
    private fun avatarResource(id:String):Int = when(id) {
        "dog" -> R.drawable.avatar_dog
        "fox" -> R.drawable.avatar_fox
        "rabbit" -> R.drawable.avatar_rabbit
        "bear" -> R.drawable.avatar_bear
        "panda" -> R.drawable.avatar_panda
        "penguin" -> R.drawable.avatar_penguin
        "owl" -> R.drawable.avatar_owl
        else -> R.drawable.avatar_cat
    }
    private val avatarCache = mutableMapOf<String,android.graphics.Bitmap>()
    private fun avatarBitmap(token:String,peer:String,id:String,revision:String):android.graphics.Bitmap {
        if(id=="custom" && revision.matches(Regex("[a-f0-9]{64}"))) {
            val key="${prefs.getString("account", "")}:$peer:$revision"
            avatarCache[key]?.let { return it }
            try {
                val value=api("avatar-image",token,JSONObject().put("peerId",peer).put("revision",revision)).getString("image")
                if(value.length<=410000 && value.startsWith("data:image/png;base64,")) {
                    val bytes=android.util.Base64.decode(value.substringAfter(','),android.util.Base64.DEFAULT)
                    val options=android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds=true }
                    android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size,options)
                    if(options.outWidth==256 && options.outHeight==256) {
                        android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size)?.let {
                            if(avatarCache.size>64)avatarCache.clear();avatarCache[key]=it;return it
                        }
                    }
                }
            }catch(_:Exception) { /* Keep alerts available even if the avatar cannot be fetched. */ }
        }
        return android.graphics.BitmapFactory.decodeResource(resources,avatarResource(id))
    }
    private fun postNotice(tag:String,id:Int,notification:Notification):Boolean {
        if(!manager.areNotificationsEnabled() || (manager.getNotificationChannel(notification.channelId)?.importance ?: NotificationManager.IMPORTANCE_NONE)==NotificationManager.IMPORTANCE_NONE) {
            prefs.edit().putString("deliveryError","系统通知或通知频道已关闭，请在消息与来电提醒中打开系统通知设置").apply();return false
        }
        return try {
            manager.notify(tag,id,notification)
            prefs.edit().putLong("lastNotificationAt",System.currentTimeMillis()).putString("lastNotificationChannel",notification.channelId).putString("deliveryError","").apply()
            true
        }catch(error:Exception) {
            prefs.edit().putString("deliveryError","通知提交失败（${error.javaClass.simpleName}）").apply();false
        }
    }
    private fun testAlert(kind:String) {
        val config=JSONObject(settings(this))
        if(kind=="call")silence()
        val id="test-${System.currentTimeMillis()}"
        val notification=Notification.Builder(this,if(kind=="call") { if(config.optBoolean("callSound",true)) "rs_calls_v3" else "rs_calls_quiet_v3" } else if(config.optBoolean("messageSound",true))"rs_messages_v2" else "rs_messages_quiet")
            .setSmallIcon(R.drawable.ic_stat_remotescreen).setContentTitle("RemoteScreen 提醒测试")
            .setContentText(if(kind=="call")"来电铃声与振动测试，6 秒后自动停止" else "这是一条本机测试通知")
            .setContentIntent(openIntent("open","","")).setAutoCancel(true).setTimeoutAfter(6000).build()
        if(kind=="call" && config.optBoolean("callSound",true))notification.flags=notification.flags or Notification.FLAG_INSISTENT
        if(postNotice("rs-test",id.hashCode(),notification) && kind=="call") {
            ringId=id;ringPeer="self-test";handler.postDelayed({if(ringId==id)silence()},6000)
        }
    }
    private fun foregroundMessage(account:String,peer:String,friend:JSONObject,name:String,text:String,preview:Boolean,sentAt:Long) {
        val title=if(preview)name else "RemoteScreen"
        val body=if(preview)text else "收到新消息"
        notices.offer(mapOf("accountId" to account,"peerId" to peer,"text" to "$title：$body",
            "name" to title,"message" to body,"preview" to preview.toString(),
            "avatarId" to (if(preview)friend.optString("avatarId","cat") else ""),
            "avatarRevision" to (if(preview)friend.optString("avatarRevision") else ""),
            "sentAt" to sentAt.toString(),
            "receivedAt" to System.currentTimeMillis().toString()))
        while(notices.size>20)notices.poll()
    }
    override fun onCreate() {
        super.onCreate(); instance=this
        // Upgrade: remove the old single-conversation cards, retain new child records.
        manager.activeNotifications.filter {it.tag=="rs-message"}.forEach {manager.cancel(it.tag,it.id)}
        manager.createNotificationChannel(NotificationChannel("rs_messages_v2", "聊天消息", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION),android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION).build())
            enableVibration(true);vibrationPattern=longArrayOf(0,180,100,180)
        })
        manager.createNotificationChannel(NotificationChannel("rs_messages_quiet", "聊天消息（静音）", NotificationManager.IMPORTANCE_HIGH).apply {setSound(null,null);enableVibration(false)})
        val oldCalls=manager.getNotificationChannel("rs_calls_v2")
        val importance=oldCalls?.importance?.coerceAtMost(NotificationManager.IMPORTANCE_HIGH) ?: NotificationManager.IMPORTANCE_HIGH
        manager.createNotificationChannel(NotificationChannel("rs_calls_v3", "语音和视频来电", importance).apply {
            setSound(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE),android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
            enableVibration(true);vibrationPattern=longArrayOf(0,400,800)
        })
        manager.createNotificationChannel(NotificationChannel("rs_calls_quiet_v3", "来电（静音）", importance).apply {setSound(null,null);enableVibration(false)})
        manager.createNotificationChannel(NotificationChannel("rs_messaging_status", "消息后台服务", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        if (!prefs.contains("client")) prefs.edit().putString("client", "notify-" + UUID.randomUUID()).apply()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (prefs.getString("token", "").isNullOrEmpty()) { stopSelf(); return START_NOT_STICKY }
        val ongoing = Notification.Builder(this, "rs_messaging_status").setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle("RemoteScreen").setContentText("接收聊天消息和通话邀请")
            .setContentIntent(openIntent("open", "", "")).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(STANDBY, ongoing, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        else startForeground(STANDBY, ongoing)
        if (!running) {
            running = true
            worker = Thread {
                while (running) {
                    try { poll();prefs.edit().putLong("lastPoll",System.currentTimeMillis()).putString("pollError","").apply() }
                    catch (_: InterruptedException) { break }
                    catch (error: Exception) {prefs.edit().putString("pollError", "消息同步失败（${error.javaClass.simpleName}），请检查网络并重新打开应用").apply();android.util.Log.w("RS-Messaging",error.javaClass.simpleName)}
                    try { Thread.sleep(4000) } catch (_: InterruptedException) { break }
                }
            }.apply { name = "RS-Messaging"; start() }
        }
        intent?.getStringExtra("testAlert")?.let { testAlert(it) }
        return START_STICKY
    }
    private fun api(path: String, token: String, body: JSONObject? = null): JSONObject {
        val base = prefs.getString("baseUrl", "")!!
        val connection = URL(base.trimEnd('/') + "/v1/social/" + path).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = if(path=="avatar-image")3000 else 8000; connection.readTimeout = if(path=="avatar-image")3000 else 8000
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            }
            if (connection.responseCode == 401) {
                if (prefs.getString("token", "") == token) { running = false; stop(this) }
                throw IllegalStateException("session ended")
            }
            if (connection.responseCode != 200) throw IllegalStateException("request failed")
            return connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
        } finally { connection.disconnect() }
    }
    private fun current(token: String) = running && prefs.getString("token", "") == token
    private fun poll() {
        val token = prefs.getString("token", "") ?: return
        val account = prefs.getString("account", "") ?: return
        // Renew the media owner before fetching chats/avatars, even when Dart is suspended.
        // A lease exists only in this live process and belongs to the signed-in account.
        val callClient = CallMediaService.clientForAccount(account) ?: prefs.getString("client", "")
        val calls = try { api("call-state", token, JSONObject().put("clientId", callClient)).getJSONArray("calls") }
            catch(error:Exception) { if(!current(token))return; null }
        if (!current(token)) return
        val data = api("state", token)
        if (!current(token)) return
        if(data.getJSONObject("me").getString("id")!=account)return
        val settings = JSONObject(settings(this))
        val muted=settings.optJSONArray("mutedPeers")?.let { list -> (0 until list.length()).map {list.getString(it)}.toSet() } ?: emptySet()
        val friends = data.getJSONArray("friends")
        val friendIds = (0 until friends.length()).map { friends.getJSONObject(it).getString("id") }.toSet()
        ChatNotifications.children(manager,account).filter {!friendIds.contains(it.notification.extras.getString(ChatNotifications.PEER))}.forEach {manager.cancel(it.tag,it.id)}
        for (index in 0 until friends.length()) {
            val friend = friends.getJSONObject(index)
            val peer = friend.getString("id")
            val key = "seen:$account:$peer"
            val raw=friend.optJSONArray("incomingMessages")
            val eligible=friend.optString("lastIncomingKind") !in listOf("call","recalled")
            val seq=if(raw!=null) {if(raw.length()>0)raw.getJSONObject(raw.length()-1).getString("seq").toLong() else 0L}
                else if(eligible)friend.optString("lastIncomingSeq","0").toLongOrNull() ?: 0L else 0L
            val unread = if (friend.optBoolean("blocked")) 0 else friend.optInt("unread")
            val visible = MainActivity.messagingForeground && prefs.getString("peer", "") == peer
            val viewedKey="viewed:$account:$peer"
            if(!prefs.contains(viewedKey))prefs.edit().putLong(viewedKey,friend.optString("notificationReadSeq","0").toLongOrNull() ?: 0).apply()
            if (MessageNoticePolicy.shouldClear(visible,friend.optBoolean("blocked"),muted.contains(peer))) {
                ChatNotifications.clearPeer(manager,account,peer)
                prefs.edit().putLong(viewedKey,maxOf(seq,prefs.getLong(viewedKey,0))).apply()
            }
            var delivered=true
            if (!friend.optBoolean("blocked") && !muted.contains(peer) && MessagingPolicy.shouldNotify(prefs.getLong(key, 0), seq, unread, visible,prefs.contains(key))) {
                val name = friend.optString("remark").ifEmpty { friend.getString("name") }
                val recent=if(raw==null) listOf(MessagePreview(seq,MessageNoticePolicy.boundedText(friend.optString("lastIncomingText")),0L)) else
                    (0 until raw.length()).map {i->raw.getJSONObject(i).let {MessagePreview(it.getString("seq").toLong(),MessageNoticePolicy.boundedText(it.optString("text")),it.optLong("createdAt"))}}
                val messages=MessageNoticePolicy.previews(recent,maxOf(prefs.getLong(viewedKey,0),prefs.getLong(key,0)))
                if(messages.isNotEmpty()) {
                    val preview=settings.optBoolean("messagePreview",true)
                    if (MainActivity.messagingForeground)foregroundMessage(account,peer,friend,name,messages.last().text,preview,messages.last().at)
                    val avatar=if(preview)avatarBitmap(token,peer,friend.optString("avatarId","cat"),friend.optString("avatarRevision")) else null
                    messages.forEachIndexed {messageIndex,message->
                        if(!current(token))return
                        if(!delivered)return@forEachIndexed
                        if(JSONObject(settings(this)).optBoolean("messagePreview",true)!=preview) {delivered=false;return@forEachIndexed}
                        val notification=ChatNotifications.child(this,account,peer,name,message,preview,settings.optBoolean("messageSound",true),messageIndex==messages.lastIndex,avatar)
                        delivered=postNotice(ChatNotifications.tag(account,peer,message.seq),0,notification)
                        if(delivered){prefs.edit().putLong(key,message.seq).apply();ChatNotifications.trim(manager,account)}
                    }
                }
            }
            if (delivered && (!prefs.contains(key) || prefs.getLong(key,0)<seq)) prefs.edit().putLong(key, seq).apply()
        }
        refreshMessageSummary(account,settings.optBoolean("messagePreview",true))
        val requests = data.getJSONArray("requests")
        val requestIds = (0 until requests.length()).map { requests.getJSONObject(it).getString("id").hashCode() }.toSet()
        manager.activeNotifications.filter { it.tag == "rs-friend" && !requestIds.contains(it.id) }.forEach { manager.cancel(it.tag, it.id) }
        for (index in 0 until requests.length()) {
            val request = requests.getJSONObject(index)
            val key = "request:$account:${request.getString("id")}:${request.optString("createdAt") }"
            if (!prefs.getBoolean(key, false)) {
                val delivered=postNotice("rs-friend", request.getString("id").hashCode(), Notification.Builder(this, if(settings.optBoolean("messageSound",true)) "rs_messages_v2" else "rs_messages_quiet")
                    .setSmallIcon(R.drawable.ic_stat_remotescreen).setContentTitle("新的好友申请")
                    .setContentText(request.getString("name") + " 希望添加你为好友")
                    .setContentIntent(openIntent("friends", "", "")).setAutoCancel(true).build())
                if(delivered)prefs.edit().putBoolean(key, true).apply()
            }
        }
        if (!current(token)) return
        if(calls==null)return
        val active = mutableSetOf<String>()
        for (index in 0 until calls.length()) {
            val call = calls.getJSONObject(index)
            if (call.optString("role") != "callee" || call.optString("status") != "ringing") continue
            val id = call.getString("id"); active.add(id)
            if(!MessagingPolicy.showIncomingCall(call.optString("status"),true,stopped.contains(id),call.optLong("createdAt")+45000,System.currentTimeMillis()))continue
            if (ringing.contains(id) && manager.activeNotifications.any { it.tag=="rs-call" && it.id==id.hashCode() }) continue
            val audible=settings.optBoolean("callSound",true) && !muted.contains(call.getString("peerId"))
            val video = call.optString("kind") == "video"
            val accept = openIntent("answer", call.getString("peerId"), id)
            val reject = openIntent("reject", call.getString("peerId"), id)
            val avatar=avatarBitmap(token,call.getString("peerId"),call.optString("peerAvatarId"),call.optString("peerAvatarRevision"))
            if(!current(token))return
            val builder = Notification.Builder(this, if(audible) "rs_calls_v3" else "rs_calls_quiet_v3").setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setLargeIcon(avatar).setContentTitle(call.getString("peerName")).setContentText(if (video) "视频来电" else "语音来电")
                .setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE)
                .setContentIntent(openIntent("call", call.getString("peerId"), id)).setOngoing(true)
                .setTimeoutAfter(MessagingPolicy.remainingRing(call.optLong("createdAt"), System.currentTimeMillis()))
            if (Build.VERSION.SDK_INT >= 31) builder.setStyle(Notification.CallStyle.forIncomingCall(
                Person.Builder().setName(call.getString("peerName")).setIcon(android.graphics.drawable.Icon.createWithBitmap(avatar)).setImportant(true).build(), reject, accept).setIsVideo(video))
            else { builder.addAction(Notification.Action.Builder(null, "挂断", reject).build()); builder.addAction(Notification.Action.Builder(null, "接通", accept).build()) }
            if(audible && !MainActivity.messagingForeground && (Build.VERSION.SDK_INT<34 || manager.canUseFullScreenIntent())) {
                builder.setFullScreenIntent(openIntent("call",call.getString("peerId"),id),true)
            }
            val notification = builder.build()
            if(audible)notification.flags=notification.flags or Notification.FLAG_INSISTENT
            // Avatar loading may finish after the user answers. Serialize the
            // final check and delivery with cancellation to avoid a stale alert.
            synchronized(callNotificationLock) {
                if(current(token) && MessagingPolicy.showIncomingCall(call.optString("status"),true,stopped.contains(id),call.optLong("createdAt")+45000,System.currentTimeMillis()) &&
                    postNotice("rs-call", id.hashCode(), notification)) {
                    ringing.add(id);ringId=id;ringPeer=call.getString("peerId")
                }
            }
        }
        handler.post { if(ringId.isNotEmpty() && !active.contains(ringId) && !ringId.startsWith("test-")) silence() }
        stopped.retainAll(active)
        ringing.filter { !active.contains(it) }.toList().forEach { manager.cancel("rs-call", it.hashCode()); ringing.remove(it) }
    }
    internal fun refreshMessageSummary(account:String,preview:Boolean) = ChatNotifications.refreshSummary(this,account,preview)
    private fun openIntent(action: String, peer: String, call: String,seq:Long=0): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("messagingAccount", prefs.getString("account", ""))
            putExtra("messagingSeq",seq);putExtra("messagingAction", action); putExtra("messagingPeer", peer); putExtra("messagingCall", call)
        }
        return PendingIntent.getActivity(this, (action + peer + call).hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    override fun onTaskRemoved(rootIntent:Intent?) {
        // Swiping the UI task must not stop this account's foreground service.
        MainActivity.messagingForeground=false
        prefs.edit().putBoolean("foreground",false).putLong("taskRemovedAt",System.currentTimeMillis()).apply()
        super.onTaskRemoved(rootIntent)
    }
    override fun onDestroy() {
        running = false; worker?.interrupt(); instance=null; handler.removeCallbacksAndMessages(null); silence(); notices.clear()
        ringing.forEach { manager.cancel("rs-call", it.hashCode()) }; ringing.clear()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
