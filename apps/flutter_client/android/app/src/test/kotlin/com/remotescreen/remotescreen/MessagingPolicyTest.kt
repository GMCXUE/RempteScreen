package com.remotescreen.remotescreen
import org.junit.Assert.*
import org.junit.Test

class MessagingPolicyTest {
    @Test fun answeredEndedAndLateStoppedCallsCannotShowIncomingAlerts() {
        assertTrue(MessagingPolicy.showIncomingCall("ringing",true,false,150,100))
        assertFalse(MessagingPolicy.showIncomingCall("active",true,false,150,100))
        assertFalse(MessagingPolicy.showIncomingCall("ended",true,false,150,100))
        assertFalse(MessagingPolicy.showIncomingCall("ringing",false,false,150,100))
        assertFalse(MessagingPolicy.showIncomingCall("ringing",true,true,150,100))
        assertFalse(MessagingPolicy.showIncomingCall("ringing",true,false,100,100))
    }
    @Test fun muteDecisionAndTimeoutNeverRestartRinging() {
        assertTrue(MessagingPolicy.canRing(true,false,false,150,100))
        assertFalse(MessagingPolicy.canRing(false,false,false,150,100))
        assertFalse(MessagingPolicy.canRing(true,true,false,150,100))
        assertFalse(MessagingPolicy.canRing(true,false,true,150,100))
        assertFalse(MessagingPolicy.canRing(true,false,false,100,100))
    }
    @Test fun anotherDevicesReadDoesNotHideNewArrival() {
        assertTrue(MessagingPolicy.shouldNotify(10,11,0,false,true))
        assertFalse(MessagingPolicy.shouldNotify(0,11,0,false,false))
    }
    @Test fun newMessageWithUnchangedUnreadCountStillNotifies() {
        assertTrue(MessagingPolicy.shouldNotify(10, 11, 1, false))
        assertFalse(MessagingPolicy.shouldNotify(11, 11, 1, false))
    }
    @Test fun readAndVisibleMessagesDoNotNotify() {
        assertFalse(MessagingPolicy.shouldNotify(10, 11, 0, false))
        assertFalse(MessagingPolicy.shouldNotify(10, 11, 1, true))
        assertTrue(MessagingPolicy.shouldNotify(0, 1, 1, false))
    }
    @Test fun lateIncomingNotificationDoesNotRingAnother45Seconds() {
        assertEquals(5000L, MessagingPolicy.remainingRing(100000, 140000))
        assertEquals(1000L, MessagingPolicy.remainingRing(100000, 150000))
        assertEquals(45000L, MessagingPolicy.remainingRing(100000, 90000))
    }
}

class MessageNoticePolicyTest {
    @Test fun longPreviewDoesNotSplitEmoji() {
        val text="😀".repeat(400)
        val shortened=MessageNoticePolicy.boundedText(text)
        assertEquals(300,shortened.codePointCount(0,shortened.length))
        assertEquals("😀".repeat(300),shortened)
    }
    @Test fun serverReadOnComputerDoesNotClearPhoneNotification() {
        assertFalse(MessageNoticePolicy.shouldClear(false,false,false))
        assertTrue(MessageNoticePolicy.shouldClear(true,false,false))
        assertTrue(MessageNoticePolicy.shouldClear(false,true,false))
        assertTrue(MessageNoticePolicy.shouldClear(false,false,true))
    }
    @Test fun burstKeepsNewestFiveInOrderAndExcludesLocallyViewed() {
        val rows=(1L..8L).reversed().map {MessagePreview(it,"message $it",it*1000)}
        assertEquals(listOf(6L,7L,8L),MessageNoticePolicy.previews(rows,5).map {it.seq})
        assertEquals(listOf(4L,5L,6L,7L,8L),MessageNoticePolicy.previews(rows+rows,0).map {it.seq})
        assertTrue(MessageNoticePolicy.previews(rows,8).isEmpty())
    }
}
