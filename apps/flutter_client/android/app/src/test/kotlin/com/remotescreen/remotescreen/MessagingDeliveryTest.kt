package com.remotescreen.remotescreen

import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import java.net.ServerSocket
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf

/** Exercise actual polling, persistence and Android notification submission together. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class MessagingDeliveryTest {
    private lateinit var service: MessagingService
    private lateinit var server: ServerSocket
    private lateinit var serverThread: Thread
    private lateinit var state: JSONObject
    private var beforeAvatar: (() -> Unit)? = null
    private val prefs get()=service.getSharedPreferences(MessagingService.PREFS,0)
    private val manager get()=service.getSystemService(NotificationManager::class.java)
    private val notices get()=ChatNotifications.children(manager,"account")
    @Before fun start() {
        service=Robolectric.buildService(MessagingService::class.java).create().get()
        MessagingService::class.java.getDeclaredField("running").apply {isAccessible=true}.set(service,true)
        MainActivity.messagingForeground=false
        server=ServerSocket(0,8,java.net.InetAddress.getByName("127.0.0.1"))
        serverThread=Thread {
            while(!server.isClosed) {
                val socket=try {server.accept()}catch(_:java.net.SocketException){break}
                socket.use {
                    val reader=it.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                    val path=reader.readLine().split(" ")[1]
                    var length=0
                    while(true) {
                        val line=reader.readLine() ?: break
                        if(line.isEmpty())break
                        if(line.startsWith("Content-Length:",true))length=line.substringAfter(':').trim().toInt()
                    }
                    repeat(length){reader.read()}
                    val response=if(path.endsWith("avatar-image")) {beforeAvatar?.invoke();"{\"image\":\"\"}"}
                        else if(path.endsWith("call-state"))"{\"calls\":[]}" else state.toString()
                    val bytes=response.toByteArray(Charsets.UTF_8)
                    val output=it.getOutputStream()
                    output.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(bytes);output.flush()
                }
            }
        }.apply {isDaemon=true;start()}
        prefs.edit().clear().putString("account","account").putString("token","token")
            .putString("baseUrl","http://127.0.0.1:${server.localPort}").apply()
        state=JSONObject().put("me",JSONObject().put("id","account")).put("friends",JSONArray()).put("requests",JSONArray())
    }
    @After fun stop() { server.close();serverThread.join(1000);service.onDestroy();MainActivity.messagingForeground=false }
    private fun messages(vararg sequences:Long, at:Long=System.currentTimeMillis()) {
        val rows=JSONArray(); sequences.forEach { rows.put(JSONObject().put("seq",it.toString()).put("text","内容 $it").put("createdAt",at)) }
        state.put("friends",JSONArray().put(JSONObject().put("id","peer").put("name","好友昵称").put("unread",sequences.size)
            .put("notificationReadSeq","0").put("incomingMessages",rows)))
    }
    private fun poll() { MessagingService::class.java.getDeclaredMethod("poll").apply {isAccessible=true}.invoke(service) }
    @Test fun backgroundBurstAlertsOnceThenSuppressesRepeatedAndOldSounds() {
        messages(1,2,3);poll()
        assertEquals(3,notices.size)
        assertEquals(1,notices.count {it.notification.groupAlertBehavior==Notification.GROUP_ALERT_CHILDREN})
        messages(2,3,4);poll()
        assertEquals(listOf(4L,3L,2L),notices.map {it.notification.extras.getLong(ChatNotifications.SEQUENCE)})
        assertEquals(Notification.GROUP_ALERT_SUMMARY,notices.first().notification.groupAlertBehavior)
        poll();assertEquals(3,notices.size)
        prefs.edit().remove("lastAlert:account").apply()
        messages(5,at=System.currentTimeMillis()-120000);poll()
        assertEquals(Notification.GROUP_ALERT_SUMMARY,notices.single().notification.groupAlertBehavior)
    }
    @Test fun foregroundUsesOnlyInAppNoticeAndCurrentChatIsSilent() {
        MainActivity.messagingForeground=true
        messages(1);poll()
        assertTrue(notices.isEmpty());assertEquals("内容 1",MessagingService.takeNotice()?.get("message"))
        prefs.edit().putString("peer","peer").apply()
        messages(2);poll()
        assertTrue(notices.isEmpty());assertNull(MessagingService.takeNotice())
    }
    @Test fun pausingBeforeBannerFrameRetriesAsSystemNotificationEvenWhenAnotherDeviceReadIt() {
        MainActivity.messagingForeground=true
        messages(1);poll()
        val notice=MessagingService.takeNotice()!!
        assertFalse(prefs.contains("seen:account:peer"))
        MainActivity.messagingForeground=false
        MessagingService.noticeShown(service,"account","peer",notice.getValue("seq").toLong())
        assertFalse(prefs.contains("seen:account:peer"))
        state.getJSONArray("friends").getJSONObject(0).put("unread",0)
        poll();assertEquals(1,notices.size);assertEquals(1L,prefs.getLong("seen:account:peer",0))
        poll();assertEquals(1,notices.size)
    }
    @Test fun displayedBannerIsAcknowledgedWithoutDuplicateBackgroundNotification() {
        MainActivity.messagingForeground=true
        messages(1);poll();MessagingService.takeNotice()
        MessagingService.noticeShown(service,"wrong-account","peer",1)
        assertFalse(prefs.contains("seen:account:peer"))
        MessagingService.noticeShown(service,"account","peer",1)
        assertEquals(1L,prefs.getLong("seen:account:peer",0))
        MainActivity.messagingForeground=false;poll();assertTrue(notices.isEmpty())
    }
    @Test fun oldBannerAcknowledgementCannotConsumeNewerPendingMessage() {
        MainActivity.messagingForeground=true
        messages(1);poll();MessagingService.takeNotice()
        messages(1,2);poll();MessagingService.takeNotice()
        MessagingService.noticeShown(service,"account","peer",1)
        assertEquals(2L,prefs.getLong("pending:account:peer",0))
        MainActivity.messagingForeground=false;poll()
        assertEquals(listOf(2L),notices.map {it.notification.extras.getLong(ChatNotifications.SEQUENCE)})
    }
    @Test fun disabledOrMutedChatStillAdvancesDeliveryWithoutCreatingUnreadSideEffects() {
        messages(1);poll();assertEquals(1,notices.size)
        MessagingService.settings(service,"{\"messageEnabled\":false}")
        assertTrue(notices.isEmpty())
        messages(2);poll();assertEquals(2L,prefs.getLong("seen:account:peer",0))
        MessagingService.settings(service,"{\"messageEnabled\":true}")
        poll();assertTrue(notices.isEmpty())
        MessagingService.settings(service,"{\"mutedPeers\":[\"peer\"]}")
        messages(3);poll();assertTrue(notices.isEmpty())
    }
    @Test fun revokedMessageAndRemovedFriendClearExistingNotifications() {
        messages(1,2);poll();assertEquals(2,notices.size)
        messages(1);poll();assertEquals(1,notices.size)
        state.put("friends",JSONArray());poll();assertTrue(notices.isEmpty())
    }
    @Test fun deniedSystemPermissionDoesNotConsumeDeliveryCursor() {
        shadowOf(manager).setNotificationsEnabled(false)
        messages(1);poll();assertFalse(prefs.contains("seen:account:peer"))
        shadowOf(manager).setNotificationsEnabled(true)
        poll();assertEquals(1,notices.size);assertEquals(1L,prefs.getLong("seen:account:peer",0))
    }
    @Test fun privateFriendRequestHidesNameAndDoesNotReplayOnServiceRestart() {
        MessagingService.settings(service,"{\"messagePreview\":false}")
        state.put("requests",JSONArray().put(JSONObject().put("id","new-peer").put("name","敏感姓名").put("createdAt",System.currentTimeMillis().toString())))
        poll()
        val notice=manager.activeNotifications.single()
        assertFalse(notice.notification.extras.toString().contains("敏感姓名"))
        manager.cancelAll();poll();assertTrue(manager.activeNotifications.isEmpty())
        MessagingService.settings(service,"{\"friendEnabled\":false}")
        state.getJSONArray("requests").getJSONObject(0).put("createdAt",(System.currentTimeMillis()+1).toString())
        poll();assertTrue(manager.activeNotifications.isEmpty())
    }
    @Test fun muteWhileAvatarLoadsCannotPostStaleContentOrConsumeDelivery() {
        messages(1)
        state.getJSONArray("friends").getJSONObject(0).put("avatarId","custom").put("avatarRevision","a".repeat(64))
        beforeAvatar={MessagingService.settings(service,"{\"mutedPeers\":[\"peer\"]}")}
        poll()
        assertTrue(notices.isEmpty());assertFalse(prefs.contains("seen:account:peer"))
        poll();assertEquals(1L,prefs.getLong("seen:account:peer",0))
    }
    @Test fun accountChangeWhileAvatarLoadsDiscardsOldAccountMessage() {
        messages(1)
        state.getJSONArray("friends").getJSONObject(0).put("avatarId","custom").put("avatarRevision","a".repeat(64))
        beforeAvatar={prefs.edit().putString("account","new-account").putString("token","new-token").apply()}
        poll();assertTrue(manager.activeNotifications.isEmpty())
        assertFalse(prefs.contains("seen:account:peer"))
    }
    @Test fun hidingPreviewClearsAlreadyPostedFriendIdentity() {
        state.put("requests",JSONArray().put(JSONObject().put("id","new-peer").put("name","敏感姓名").put("createdAt",System.currentTimeMillis().toString())))
        poll();assertTrue(manager.activeNotifications.single().notification.extras.toString().contains("敏感姓名"))
        MessagingService.settings(service,"{\"messagePreview\":false}")
        assertTrue(manager.activeNotifications.isEmpty())
    }
    @Test fun staleAccountDismissCannotClearCurrentAccount() {
        messages(1);poll()
        MessagingService.dismissed(service,"old-account","")
        assertEquals(1,notices.size)
        MessagingService.viewed(service,"old-account","peer",1)
        assertEquals(1,notices.size)
    }
}
