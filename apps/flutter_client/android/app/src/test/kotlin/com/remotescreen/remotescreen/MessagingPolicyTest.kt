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
