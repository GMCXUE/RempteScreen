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
    // One audible message/request per account per ten seconds. Backlog stays silent.
    fun shouldAlert(lastAlert: Long, sentAt: Long, now: Long): Boolean =
        sentAt > 0 && sentAt <= now + 5000 && now - sentAt <= 60000 &&
            (lastAlert == 0L || now < lastAlert || now - lastAlert >= 10000)
    fun remainingRing(createdAt: Long, now: Long): Long = (createdAt + 45000 - now).coerceIn(1000, 45000)
}

internal data class MessagePreview(val seq: Long, val text: String, val at: Long)
internal object MessageNoticePolicy {
    fun boundedText(text: String): String = text.substring(0,text.offsetByCodePoints(0,minOf(300,text.codePointCount(0,text.length))))
    fun previews(messages: List<MessagePreview>, viewed: Long): List<MessagePreview> =
        messages.filter { it.seq > viewed }.distinctBy { it.seq }.sortedBy { it.seq }.takeLast(5)
    // Server unread belongs to all devices. Only this device viewing/clearing a chat clears its alert.
    fun shouldClear(visible: Boolean, blocked: Boolean, muted: Boolean): Boolean = visible || blocked || muted
}
