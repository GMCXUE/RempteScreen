package com.remotescreen.remotescreen

internal object MessagingPolicy {
    fun mediaClientForAccount(activeAccount: String?, activeClient: String?, account: String): String? =
        activeClient?.takeIf { activeAccount == account && it.matches(Regex("[a-zA-Z0-9_-]{16,100}")) }
    fun showIncomingCall(status:String, callee:Boolean, stopped:Boolean, expires:Long, now:Long):Boolean =
        status=="ringing" && callee && !stopped && expires>now
    fun shouldNotify(previous: Long, latest: Long, unread: Int, visible: Boolean, initialized:Boolean=false): Boolean =
        latest > previous && (unread > 0 || initialized) && !visible
    fun canRing(enabled:Boolean, muted:Boolean, stopped:Boolean, expires:Long, now:Long):Boolean =
        enabled && !muted && !stopped && expires>now
    fun remainingRing(createdAt: Long, now: Long): Long = (createdAt + 45000 - now).coerceIn(1000, 45000)
}
