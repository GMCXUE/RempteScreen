package com.remotescreen.remotescreen

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import org.robolectric.util.ReflectionHelpers
import android.graphics.BitmapFactory
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
            assertTrue(it.notification.extras.getString(Notification.EXTRA_TEMPLATE,"").contains("BigTextStyle"))
        }
        val summary=manager.activeNotifications.single {it.tag==ChatNotifications.SUMMARY_TAG}.notification
        assertTrue(summary.flags and Notification.FLAG_GROUP_SUMMARY != 0)
        assertEquals(4,summary.number)
        assertEquals("RemoteScreen",summary.extras.getCharSequence(Notification.EXTRA_TITLE))
        assertEquals(Notification.CATEGORY_MESSAGE,summary.category)
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
    @Test fun dismissingOldSummaryCannotEraseMessageThatArrivedAfterIt() {
        post(1);post(2)
        ChatNotifications.refreshSummary(context,"account",true)
        post(3)
        MessageDismissReceiver().onReceive(context,Intent().putExtra("account","account").putExtra("peer","").putExtra("seq",2L))
        assertEquals(listOf(3L),ChatNotifications.children(manager,"account").map {it.notification.extras.getLong(ChatNotifications.SEQUENCE)})
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
    @Test fun nativeChildHasOneSystemAvatarAndSystemHeaderTimestamp() {
        val at=System.currentTimeMillis()-120000
        val text="这是一条长消息".repeat(30)
        val n=ChatNotifications.child(context,"account","peer","测试小夏",MessagePreview(1,text,at),true,true,true,
            BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog))
        assertNotNull(n.getLargeIcon())
        assertEquals(at,n.`when`) // The system header uses the real send time.
        assertTrue(n.extras.getBoolean(Notification.EXTRA_SHOW_WHEN,false))
        assertEquals("私信了你：$text",n.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertEquals("私信了你：$text",n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        assertTrue(n.extras.getString(Notification.EXTRA_TEMPLATE,"").contains("BigTextStyle"))
        assertNull(n.contentView);assertNull(n.bigContentView);assertNull(n.headsUpContentView)
        assertTrue(n.publicVersion.extras.getBoolean(Notification.EXTRA_SHOW_WHEN,false))
    }
    @Test fun summaryRowsContainOnlySenderAndContentAndPrivateChildHasNoAvatar() {
        post(1);post(2)
        ChatNotifications.refreshSummary(context,"account",true)
        val n=manager.activeNotifications.single {it.tag==ChatNotifications.SUMMARY_TAG}.notification
        assertEquals(listOf("测试小夏：私信了你：内容 2","测试小夏：私信了你：内容 1"),n.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)!!.map {it.toString()})
        assertTrue(n.extras.getBoolean(Notification.EXTRA_SHOW_WHEN,false))
        assertTrue(n.publicVersion.extras.getBoolean(Notification.EXTRA_SHOW_WHEN,false))
        val private=ChatNotifications.child(context,"account","peer","敏感昵称",MessagePreview(3,"敏感正文",System.currentTimeMillis()),false,true,true,
            BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog))
        assertNull(private.getLargeIcon());assertNull(private.publicVersion.getLargeIcon())
        assertEquals("RemoteScreen",private.extras.getCharSequence(Notification.EXTRA_TITLE))
        assertEquals("收到新消息",private.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertEquals("收到新消息",private.extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        assertEquals("收到新消息",private.publicVersion.extras.getCharSequence(Notification.EXTRA_TEXT))
    }
    @Test fun xiaomiUsesOrdinaryNativeCardWithSenderHeaderAndSystemTimestamp() {
        val manufacturer=Build.MANUFACTURER
        try {
            ReflectionHelpers.setStaticField(Build::class.java,"MANUFACTURER","Xiaomi")
            val n=ChatNotifications.child(context,"account","peer","测试小夏",MessagePreview(1,"正文",123456L),true,true,true,
                BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog))
            assertNull(n.extras.getString(Notification.EXTRA_TEMPLATE))
            assertEquals("测试小夏",n.extras.getCharSequence(Notification.EXTRA_TITLE))
            assertEquals("私信了你：正文",n.extras.getCharSequence(Notification.EXTRA_TEXT))
            assertNotNull(n.getLargeIcon())
            assertTrue(n.extras.getBoolean(Notification.EXTRA_SHOW_WHEN,false))
            assertEquals(123456L,n.`when`)
            assertNull(n.contentView);assertNull(n.bigContentView);assertNull(n.headsUpContentView)
        } finally { ReflectionHelpers.setStaticField(Build::class.java,"MANUFACTURER",manufacturer) }
    }

}
