package com.remotescreen.remotescreen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restore only a previously signed-in messaging session, without camera/mic. */
class MessagingRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        if(intent.action!=Intent.ACTION_BOOT_COMPLETED && intent.action!=Intent.ACTION_MY_PACKAGE_REPLACED)return
        val prefs=context.getSharedPreferences(MessagingService.PREFS,Context.MODE_PRIVATE)
        if(prefs.getString("token","").isNullOrEmpty())return
        try { context.startForegroundService(Intent(context,MessagingService::class.java)) }
        catch(error:Exception) { prefs.edit().putString("pollError","后台消息服务恢复失败（${error.javaClass.simpleName}），请打开应用检查后台运行设置").apply() }
    }
}
