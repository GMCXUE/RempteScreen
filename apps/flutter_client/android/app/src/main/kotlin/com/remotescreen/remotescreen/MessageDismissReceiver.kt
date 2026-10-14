package com.remotescreen.remotescreen

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class MessageDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        MessagingService.dismissed(context,intent.getStringExtra("account") ?: "",intent.getStringExtra("peer") ?: "")
    }
    companion object {
        fun intent(context:Context,account:String,peer:String,seq:Long):PendingIntent = PendingIntent.getBroadcast(context,(account+peer).hashCode(),
            Intent(context,MessageDismissReceiver::class.java).setData(android.net.Uri.Builder().scheme("remotescreen-notice").authority("dismiss").appendPath(account).appendPath(peer).appendPath(seq.toString()).build()).putExtra("account",account).putExtra("peer",peer).putExtra("seq",seq),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
