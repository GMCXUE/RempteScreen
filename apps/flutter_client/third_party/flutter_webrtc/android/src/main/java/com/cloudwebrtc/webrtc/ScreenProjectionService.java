package com.cloudwebrtc.webrtc;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * 投屏前台服务（mediaProjection 类型）。
 *
 * Android 14 起系统强制要求：调用 getMediaProjection() 之前，必须有一个
 * mediaProjection 类型的前台服务正在运行，否则抛 SecurityException。
 * Android 17（SDK 37）上该检查对所有 targetSdk 生效，无法绕过。
 *
 * 用法：采集开始前调用 start()，服务进入前台后通过 Listener 回调通知
 * 调用方继续采集流程；采集结束（用户停止或系统吊销授权）后调用 stop()。
 */
public class ScreenProjectionService extends Service {
    private static final String TAG = "ScreenProjectionService";
    private static final String CHANNEL_ID = "cloudwebrtc_screen_capture";
    private static final int NOTIFICATION_ID = 8130;

    /** 服务进入前台（可以开始采集）后的回调。 */
    public interface Listener {
        void onServiceReady();

        void onServiceFailed(String reason);
    }

    private static Listener pendingListener;

    /**
     * 启动前台服务。服务进入前台后回调 onServiceReady（主线程）。
     *
     * @return false 表示当前系统不需要/无法启动该服务（API 29 以下），
     *         调用方应直接走无前台服务的旧流程。
     */
    public static boolean start(Context context, Listener listener) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return false;
        }
        pendingListener = listener;
        Intent intent = new Intent(context, ScreenProjectionService.class);
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Exception e) {
            pendingListener = null;
            Log.w(TAG, "startForegroundService failed: " + e);
            return false;
        }
        return true;
    }

    /** 停止服务（采集结束时调用，无论哪一方先结束）。 */
    public static void stop(Context context) {
        try {
            context.stopService(new Intent(context, ScreenProjectionService.class));
        } catch (Exception ignored) {
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification notification = buildNotification();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
        } catch (Exception e) {
            Log.w(TAG, "startForeground failed: " + e);
            Listener l = pendingListener;
            pendingListener = null;
            if (l != null) {
                l.onServiceFailed("Failed to enter foreground: " + e.getMessage());
            }
            stopSelf();
            return START_NOT_STICKY;
        }
        Listener l = pendingListener;
        pendingListener = null;
        if (l != null) {
            l.onServiceReady();
        }
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm =
                    (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
                NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                        "屏幕采集", NotificationManager.IMPORTANCE_LOW);
                channel.setSound(null, null);
                channel.setShowBadge(false);
                nm.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setContentTitle("屏幕共享进行中")
                .setContentText("正在采集本机屏幕画面")
                .setSmallIcon(getApplicationInfo().icon)
                .setOngoing(true);
        return builder.build();
    }
}
