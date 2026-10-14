package com.remotescreen.remotescreen

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.graphics.BitmapFactory
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
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
    @Test fun singleMessageKeepsAvatarAndBottomRightSendTimeInAllContentLayouts() {
        val at=System.currentTimeMillis()-120000
        val avatar=BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog)
        val n=ChatNotifications.child(context,"account","peer","测试小夏",MessagePreview(1,"这是一条长消息".repeat(30),at),true,true,true,avatar)
        assertNotNull(n.getLargeIcon());assertEquals(at,n.`when`)
        val time=ChatNotifications.timeLabel(at)
        for(remote in listOf(n.contentView,n.bigContentView,n.headsUpContentView)) {
            assertNotNull(remote)
            val view=remote.apply(context,FrameLayout(context))
            val stamp=view.findViewById<TextView>(R.id.chat_notice_time)
            assertEquals(time,stamp.text.toString())
            assertEquals(Gravity.END,stamp.gravity and Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK)
            assertNotNull(view.findViewById<ImageView>(R.id.chat_notice_avatar).drawable)
            assertEquals("测试小夏",view.findViewById<TextView>(R.id.chat_notice_name).text.toString())
            view.measure(View.MeasureSpec.makeMeasureSpec(300,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(600,View.MeasureSpec.AT_MOST))
            view.layout(0,0,view.measuredWidth,view.measuredHeight)
            val body=view.findViewById<TextView>(R.id.chat_notice_body)
            assertTrue(stamp.right>=body.right)
            assertTrue(stamp.bottom>=body.bottom)
        }
        assertTrue(n.extras.getCharSequence(Notification.EXTRA_TEXT).toString().startsWith(time))
    }
    @Test fun foldedGroupSnippetsEachRetainTheirOwnSendTimeAndPrivateVersionHasNoAvatar() {
        val at=System.currentTimeMillis()-60000
        for(seq in 1L..2L) {
            val n=ChatNotifications.child(context,"account","peer","测试小夏",MessagePreview(seq,"正文 $seq",at-seq*60000),true,true,false,
                BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog))
            manager.notify(ChatNotifications.tag("account","peer",seq),0,n)
        }
        ChatNotifications.refreshSummary(context,"account",true)
        val children=ChatNotifications.children(manager,"account")
        children.forEach {
            assertTrue(it.notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString().startsWith(ChatNotifications.timeLabel(it.notification.`when`)))
        }
        val lines=manager.activeNotifications.single {it.tag==ChatNotifications.SUMMARY_TAG}.notification.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)!!
        children.zip(lines.toList()).forEach {(n,line)->assertTrue(line.toString().startsWith(ChatNotifications.timeLabel(n.notification.`when`)))}
        val private=ChatNotifications.child(context,"account","peer","敏感昵称",MessagePreview(3,"敏感正文",at),false,true,true,
            BitmapFactory.decodeResource(context.resources,R.drawable.avatar_dog))
        assertNull(private.getLargeIcon());assertNull(private.publicVersion.getLargeIcon())
        assertTrue(private.publicVersion.extras.getCharSequence(Notification.EXTRA_TEXT).toString().contains(ChatNotifications.timeLabel(at)))
        for(remote in listOf(private.contentView,private.bigContentView,private.headsUpContentView)) {
            val view=remote.apply(context,FrameLayout(context))
            assertEquals("RemoteScreen",view.findViewById<TextView>(R.id.chat_notice_name).text.toString())
            assertEquals("收到新消息",view.findViewById<TextView>(R.id.chat_notice_body).text.toString())
        }
    }
    @Test fun timestampsAreLocalAbsoluteSendTimesWithDateAndYearWhenNeeded() {
        val zone=java.util.TimeZone.getTimeZone("Asia/Shanghai")
        val parse=java.text.SimpleDateFormat("yyyy-MM-dd HH:mm",java.util.Locale.US).apply {timeZone=zone}
        val now=parse.parse("2026-10-14 15:00")!!.time
        assertEquals("12:34",ChatNotifications.timeLabel(parse.parse("2026-10-14 12:34")!!.time,now,zone))
        assertEquals("10/13 12:34",ChatNotifications.timeLabel(parse.parse("2026-10-13 12:34")!!.time,now,zone))
        assertEquals("2025/10/13 12:34",ChatNotifications.timeLabel(parse.parse("2025-10-13 12:34")!!.time,now,zone))
        assertEquals("时间未知",ChatNotifications.timeLabel(0,now,zone))
    }
}
