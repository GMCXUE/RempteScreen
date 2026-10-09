package com.remotescreen.remotescreen

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 原生能力桥：Flutter 侧通过它启停「待命服务」（后台接收观看请求）。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "remotescreen/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 9001)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
