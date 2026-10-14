package com.remotescreen.remotescreen

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection

/**
 * 原生能力桥：Flutter 侧通过它启停「待命服务」（后台接收观看请求）。
 */
class MainActivity : FlutterActivity() {
    companion object { @Volatile var messagingForeground = false }
    private val channelName = "remotescreen/native"
    private val pickFileRequestCode = 9002
    private var notificationPermissionRequested = false
    private var pendingCallPermission: MethodChannel.Result? = null
    private var pendingCallPermissions = emptyList<String>()
    private var pendingFilePicker: MethodChannel.Result? = null
    private var viewerFullscreen = false
    private var viewerPreviousSystemUi = 0
    private var nativeEvents: MethodChannel? = null
    private val videoOverlay by lazy { RemoteVideoOverlay(applicationContext) { callId, accountId ->
        startActivity(Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (!callId.isNullOrBlank() && !accountId.isNullOrBlank()) {
                putExtra("messagingAction", "call"); putExtra("messagingCall", callId); putExtra("messagingAccount", accountId)
            }
        })
    } }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 9003) return
        val result = pendingCallPermission ?: return
        pendingCallPermission = null
        val granted = pendingCallPermissions.all { checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }
        pendingCallPermissions = emptyList()
        if (granted) result.success(null)
        else result.error("call_permission_denied", "请在系统设置中允许 RemoteScreen 使用麦克风或摄像头", null)
    }

    override fun onResume() {
        super.onResume()
        messagingForeground = true
        UpdateSessionInstaller.onResume(this)
        getSharedPreferences(MessagingService.PREFS, MODE_PRIVATE).edit().putBoolean("foreground", true).apply()
    }
    override fun onPause() {
        messagingForeground = false
        UpdateSessionInstaller.onPause(this)
        getSharedPreferences(MessagingService.PREFS, MODE_PRIVATE).edit().putBoolean("foreground", false).apply()
        super.onPause()
    }
    private fun configureCallLockScreen(intent:Intent?) {
        val incoming=intent?.getStringExtra("messagingAction")=="call"
        if(Build.VERSION.SDK_INT>=27){setShowWhenLocked(incoming);setTurnScreenOn(incoming)}
    }
    override fun onCreate(savedInstanceState:android.os.Bundle?) {
        super.onCreate(savedInstanceState);configureCallLockScreen(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent); configureCallLockScreen(intent)
        nativeEvents?.invokeMethod("messagingActionReady", null)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && viewerFullscreen) applyViewerSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun applyViewerSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let { controller ->
                if (viewerFullscreen) {
                    controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(WindowInsets.Type.systemBars())
                } else {
                    controller.show(WindowInsets.Type.systemBars())
                }
            }
        } else {
            window.decorView.systemUiVisibility = if (viewerFullscreen) {
                viewerPreviousSystemUi or View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            } else viewerPreviousSystemUi
        }
    }

    override fun onDestroy() {
        pendingCallPermission?.error("call_permission_cancelled", "通话权限请求已取消，请重试", null)
        pendingCallPermission = null
        videoOverlay.dismiss()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).also { nativeEvents = it }
            .setMethodCallHandler { call, result ->
                if (AppUpdates.handle(this, call, result)) return@setMethodCallHandler
                when (call.method) {
                    "setViewerFullscreen" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled == viewerFullscreen) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        if (enabled && !viewerFullscreen) {
                            @Suppress("DEPRECATION")
                            viewerPreviousSystemUi = window.decorView.systemUiVisibility
                        }
                        viewerFullscreen = enabled
                        applyViewerSystemBars()
                        result.success(null)
                    }
                    "startMessagingService" -> {
                        val base = call.argument<String>("baseUrl")
                        val token = call.argument<String>("token")
                        val account = call.argument<String>("accountId")
                        if (base.isNullOrBlank() || token.isNullOrBlank() || account.isNullOrBlank()) {
                            result.error("invalid_arguments", "缺少账号凭据", null)
                        } else {
                            try { MessagingService.start(this, base, token, account); result.success(true) }
                            catch (_: Exception) { result.error("notification_service", "消息后台服务启动失败", null) }
                        }
                    }
                    "stopMessagingService" -> { MessagingService.stop(this); result.success(true) }
                    "openMessagingSettings" -> {
                        val kind=call.argument<String>("kind")?:"notifications"
                        val target=when(kind) {
                            "calls" -> if(Build.VERSION.SDK_INT>=34) Intent(android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,Uri.parse("package:$packageName")) else Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE,packageName)
                            "battery" -> Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            "autostart" -> Intent().setComponent(android.content.ComponentName("com.miui.securitycenter","com.miui.permcenter.autostart.AutoStartManagementActivity"))
                            else -> Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE,packageName)
                        }
                        try { startActivity(target);result.success(null) }
                        catch(_:Exception) {
                            try {startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:$packageName")));result.success(null)}
                            catch(_:Exception){result.error("notification_settings","无法打开系统设置，请手动打开 RemoteScreen 的通知与后台运行设置",null)}
                        }
                    }
                    "messagingDiagnostics" -> { result.success(MessagingService.diagnostics(this)) }
                    "testMessagingAlert" -> {
                        try { MessagingService.test(this,call.argument<String>("kind")?:"message");result.success(null) }
                        catch(_:Exception){result.error("test_alert","提醒测试启动失败，请重新登录",null)}
                    }
                    "messagingSettings" -> { result.success(MessagingService.settings(this,call.argument<String>("value"))) }
                    "takeMessagingNotice" -> { result.success(MessagingService.takeNotice()) }
                    "clearMessagingCall" -> {
                        configureCallLockScreen(null)
                        val id = call.argument<String>("callId")
                        if (!id.isNullOrBlank()) MessagingService.stopRing(id)
                        if (!id.isNullOrBlank()) getSystemService(android.app.NotificationManager::class.java).cancel("rs-call", id.hashCode())
                        result.success(null)
                    }
                    "setMessagingVisiblePeer" -> {
                        val peer=call.argument<String>("peerId") ?: ""
                        if(messagingForeground && peer.isNotEmpty())MessagingService.viewed(this,getSharedPreferences(MessagingService.PREFS,MODE_PRIVATE).getString("account","") ?: "",peer,0)

                        getSharedPreferences(MessagingService.PREFS, MODE_PRIVATE).edit()
                            .putString("peer", call.argument<String>("peerId") ?: "").apply()
                        result.success(null)
                    }
                    "takeMessagingAction" -> {
                        val action = intent?.getStringExtra("messagingAction")
                        if (action == null) result.success(null)
                        else {
                            val peer = intent.getStringExtra("messagingPeer") ?: ""
                            val id = intent.getStringExtra("messagingCall") ?: ""
                            if(action=="message")MessagingService.viewed(this,intent.getStringExtra("messagingAccount") ?: "",peer,intent.getLongExtra("messagingSeq",0))
                            intent.removeExtra("messagingAction")
                            if (id.isNotEmpty() && (action=="answer" || action=="reject")) {
                                MessagingService.stopRing(id)
                                getSystemService(android.app.NotificationManager::class.java).cancel("rs-call", id.hashCode())
                            }
                            result.success(mapOf("action" to action, "peerId" to peer, "callId" to id, "accountId" to (intent.getStringExtra("messagingAccount") ?: "")))
                        }
                    }
                    "hasVideoOverlayPermission" -> result.success(android.provider.Settings.canDrawOverlays(this))
                    "requestVideoOverlayPermission" -> {
                        val needsPermission = !android.provider.Settings.canDrawOverlays(this)
                        if (needsPermission) {
                            startActivity(Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")))
                        }
                        result.success(needsPermission)
                    }
                    "updateVideoOverlay" -> {
                        try {
                            val id = call.argument<String>("id") ?: throw IllegalArgumentException("缺少通话会话")
                            result.success(videoOverlay.update(id, call.argument<String>("trackId"),
                                call.argument<Boolean>("manual") ?: false,
                                call.argument<Boolean>("visible") ?: (call.argument<String>("trackId") != null),
                                call.argument<String>("callId"), call.argument<String>("accountId"),
                                call.argument<String>("kind") ?: "video", call.argument<String>("peerName"),
                                call.argument<Number>("acceptedAt")?.toLong()))
                        } catch (error: Exception) {
                            result.error("video_overlay_failed", "打开视频悬浮窗失败：${error.message}", null)
                        }
                    }
                    "startWatchService" -> {
                        val baseUrl = call.argument<String>("baseUrl")
                        val deviceId = call.argument<String>("deviceId")
                        val sessionToken = call.argument<String>("sessionToken")
                        if (baseUrl.isNullOrEmpty() || deviceId.isNullOrEmpty() || sessionToken.isNullOrEmpty()) {
                            result.error("invalid_arguments", "缺少设备凭据", null)
                        } else {
                            RequestWatchService.start(applicationContext, baseUrl, deviceId, sessionToken)
                            result.success(true)
                        }
                    }
                    "stopWatchService" -> {
                        RequestWatchService.stop(applicationContext)
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED && !notificationPermissionRequested) {
                            notificationPermissionRequested = true
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9001)
                        }
                        result.success(true)
                    }
                    "clipboardHasSystemFeedback" -> result.success(Build.VERSION.SDK_INT >= 33)
                    "copyChatImage" -> copyChatImage(call.argument<ByteArray>("bytes"), result)
                    "readChatImage" -> readChatImage(call.argument<String>("uri"), result)
                    "pickFile" -> openFilePicker(result)
                    "prepareCallCapture" -> {
                        val permissions = mutableListOf<String>()
                        if (call.argument<Boolean>("microphone") == true) permissions.add(android.Manifest.permission.RECORD_AUDIO)
                        if (call.argument<Boolean>("camera") == true) permissions.add(android.Manifest.permission.CAMERA)
                        val missing = permissions.filter { checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
                        if (missing.isEmpty()) result.success(null)
                        else if (pendingCallPermission != null) result.error("call_permission_busy", "正在请求通话权限，请稍后重试", null)
                        else {
                            pendingCallPermission = result; pendingCallPermissions = missing
                            requestPermissions(missing.toTypedArray(), 9003)
                        }
                    }
                    "updateCallService" -> {
                        val id = call.argument<String>("id")
                        if (id.isNullOrBlank()) result.error("invalid_arguments", "缺少通话会话", null)
                        else CallMediaService.update(this, id,
                            call.argument<Boolean>("microphone") ?: false,
                            call.argument<Boolean>("camera") ?: false, result,
                            call.argument<Boolean>("active") ?: false, call.argument<String>("callId"),
                            call.argument<String>("accountId"), call.argument<String>("clientId"), call.argument<String>("peerName"))
                    }
                    "openReceivedDirectory" -> {
                        val opened = ReceivedDirectoryFallback.open(directory = {
                            val directory = android.provider.DocumentsContract.buildDocumentUri(
                                "com.android.externalstorage.documents",
                                "primary:Download/RemoteScreen-Files",
                            )
                            startActivity(Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(directory, "vnd.android.document/directory")
                                // This URI belongs to the system DocumentsProvider. Our
                                // MediaStore write does not grant permission to re-share it.
                                // The file manager uses its own access to browse the folder.
                            })
                        }, downloads = {
                            startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS))
                        })
                        if (opened) result.success(null)
                        else result.error("open_directory_failed", "无法打开文件所在目录", null)
                    }
                    "saveReceivedFile" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val name = call.argument<String>("name")
                        if (sourcePath.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("invalid_arguments", "缺少待保存文件信息", null)
                        } else {
                            saveReceivedFile(sourcePath, name, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun readChatImage(sourceUri: String?, result: MethodChannel.Result) {
        // Only access the clipboard after the user explicitly requests a paste.
        val uri = try {
            if (sourceUri != null) Uri.parse(sourceUri) else {
                val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                val clip = clipboard.primaryClip
                if (clip == null || clip.itemCount == 0) null else clip.getItemAt(0).uri
            }
        } catch (_: Exception) {
            result.error("clipboard_failed", "无法读取剪贴板图片，请重新复制", null)
            return
        }
        if (uri == null || uri.scheme != "content") { result.success(null); return }
        Thread {
            try {
                val mime = contentResolver.getType(uri)
                if (mime != null && !mime.startsWith("image/")) {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }
                val bytes = contentResolver.openInputStream(uri)?.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > 8 * 1024 * 1024) throw IllegalArgumentException("图片过大，请选择 8 MB 以内的图片")
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } ?: throw java.io.IOException()
                val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                if (options.outMimeType !in listOf("image/jpeg", "image/png", "image/webp")) throw IllegalArgumentException("请选择 JPG、PNG 或 WebP 图片")
                if (options.outWidth <= 0 || options.outHeight <= 0) throw java.io.IOException()
                if (options.outWidth.toLong() * options.outHeight > 24_000_000) throw IllegalArgumentException("图片过大，请选择其他图片")
                val image = "data:${options.outMimeType};base64,${android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)}"
                runOnUiThread { result.success(image) }
            } catch (error: Exception) {
                val message = if (error is IllegalArgumentException) error.message else "无法读取剪贴板图片，请重新复制"
                runOnUiThread { result.error("clipboard_failed", message, null) }
            }
        }.start()
    }

    private fun copyChatImage(bytes: ByteArray?, result: MethodChannel.Result) {
        if (bytes == null || bytes.isEmpty() || bytes.size > 8 * 1024 * 1024) {
            result.error("invalid_image", "无法复制图片，请重试", null)
            return
        }
        Thread {
            try {
                val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                if (options.outMimeType != "image/jpeg" || options.outWidth <= 0 || options.outHeight <= 0 ||
                    options.outWidth.toLong() * options.outHeight > 24_000_000) throw IllegalArgumentException("invalid image")
                val folder = File(cacheDir, "chat-clipboard").apply { mkdirs() }
                // Retain recent copied URIs for paste/history; expose only this cache folder.
                folder.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L }
                    ?.forEach { it.delete() }
                val file = File(folder, "${java.util.UUID.randomUUID()}.jpg")
                file.writeBytes(bytes)
                val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.chatclipboard", file)
                runOnUiThread {
                    try {
                        val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                        clipboard.setPrimaryClip(android.content.ClipData.newUri(contentResolver, "聊天图片", uri))
                        result.success(null)
                    } catch (_: Exception) { result.error("clipboard_failed", "复制失败，请重试", null) }
                }
            } catch (_: Exception) {
                runOnUiThread { result.error("clipboard_failed", "复制失败，请重试", null) }
            }
        }.start()
    }

    private fun openFilePicker(result: MethodChannel.Result) {
        if (pendingFilePicker != null) {
            result.error("picker_busy", "文件选择器正在使用", null)
            return
        }
        pendingFilePicker = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, pickFileRequestCode)
        } catch (error: Exception) {
            pendingFilePicker = null
            result.error("picker_failed", "无法打开文件选择器：${error.message}", null)
        }
    }

    @Deprecated("FlutterActivity 仍通过该回调转发系统文件选择结果")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickFileRequestCode) return

        val result = pendingFilePicker ?: return
        pendingFilePicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }

        Thread {
            var cached: File? = null
            try {
                val (name, declaredSize) = queryFileInfo(uri)
                FileTransferLimit.check(declaredSize)
                val sendDir = File(cacheDir, "remotescreen-send").apply { mkdirs() }
                val safeName = safeFileName(name)
                val selectedCache = File(sendDir, "${System.currentTimeMillis()}-$safeName")
                cached = selectedCache
                val copied = contentResolver.openInputStream(uri)?.use { input ->
                    selectedCache.outputStream().buffered().use { output -> FileTransferLimit.copy(input, output) }
                } ?: throw IllegalStateException("无法读取所选文件")
                val size = copied
                runOnUiThread {
                    result.success(mapOf("path" to selectedCache.absolutePath, "name" to safeName, "size" to size))
                }
            } catch (error: Exception) {
                cached?.delete()
                runOnUiThread {
                    result.error("read_failed", "读取所选文件失败：${error.message}", null)
                }
            }
        }.start()
    }

    private fun queryFileInfo(uri: Uri): Pair<String, Long> {
        var name = "file"
        var size = -1L
        val cursor: Cursor? = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) name = it.getString(nameIndex) ?: name
                if (sizeIndex >= 0 && !it.isNull(sizeIndex)) size = it.getLong(sizeIndex)
            }
        }
        return Pair(name, size)
    }

    private fun saveReceivedFile(sourcePath: String, requestedName: String, result: MethodChannel.Result) {
        Thread {
            try {
                val source = File(sourcePath)
                if (!source.isFile) throw IllegalArgumentException("临时文件不存在")
                val safeName = safeFileName(requestedName)
                val savedName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveWithMediaStore(source, safeName)
                } else {
                    saveLegacy(source, safeName)
                }
                runOnUiThread {
                    result.success("下载/RemoteScreen-Files/$savedName")
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("save_failed", "保存接收文件失败：${error.message}", null)
                }
            }
        }.start()
    }

    private fun saveWithMediaStore(source: File, requestedName: String): String {
        val resolver = contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/RemoteScreen-Files/"
        val displayName = uniqueMediaStoreName(collection, relativePath, requestedName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(
                MediaStore.MediaColumns.MIME_TYPE,
                URLConnection.guessContentTypeFromName(displayName) ?: "application/octet-stream",
            )
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val destination = resolver.insert(collection, values)
            ?: throw IllegalStateException("无法创建下载文件")
        try {
            resolver.openOutputStream(destination, "w")?.use { output ->
                source.inputStream().buffered().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("无法写入下载文件")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(destination, values, null, null)
            return displayName
        } catch (error: Exception) {
            resolver.delete(destination, null, null)
            throw error
        }
    }

    private fun uniqueMediaStoreName(collection: Uri, relativePath: String, requestedName: String): String {
        val dot = requestedName.lastIndexOf('.')
        val stem = if (dot > 0) requestedName.substring(0, dot) else requestedName
        val extension = if (dot > 0) requestedName.substring(dot) else ""
        var candidate = requestedName
        var index = 1
        while (mediaStoreNameExists(collection, relativePath, candidate)) {
            candidate = "$stem ($index)$extension"
            index += 1
        }
        return candidate
    }

    private fun mediaStoreNameExists(collection: Uri, relativePath: String, name: String): Boolean {
        val cursor = contentResolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
            arrayOf(relativePath, name),
            null,
        )
        cursor?.use { return it.moveToFirst() }
        return false
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(source: File, requestedName: String): String {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "RemoteScreen-Files",
        ).apply { mkdirs() }
        val destination = uniqueFile(directory, requestedName)
        source.inputStream().buffered().use { input ->
            destination.outputStream().buffered().use { output -> input.copyTo(output) }
        }
        return destination.name
    }

    private fun uniqueFile(directory: File, requestedName: String): File {
        var candidate = File(directory, requestedName)
        if (!candidate.exists()) return candidate
        val dot = requestedName.lastIndexOf('.')
        val stem = if (dot > 0) requestedName.substring(0, dot) else requestedName
        val extension = if (dot > 0) requestedName.substring(dot) else ""
        var index = 1
        while (candidate.exists()) {
            candidate = File(directory, "$stem ($index)$extension")
            index += 1
        }
        return candidate
    }

    private fun safeFileName(name: String): String {
        val leaf = name.replace('\\', '/').substringAfterLast('/').trim()
        val cleaned = leaf.replace(Regex("[\\u0000-\\u001f]"), "_")
        return cleaned.ifBlank { "file" }
    }
}
