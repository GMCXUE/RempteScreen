package com.remotescreen.remotescreen

import org.junit.Assert.*
import org.junit.Test

class CallBackgroundPolicyTest {
    @Test fun backgroundRenewsMediaOwnerInsteadOfNotificationIdentity() {
        val owner = "friend-client-1234567890"
        assertEquals(owner, MessagingPolicy.mediaClientForAccount("alice", owner, "alice"))
        // Switching accounts or losing the live service must not renew another call.
        assertNull(MessagingPolicy.mediaClientForAccount("alice", owner, "bob"))
        assertNull(MessagingPolicy.mediaClientForAccount(null, null, "alice"))
        assertNull(MessagingPolicy.mediaClientForAccount("alice", "", "alice"))
        assertNull(MessagingPolicy.mediaClientForAccount("alice", "invalid/client", "alice"))
    }
}
