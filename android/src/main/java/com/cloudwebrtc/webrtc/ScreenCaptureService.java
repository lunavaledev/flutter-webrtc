package com.cloudwebrtc.webrtc;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

public class ScreenCaptureService extends Service {
    static final int TYPE_PROJECTION = 1;
    static final int TYPE_MICROPHONE = 2;

    private static final String TAG = FlutterWebRTCPlugin.TAG;
    private static final String CHANNEL_ID = "flutter_webrtc_screen_capture";
    private static final int NOTIFICATION_ID = 0x5244;
    private static final long START_TIMEOUT_MS = 3000;

    private static final Handler mainHandler = new Handler(Looper.getMainLooper());
    private static Runnable pendingReady;
    private static Runnable pendingFailed;
    private static int wantedTypes;
    private static int startedTypes;
    private static boolean running;
    private static int startGen;
    private static PowerManager.WakeLock wakeLock;

    static void ensure(Context context, int type, Runnable onReady, Runnable onFailed) {
        wantedTypes |= type;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            mainHandler.post(onReady);
            return;
        }
        if (running && (startedTypes & type) == type) {
            mainHandler.post(onReady);
            return;
        }
        queue(onReady, onFailed);
        final int gen = ++startGen;
        mainHandler.postDelayed(() -> {
            if (gen != startGen) return;
            if (running && (startedTypes & type) == type) {
                fireReady();
                return;
            }
            fireFailed();
        }, START_TIMEOUT_MS);
        try {
            Intent intent = new Intent(context, ScreenCaptureService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (Exception e) {
            Log.e(TAG, "ScreenCaptureService start failed", e);
            fireFailed();
        }
    }

    static void release(Context context, int type) {
        wantedTypes &= ~type;
        if (wantedTypes == 0) {
            pendingReady = null;
            pendingFailed = null;
            if (!running) return;
            context.stopService(new Intent(context, ScreenCaptureService.class));
            return;
        }
        if (running) {
            context.startService(new Intent(context, ScreenCaptureService.class));
        }
    }

    private static void queue(Runnable onReady, Runnable onFailed) {
        Runnable prevReady = pendingReady;
        Runnable prevFailed = pendingFailed;
        pendingReady = prevReady == null ? onReady : () -> {
            prevReady.run();
            onReady.run();
        };
        pendingFailed = prevFailed == null ? onFailed : () -> {
            prevFailed.run();
            onFailed.run();
        };
    }

    private static void fireReady() {
        startGen++;
        Runnable ready = pendingReady;
        pendingReady = null;
        pendingFailed = null;
        if (ready != null) ready.run();
    }

    private static void fireFailed() {
        startGen++;
        Runnable failed = pendingFailed;
        pendingReady = null;
        pendingFailed = null;
        if (failed != null) failed.run();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        try {
            applyForeground();
            acquireWakeLock();
            running = true;
            startedTypes = wantedTypes;
            mainHandler.post(ScreenCaptureService::fireReady);
        } catch (Exception e) {
            Log.e(TAG, "ScreenCaptureService startForeground failed", e);
            running = false;
            startedTypes = 0;
            stopSelf();
            mainHandler.post(ScreenCaptureService::fireFailed);
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        startedTypes = 0;
        wantedTypes = 0;
        releaseWakeLock();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void applyForeground() {
        Notification notification = buildNotification();
        int fgs = toFgsTypes(wantedTypes);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && fgs != 0) {
            startForeground(NOTIFICATION_ID, notification, fgs);
            return;
        }
        startForeground(NOTIFICATION_ID, notification);
    }

    private static int toFgsTypes(int types) {
        int fgs = 0;
        if ((types & TYPE_PROJECTION) != 0
                && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            fgs |= ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION;
        }
        if ((types & TYPE_MICROPHONE) != 0
                && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            fgs |= ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE;
        }
        return fgs;
    }

    private void acquireWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) return;
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm == null) return;
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rd:screen");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire();
    }

    private static void releaseWakeLock() {
        if (wakeLock == null) return;
        if (wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }

    private Notification buildNotification() {
        String title = (wantedTypes & TYPE_PROJECTION) != 0
                ? "正在共享屏幕"
                : (wantedTypes & TYPE_MICROPHONE) != 0 ? "正在使用麦克风" : "远程连接中";
        int icon = android.R.drawable.ic_media_play;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return new Notification.Builder(this)
                    .setContentTitle(title)
                    .setSmallIcon(icon)
                    .setOngoing(true)
                    .build();
        }
        NotificationManager manager =
                (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "屏幕共享", NotificationManager.IMPORTANCE_LOW);
        manager.createNotificationChannel(channel);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setSmallIcon(icon)
                .setOngoing(true)
                .build();
    }
}
