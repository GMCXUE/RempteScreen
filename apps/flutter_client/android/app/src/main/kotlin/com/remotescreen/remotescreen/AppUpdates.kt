package com.remotescreen.remotescreen

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Installation remains a system confirmation, never a background package replacement. */
object AppUpdates {
    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("updateInfo", "updateCacheDir", "canInstallUpdate", "requestInstallUpdatePermission", "validateUpdate", "installUpdate", "consumeUpdateInstallResult")) return false
        try {
            val pm = activity.packageManager
            when (call.method) {
                "updateInfo" -> {
                    @Suppress("DEPRECATION") val info = pm.getPackageInfo(activity.packageName, 0)
                    val arch = when { Build.SUPPORTED_ABIS.contains("arm64-v8a") -> "arm64"; Build.SUPPORTED_ABIS.contains("x86_64") -> "x64"; else -> "armv7" }
                    @Suppress("DEPRECATION") val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                    result.success(mapOf("platform" to "android", "arch" to arch, "versionName" to info.versionName, "buildCode" to code))
                }
                "consumeUpdateInstallResult" -> result.success(UpdateSessionInstaller.consumeResult(activity))
                "updateCacheDir" -> result.success(File(activity.cacheDir, "updates").apply { mkdirs() }.absolutePath)
                "canInstallUpdate" -> result.success(Build.VERSION.SDK_INT < 26 || pm.canRequestPackageInstalls())
                "requestInstallUpdatePermission" -> {
                    if (Build.VERSION.SDK_INT >= 26) activity.startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                else -> {
                    // Hashing and archive inspection can take seconds; keep the UI thread free.
                    Thread {
                        try {
                            val file = validate(activity, call)
                            if (call.method == "installUpdate") {
                                if (Build.VERSION.SDK_INT >= 26 && !pm.canRequestPackageInstalls()) throw IllegalStateException("请先允许 RemoteScreen 安装应用")
                                UpdateSessionInstaller.install(activity.applicationContext, file, call.argument<String>("sha256")!!)
                            }
                            activity.runOnUiThread {
                                try {
                                    result.success(true)
                                } catch (e: Exception) { result.error("update_install", e.message ?: "无法打开安装页面", null) }
                            }
                        } catch (e: Exception) { activity.runOnUiThread { result.error("update_package", e.message ?: "安装包校验失败", null) } }
                    }.start()
                }
            }
        } catch (e: Exception) { result.error("update", e.message ?: "更新操作失败", null) }
        return true
    }
    @Suppress("DEPRECATION")
    private fun validate(activity: Activity, call: MethodCall): File {
        val sha = call.argument<String>("sha256") ?: error("缺少校验值")
        require(Regex("[a-f0-9]{64}").matches(sha)) { "安装包校验值无效" }
        val directory = File(activity.cacheDir, "updates").canonicalFile
        val file = File(call.argument<String>("path") ?: "").canonicalFile
        require(file.parentFile == directory && file.name == "$sha.apk" && file.isFile) { "安装包路径无效" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val bytes = ByteArray(65536); while (true) { val n = input.read(bytes); if (n < 0) break; digest.update(bytes, 0, n) } }
        require(digest.digest().joinToString("") { "%02x".format(it) } == sha) { "安装包校验失败，请重新下载" }
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val current = pm.getPackageInfo(activity.packageName, flags)
        val incoming = pm.getPackageArchiveInfo(file.path, flags) ?: error("无法读取安装包")
        require(incoming.packageName == activity.packageName) { "安装包不属于 RemoteScreen" }
        val expected = call.argument<Number>("buildCode")?.toLong() ?: error("缺少版本编号")
        val oldCode = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()
        val newCode = if (Build.VERSION.SDK_INT >= 28) incoming.longVersionCode else incoming.versionCode.toLong()
        require(newCode == expected && newCode > oldCode) { "安装包版本不符，请重新检查更新" }
        val oldSignatures = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
        val newSignatures = if (Build.VERSION.SDK_INT >= 28) incoming.signingInfo?.apkContentsSigners else incoming.signatures
        require(!oldSignatures.isNullOrEmpty() && !newSignatures.isNullOrEmpty() &&
            oldSignatures.map { it.toCharsString() }.toSet() == newSignatures.map { it.toCharsString() }.toSet()) { "安装包签名不一致，无法覆盖安装" }
        return file
    }
}
