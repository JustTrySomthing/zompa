package io.tablecircle.prototype;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import androidx.core.app.NotificationCompat;

final class ChatAlerts {
    private static final String CHANNEL = "friend_activity";
    private static final String CALL_CHANNEL = "incoming_calls";
    static final String OPEN_CHATS = "io.zompado.OPEN_CHATS";
    static final String CALL_CHAT = "callChat";
    static final String CALL_MESSAGE = "callMessage";

    static void setup(Context context) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            manager.createNotificationChannel(
                new NotificationChannel(CHANNEL, "Friend activity", NotificationManager.IMPORTANCE_DEFAULT));
            manager.createNotificationChannel(
                new NotificationChannel(CALL_CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH));
        }
    }

    static boolean enabled(Context context) {
        return enabled(context, CHANNEL);
    }

    static boolean callsEnabled(Context context) {
        return enabled(context, CALL_CHANNEL);
    }

    private static boolean enabled(Context context, String channel) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (!manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT < 26) return true;
        setup(context);
        return manager.getNotificationChannel(channel).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    static synchronized void post(Context context, int chat, int message, String title) {
        if (chat <= 0 || message <= 0 || !enabled(context)) return;
        var history = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        String key = "last_" + chat;
        if (history.getInt(key, 0) >= message) return;
        context.getSystemService(NotificationManager.class).notify("friend-activity", chat,
            notification(context, title, CHANNEL, 391));
        history.edit().putInt(key, message).apply();
    }

    static void incoming(Context context, int chat, int message, long secondsLeft) {
        if (chat <= 0 || message <= 0 || secondsLeft <= 0 || !callsEnabled(context)) return;
        Intent intent = openChats(context).setData(android.net.Uri.parse("zompado-call:" + message))
            .putExtra(CALL_CHAT, chat).putExtra(CALL_MESSAGE, message);
        PendingIntent open = PendingIntent.getActivity(context, 395, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        context.getSystemService(NotificationManager.class).notify("voice", message,
            notification(context, "Incoming Zompado voice call", CALL_CHANNEL, open)
                .setContentText("Open Zompado to answer.")
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setTimeoutAfter(secondsLeft * 1000)
                .setOnlyAlertOnce(true)
                .build());
    }

    private static Intent openChats(Context context) {
        return new Intent(context, MainActivity.class)
            .setAction(OPEN_CHATS).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    }

    static android.app.Notification notification(Context context, String title, String channel, int request) {
        PendingIntent open = PendingIntent.getActivity(context, request, openChats(context),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return notification(context, title, channel, open).build();
    }

    private static NotificationCompat.Builder notification(Context context, String title, String channel,
            PendingIntent open) {
        return new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompado_icon_monochrome)
            .setContentTitle(title)
            .setContentText("Open Zompado to see what’s new.")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(open)
            .setAutoCancel(true);
    }
}
