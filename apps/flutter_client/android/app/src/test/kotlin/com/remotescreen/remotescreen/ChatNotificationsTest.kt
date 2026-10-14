package com.remotescreen.remotescreen

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], application=Application::class)
class ChatNotificationsTest {
    private val context get()=RuntimeEnvironment.getApplication()
    private val manager get()=context.getSystemService(NotificationManager::class.java)
    @Before fun channels() {
        manager.createNotificationChannel(NotificationChannel("rs_messages_v2","聊天消息",NotificationManager.IMPORTANCE_HIGH))
        manager.createNotificationChannel(NotificationChannel("rs_messages_quiet","聊天消息（静音）",NotificationManager.IMPORTANCE_HIGH))
        context.getSharedPreferences(MessagingService.PREFS,0).edit().putString("account","account").apply()
    }
    private fun post(seq:Long,peer:String="peer",preview:Boolean=true) {
        val child=ChatNotifications.child(context,"account",peer,"测试小夏",MessagePreview(seq,"内容 $seq",1700000000000+seq),preview,true,seq==4L)
        manager.notify(ChatNotifications.tag("account",peer,seq),0,child)
    }
    @Test fun fourMessagesFromSamePeerHaveFourCollapsedChildrenAndOneSummary() {
        (1L..4L).forEach {post(it)}
        ChatNotifications.refreshSummary(context,"account",true)
        val children=ChatNotifications.children(manager,"account")
        assertEquals(4,children.size);assertEquals(5,manager.activeNotifications.size)
        assertEquals(4,children.map {it.tag}.toSet().size)
        children.forEach {
            assertEquals("rs-chats:account",it.notification.group)
            assertEquals("测试小夏",it.notification.extras.getCharSequence(Notification.EXTRA_TITLE))
            assertFalse(it.notification.extras.getString(Notification.EXTRA_TEMPLATE,"").contains("MessagingStyle"))
        }
        val summary=manager.activeNotifications.single {it.tag==ChatNotifications.SUMMARY_TAG}.notification
        assertTrue(summary.flags and Notification.FLAG_GROUP_SUMMARY != 0)
        assertEquals(4,summary.number)
        assertEquals("RemoteScreen",summary.extras.getCharSequence(Notification.EXTRA_TITLE))
        assertEquals(4,summary.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)!!.size)
    }
    @Test fun dismissingOneMessageRetainsOtherMessagesAndViewingChatClearsAll() {
        (1L..4L).forEach {post(it)}
        manager.cancel(ChatNotifications.tag("account","peer",2),0)
        MessageDismissReceiver().onReceive(context,Intent().putExtra("account","account").putExtra("peer","peer").putExtra("seq",2L))
        assertEquals(listOf(4L,3L,1L),ChatNotifications.children(manager,"account").map {it.notification.extras.getLong(ChatNotifications.SEQUENCE)})
        assertEquals(0L,context.getSharedPreferences(MessagingService.PREFS,0).getLong("viewed:account:peer",0))
        MessagingService.viewed(context,"account","peer",4)
        assertTrue(ChatNotifications.children(manager,"account").isEmpty())
    }
    @Test fun privateGroupHasNoSenderOrMessageContent() {
        post(1,preview=false);post(2,preview=false)
        ChatNotifications.refreshSummary(context,"account",false)
        manager.activeNotifications.forEach {
            val e=it.notification.extras
            assertFalse(e.toString().contains("测试小夏"));assertFalse(e.toString().contains("内容"))
        }
    }
    @Test fun trimmingKeepsFivePerPeerAndTwentyAcrossApp() {
        (1L..8L).forEach {post(it)}
        ChatNotifications.trim(manager,"account")
        assertEquals(listOf(8L,7L,6L,5L,4L),ChatNotifications.children(manager,"account").map {it.notification.extras.getLong(ChatNotifications.SEQUENCE)})
        for(peer in listOf("p2","p3","p4","p5")) (9L..13L).forEach {post(it,peer)}
        ChatNotifications.trim(manager,"account")
        assertEquals(20,ChatNotifications.children(manager,"account").size)
    }
    @Test fun tagsSeparateMessagesEvenWhenPeersHaveSameJavaHash() {
        assertEquals("Aa".hashCode(),"BB".hashCode())
        post(1,"Aa");post(1,"BB");post(2,"Aa")
        assertEquals(3,ChatNotifications.children(manager,"account").size)
    }
}
