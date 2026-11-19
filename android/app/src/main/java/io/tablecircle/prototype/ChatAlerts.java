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
    static final String OPEN_CHATS = "io.zompado.OPEN_CHATS";

    static void setup(Context context) {
        if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "Friend activity", NotificationManager.IMPORTANCE_DEFAULT));
        }
    }

    static boolean enabled(Context context) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (!manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT < 26) return true;
        setup(context);
        return manager.getNotificationChannel(CHANNEL).getImportance() != NotificationManager.IMPORTANCE_NONE;
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

    static void incoming(Context context, int message) {
        if (!enabled(context)) return;
        context.getSystemService(NotificationManager.class).notify("voice", message,
            notification(context, "Incoming Zompado voice call", CHANNEL, 395));
    }

    static android.app.Notification notification(Context context, String title, String channel, int request) {
        Intent intent = new Intent(context, MainActivity.class)
            .setAction(OPEN_CHATS).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent open = PendingIntent.getActivity(context, request, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompado_icon_monochrome)
            .setContentTitle(title)
            .setContentText("Open Zompado to see what’s new.")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build();
    }
}
