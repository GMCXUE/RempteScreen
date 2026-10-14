package com.remotescreen.remotescreen

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.service.notification.StatusBarNotification

/** Independent children let SystemUI render several rows in a collapsed app group. */
internal object ChatNotifications {
    const val SUMMARY_TAG = "rs-message-summary"
    const val SUMMARY_ID = 49001
    const val ACCOUNT = "rs.account"
    const val PEER = "rs.peer"
    const val SEQUENCE = "rs.sequence"
    fun isMessage(tag:String?):Boolean = tag=="rs-message" || tag?.startsWith("rs-message:")==true
    fun tag(account:String,peer:String,seq:Long):String = "rs-message:$account:$peer:$seq"
    fun group(account:String):String = "rs-chats:$account"
    fun children(manager:NotificationManager,account:String):List<StatusBarNotification> =
        manager.activeNotifications.filter {it.tag?.startsWith("rs-message:")==true && it.notification.extras.getString(ACCOUNT)==account}
            .sortedWith(compareByDescending<StatusBarNotification> {it.notification.extras.getLong(SEQUENCE)}.thenByDescending {it.notification.`when`})
    fun clearPeer(manager:NotificationManager,account:String,peer:String) {
        manager.activeNotifications.filter {
            (it.tag=="rs-message" && it.id==peer.hashCode()) ||
            (it.tag?.startsWith("rs-message:")==true && it.notification.extras.getString(ACCOUNT)==account && it.notification.extras.getString(PEER)==peer)
        }.forEach {manager.cancel(it.tag,it.id)}
    }
    fun trim(manager:NotificationManager,account:String) {
        val perPeer=mutableMapOf<String,Int>();var count=0
        children(manager,account).forEach {
            val peer=it.notification.extras.getString(PEER) ?: ""
            val peerCount=(perPeer[peer] ?: 0)+1;perPeer[peer]=peerCount
            if(peerCount>5 || count>=20)manager.cancel(it.tag,it.id) else count++
        }
    }
    fun activity(context:Context,account:String,peer:String="",seq:Long=0):PendingIntent {
        val action=if(peer.isEmpty())"messages" else "message"
        val intent=Intent(context,MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            data=Uri.Builder().scheme("remotescreen-notice").authority(action).appendPath(account).appendPath(peer).appendPath(seq.toString()).build()
            putExtra("messagingAccount",account);putExtra("messagingAction",action);putExtra("messagingPeer",peer);putExtra("messagingSeq",seq)
        }
        return PendingIntent.getActivity(context,0,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    fun child(context:Context,account:String,peer:String,name:String,message:MessagePreview,preview:Boolean,sound:Boolean,alert:Boolean):Notification {
        val channel=if(sound)"rs_messages_v2" else "rs_messages_quiet"
        val title=if(preview)name else "RemoteScreen"
        val text=if(preview)message.text else "收到新消息"
        val extras=Bundle().apply {putString(ACCOUNT,account);putString(PEER,peer);putLong(SEQUENCE,message.seq)}
        return Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle(title).setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
            .setWhen(message.at).setShowWhen(true).setNumber(1).setOnlyAlertOnce(true)
            .setGroup(group(account)).setSortKey((Long.MAX_VALUE-message.seq).toString().padStart(19,'0'))
            .setGroupAlertBehavior(if(alert)Notification.GROUP_ALERT_CHILDREN else Notification.GROUP_ALERT_SUMMARY)
            .setContentIntent(activity(context,account,peer,message.seq)).setAutoCancel(true).addExtras(extras)
            .setDeleteIntent(MessageDismissReceiver.intent(context,account,peer,message.seq))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(if(preview)Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setContentTitle("RemoteScreen").setContentText("收到新消息").setVisibility(Notification.VISIBILITY_PUBLIC).build()).build()
    }
    fun refreshSummary(context:Context,account:String,preview:Boolean) {
        val manager=context.getSystemService(NotificationManager::class.java)
        trim(manager,account)
        val messages=children(manager,account)
        if(messages.size<2){manager.cancel(SUMMARY_TAG,SUMMARY_ID);return}
        val title="${messages.size} 条新消息"
        val style=Notification.InboxStyle().setBigContentTitle(title)
        messages.take(5).forEach {
            val e=it.notification.extras
            style.addLine(if(preview)"${e.getCharSequence(Notification.EXTRA_TITLE) ?: "好友"}：${e.getCharSequence(Notification.EXTRA_TEXT) ?: "新消息"}" else "收到新消息")
        }
        val n=Notification.Builder(context,"rs_messages_quiet").setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle("RemoteScreen").setContentText(title).setStyle(style).setNumber(messages.size)
            .setWhen(messages.first().notification.`when`).setShowWhen(true)
            .setGroup(group(account)).setGroupSummary(true).setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true).setContentIntent(activity(context,account)).setAutoCancel(true)
            .setDeleteIntent(MessageDismissReceiver.intent(context,account,"",0))
            .setVisibility(if(preview)Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(context,"rs_messages_quiet").setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setContentTitle("RemoteScreen").setContentText(title).setVisibility(Notification.VISIBILITY_PUBLIC).build()).build()
        try {manager.notify(SUMMARY_TAG,SUMMARY_ID,n)}catch(_:SecurityException){ /* Notification permission stays under system control. */ }
    }
}
