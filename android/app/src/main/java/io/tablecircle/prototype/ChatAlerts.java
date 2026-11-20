package io.tablecircle.prototype;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import androidx.core.app.NotificationCompat;
import java.util.UUID;
import java.util.HashMap;
import java.util.Map;

final class ChatAlerts {
    private static final String CHANNEL = "friend_activity";
    private static final String INVITE_CHANNEL = "game_invites";
    private static final String CALL_CHANNEL = "incoming_calls";
    static final String OPEN_CHATS = "io.zompado.OPEN_CHATS";
    static final String ALERT_CHAT = "alertChat";
    static final String ALERT_MESSAGE = "alertMessage";
    static final String INCOMING_CALL = "incomingCall";
    private static final String ALERT_TOKEN = "alertToken";

    static void setup(Context context) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            channel(manager, CHANNEL, "Chat messages", NotificationManager.IMPORTANCE_DEFAULT);
            channel(manager, INVITE_CHANNEL, "Game invites", NotificationManager.IMPORTANCE_DEFAULT);
            channel(manager, CALL_CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH);
        }
    }

    private static void channel(NotificationManager manager, String id, String name, int importance) {
        var channel = new NotificationChannel(id, name, importance);
        channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
        manager.createNotificationChannel(channel);
    }

    static Map<String, Boolean> settings(Context context) {
        var prefs = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        var values = new HashMap<String, Boolean>();
        for (String key : new String[] {"muted", "messages", "invites", "calls", "updates"}) {
            values.put(key, prefs.getBoolean(key, !"muted".equals(key)));
        }
        return values;
    }

    static boolean allowed(Context context, String key) {
        var prefs = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        return !prefs.getBoolean("muted", false) && prefs.getBoolean(key, true);
    }

    static synchronized boolean set(Context context, String key, boolean value) {
        if (!settings(context).containsKey(key)) return false;
        boolean saved = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE)
            .edit().putBoolean(key, value).commit();
        if (!saved || ("muted".equals(key) ? !value : value)) return saved;
        var manager = context.getSystemService(NotificationManager.class);
        for (var posted : manager.getActiveNotifications()) {
            var notification = posted.getNotification();
            if ((notification.flags & Notification.FLAG_FOREGROUND_SERVICE) != 0) continue;
            var channel = Build.VERSION.SDK_INT >= 26 ? notification.getChannelId() : null;
            if ("muted".equals(key) || channelFor(key).equals(channel)) {
                manager.cancel(posted.getTag(), posted.getId());
            }
        }
        return true;
    }

    private static String channelFor(String kind) {
        if ("calls".equals(kind)) return CALL_CHANNEL;
        if ("invites".equals(kind)) return INVITE_CHANNEL;
        if ("updates".equals(kind)) return "app_updates";
        return CHANNEL;
    }

    static boolean enabled(Context context) {
        return enabled(context, "messages") || enabled(context, "invites");
    }

    static boolean callsEnabled(Context context) {
        return enabled(context, "calls");
    }

    private static boolean enabled(Context context, String kind) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (!allowed(context, kind) || !manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT < 26) return true;
        setup(context);
        return manager.getNotificationChannel(channelFor(kind)).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    static synchronized boolean post(Context context, int chat, int message, String title, String kind) {
        if (kind == null) kind = "messages";
        if (chat <= 0 || message <= 0 || !enabled(context, kind)) return false;
        var history = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        String key = "last_" + chat;
        if (history.getInt(key, 0) >= message) return true;
        PendingIntent open = alertIntent(context, chat, message, false);
        context.getSystemService(NotificationManager.class).notify("friend-activity", chat,
            notification(context, title, channelFor(kind), open).build());
        history.edit().putInt(key, message).apply();
        return true;
    }

    static void remind(Context context, int chat, int message) {
        if (chat <= 0 || message <= 0 || !enabled(context, "messages")) return;
        PendingIntent open = alertIntent(context, chat, message, false);
        context.getSystemService(NotificationManager.class).notify("reply-reminder", message,
            notification(context, "Reminder to reply", CHANNEL, open)
                .setContentText("Open the conversation in Zompado.")
                .build());
    }

    static void incoming(Context context, int chat, int message, long secondsLeft) {
        if (chat <= 0 || message <= 0 || secondsLeft <= 0 || !callsEnabled(context)) return;
        PendingIntent open = alertIntent(context, chat, message, true);
        context.getSystemService(NotificationManager.class).notify("voice", message,
            notification(context, "Incoming Zompado call", CALL_CHANNEL, open)
                .setContentText("Open Zompado to answer.")
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setTimeoutAfter(secondsLeft * 1000)
                .setOnlyAlertOnce(true)
                .build());
    }

    private static PendingIntent alertIntent(Context context, int chat, int message, boolean call) {
        // Use the message ID so separate chats and replaced alerts keep their own target.
        Intent intent = openChats(context).setData(Uri.parse("zompado-alert:" + message))
            .putExtra(ALERT_CHAT, chat).putExtra(ALERT_MESSAGE, message).putExtra(INCOMING_CALL, call)
            .putExtra(ALERT_TOKEN, alertToken(context));
        return PendingIntent.getActivity(context, call ? 395 : 391, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static synchronized String alertToken(Context context) {
        var prefs = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        String token = prefs.getString(ALERT_TOKEN, null);
        if (token != null) return token;
        token = UUID.randomUUID().toString();
        return prefs.edit().putString(ALERT_TOKEN, token).commit() ? token : null;
    }

    static boolean isTrustedAlert(Context context, Intent intent) {
        String token = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE)
            .getString(ALERT_TOKEN, null);
        boolean trusted = token != null && token.equals(intent.getStringExtra(ALERT_TOKEN));
        intent.removeExtra(ALERT_TOKEN);
        return trusted;
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
        var publicVersion = new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompado_icon_monochrome)
            .setContentTitle(title)
            .setContentIntent(open)
            .build();
        return new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompado_icon_monochrome)
            .setContentTitle(title)
            .setContentText("Open Zompado to see what’s new.")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setSilent(QuietHours.active(context))
            .setContentIntent(open)
            .setAutoCancel(true);
    }
}
