package io.tablecircle.prototype;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

public final class ChatListenerService extends Service {
    private static final String CHANNEL = "chat_connection";
    private static final int NOTIFICATION_ID = 393;
    private static ChatListenerService instance;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable connect = this::connect;
    private ChatSyncJob.Worker listener;

    static void profileReady(Context context) {
        context.getSharedPreferences("chat_listener", MODE_PRIVATE)
            .edit().putBoolean("profile_ready", true).apply();
        sync(context);
    }

    private static boolean shouldRun(Context context) {
        return context.getSharedPreferences("chat_listener", MODE_PRIVATE)
                .getBoolean("profile_ready", false) && ChatSyncJob.hasProfile(context)
            && ChatAlerts.hasChatAlerts(context);
    }

    static void sync(Context context) {
        Intent service = new Intent(context, ChatListenerService.class);
        if (!shouldRun(context)) {
            if (instance != null) context.stopService(service);
            return;
        }
        if (instance != null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service);
            else context.startService(service);
        } catch (IllegalStateException | SecurityException ignored) {
            // A later launch can retry; the periodic job remains scheduled.
        }
    }

    static boolean isRunning() {
        return instance != null;
    }

    static void resumeListening() {
        if (instance != null) instance.scheduleConnect(1000);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL, "Background connection", NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_SECRET);
            getSystemService(NotificationManager.class).createNotificationChannel(channel);
        }
        try {
            startForeground(NOTIFICATION_ID, ChatAlerts.connectionNotification(this, CHANNEL));
        } catch (IllegalStateException | SecurityException ignored) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!shouldRun(this)) {
            stopSelf();
            return START_NOT_STICKY;
        }
        instance = this;
        resumeListening();
        return START_STICKY;
    }

    private void scheduleConnect(long delay) {
        main.removeCallbacks(connect);
        main.postDelayed(connect, delay);
    }

    private void connect() {
        if (listener != null || !ChatSyncJob.canListen()) return;
        if (!shouldRun(this)) {
            stopSelf();
            return;
        }
        listener = new ChatSyncJob.Worker(this, true, finished -> main.post(() -> {
            if (listener != finished) {
                // A replacement service may have waited for this worker to release Core.
                resumeListening();
                return;
            }
            listener = null;
            scheduleConnect(10000);
        }));
        listener.worker.start();
    }

    @Override
    public void onDestroy() {
        if (instance == this) instance = null;
        main.removeCallbacks(connect);
        if (listener != null) {
            listener.stop();
            listener = null;
        }
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }

    public static final class BootReceiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
                ChatSyncJob.schedule(context);
                sync(context);
            }
        }
    }
}
