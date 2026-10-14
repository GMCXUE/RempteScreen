package com.remotescreen.remotescreen

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.service.notification.StatusBarNotification

/** Independent children let SystemUI render several rows in a collapsed app group. */
internal object ChatNotifications {
    const val SUMMARY_TAG = "rs-message-summary"
    const val SUMMARY_ID = 49001
    const val ACCOUNT = "rs.account"
    const val PEER = "rs.peer"
    const val SEQUENCE = "rs.sequence"
    const val MESSAGE_TEXT = "rs.text"
    private fun roundAvatar(source:Bitmap):Bitmap {
        val image=Bitmap.createScaledBitmap(source,64,64,true)
        return Bitmap.createBitmap(64,64,Bitmap.Config.ARGB_8888).also {
            val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply {shader=BitmapShader(image,Shader.TileMode.CLAMP,Shader.TileMode.CLAMP)}
            Canvas(it).drawCircle(32f,32f,32f,paint)
        }
    }
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
    fun child(context:Context,account:String,peer:String,name:String,message:MessagePreview,preview:Boolean,sound:Boolean,alert:Boolean,avatar:Bitmap?=null):Notification {
        val channel=if(sound)"rs_messages_v2" else "rs_messages_quiet"
        val title=if(preview)name else "RemoteScreen"
        val text=if(preview)"私信了你：${message.text}" else "收到新消息"
        val picture=if(preview && avatar!=null)roundAvatar(avatar) else null
        val extras=Bundle().apply {putString(ACCOUNT,account);putString(PEER,peer);putLong(SEQUENCE,message.seq);putString(MESSAGE_TEXT,text)}
        val builder=Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle(title).setContentText(text)
            // Native children allow HyperOS to merge multiple messages into its
            // standard collapsed rows. Custom RemoteViews were split and folded.
            .setWhen(if(message.at>0)message.at else 0).setShowWhen(message.at>0).setNumber(1).setOnlyAlertOnce(true)
            .setGroup(group(account)).setSortKey((Long.MAX_VALUE-message.seq).toString().padStart(19,'0'))
            .setGroupAlertBehavior(if(alert)Notification.GROUP_ALERT_CHILDREN else Notification.GROUP_ALERT_SUMMARY)
            .setContentIntent(activity(context,account,peer,message.seq)).setAutoCancel(true).addExtras(extras)
            .setDeleteIntent(MessageDismissReceiver.intent(context,account,peer,message.seq))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(if(preview)Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setContentTitle("RemoteScreen").setContentText("收到新消息")
                .setWhen(if(message.at>0)message.at else 0).setShowWhen(message.at>0)
                .setVisibility(Notification.VISIBILITY_PUBLIC).build())
        // HyperOS expands ordinary native message cards with the sender in its
        // header. BigTextStyle moves that name into the body on the tested device.
        // Other Android surfaces need BigTextStyle for expandable long content.
        if(!Build.MANUFACTURER.equals("Xiaomi",ignoreCase=true))builder.setStyle(Notification.BigTextStyle().bigText(text))
        if(picture!=null)builder.setLargeIcon(picture)
        return builder.build()
    }
    fun friend(context:Context,account:String,id:String,name:String,preview:Boolean,alert:Boolean,action:PendingIntent):Notification {
        val channel=if(alert)"rs_messages_v2" else "rs_messages_quiet"
        return Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle("新的好友申请").setContentText(if(preview)"$name 希望添加你为好友" else "收到新的好友申请")
            .setContentIntent(action).setAutoCancel(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addExtras(Bundle().apply {putString(ACCOUNT,account);putString(PEER,id)})
            .setPublicVersion(Notification.Builder(context,channel).setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setContentTitle("RemoteScreen").setContentText("收到新的好友申请").build()).build()
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
            val body=e.getString(MESSAGE_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT) ?: "新消息"
            style.addLine(if(preview)"${e.getCharSequence(Notification.EXTRA_TITLE) ?: "好友"}：$body" else "收到新消息")
        }
        val n=Notification.Builder(context,"rs_messages_quiet").setSmallIcon(R.drawable.ic_stat_remotescreen)
            .setContentTitle("RemoteScreen").setContentText(title).setStyle(style).setNumber(messages.size)
            .setWhen(messages.first().notification.`when`).setShowWhen(messages.first().notification.`when`>0)
            .setGroup(group(account)).setGroupSummary(true).setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(true).setContentIntent(activity(context,account)).setAutoCancel(true)
            .setDeleteIntent(MessageDismissReceiver.intent(context,account,"",messages.first().notification.extras.getLong(SEQUENCE)))
            .setVisibility(if(preview)Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(context,"rs_messages_quiet").setSmallIcon(R.drawable.ic_stat_remotescreen)
                .setContentTitle("RemoteScreen").setContentText(title).setWhen(messages.first().notification.`when`).setShowWhen(messages.first().notification.`when`>0).setVisibility(Notification.VISIBILITY_PUBLIC).build()).build()
        try {manager.notify(SUMMARY_TAG,SUMMARY_ID,n)}catch(_:SecurityException){ /* Notification permission stays under system control. */ }
    }
}
