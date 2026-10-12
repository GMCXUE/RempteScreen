package com.remotescreen.remotescreen

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File
import java.lang.ref.WeakReference

/** System owns the staged APK. MIUI never has to open our private FileProvider. */
internal object UpdateSessionInstaller {
    private const val PREFS = "update-install-result"
    private var foreground = WeakReference<Activity>(null)
    @Volatile private var confirmation: Intent? = null

    fun onResume(activity: Activity) {
        foreground = WeakReference(activity)
        showConfirmation(activity)
    }
    fun onPause(activity: Activity) {
        if (foreground.get() === activity) foreground.clear()
    }
    private fun showConfirmation(activity: Activity) {
        val intent = confirmation ?: return
        try {
            activity.startActivity(intent)
            confirmation = null
        } catch (e: Exception) {
            Log.e("RemoteScreenUpdates", "Cannot open install confirmation", e)
            saveError(activity, "无法打开系统安装确认，请返回应用后重试")
        }
    }
    private fun saveError(context: Context, message: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("error", message).apply()
    }
    fun consumeResult(context: Context): Map<String, String> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val error = prefs.getString("error", "") ?: ""
        prefs.edit().remove("error").apply()
        return mapOf("error" to error)
    }
    fun install(context: Context, file: File, sha: String) {
        confirmation = null
        val installer = context.packageManager.packageInstaller
        // Retry replaces only this application's earlier update session.
        for (session in installer.mySessions.filter { it.appPackageName == context.packageName }) {
            try { installer.abandonSession(session.sessionId) } catch (_: Exception) {}
        }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            if (Build.VERSION.SDK_INT >= 33) setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
        }
        val id = installer.createSession(params)
        var committed = false
        try {
            installer.openSession(id).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    file.inputStream().use { input -> UpdatePackageStream.copyVerified(input, output, file.length(), sha) }
                    session.fsync(output)
                }
                val intent = Intent(context, UpdateInstallResultReceiver::class.java).apply {
                    action = "${context.packageName}.UPDATE_INSTALL_RESULT"
                    data = android.net.Uri.parse("remotescreen-update://session/$id")
                    addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
                }
                // PackageInstaller supplies status extras; immutable PendingIntents are rejected on API 35+.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val callback = PendingIntent.getBroadcast(context, id, intent, flags)
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt("session", id).remove("error").apply()
                session.commit(callback.intentSender)
                committed = true
            }
            Log.i("RemoteScreenUpdates", "APK staged in system install session $id")
        } finally {
            if (!committed) try { installer.abandonSession(id) } catch (_: Exception) {}
        }
    }
    fun result(context: Context, intent: Intent) {
        val expected = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt("session", -1)
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (sessionId != expected || intent.data?.lastPathSegment != sessionId.toString()) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        Log.i("RemoteScreenUpdates", "Install session $sessionId status $status")
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val pending = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            if (pending == null) { saveError(context, "系统未提供安装确认，请重试"); return }
            confirmation = pending
            foreground.get()?.let { showConfirmation(it) }
            return
        }
        confirmation = null
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("session").apply()
        if (status != PackageInstaller.STATUS_SUCCESS) {
            saveError(context, if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "安装已取消，可重新尝试更新"
                else "系统未完成安装，请重试。错误码：$status")
        }
    }
}

class UpdateInstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = UpdateSessionInstaller.result(context, intent)
}
