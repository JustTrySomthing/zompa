package io.tablecircle.prototype;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.provider.Settings;
import androidx.core.app.NotificationCompat;
import java.util.UUID;
import java.util.HashMap;
import java.util.Map;

final class ChatAlerts {
    private static final String CHANNEL = "friend_activity";
    private static final String INVITE_CHANNEL = "game_invites";
    private static final String CALL_ACTIVITY = "incoming_calls";
    private static final String RING_CHANNEL = "incoming_calls_ringtone";
    private static final AudioAttributes RING_AUDIO = new AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build();
    static final String OPEN_CHATS = "io.zompado.OPEN_CHATS";
    static final String ALERT_CHAT = "alertChat";
    static final String ALERT_MESSAGE = "alertMessage";
    static final String INCOMING_CALL = "incomingCall";
    private static final String ALERT_TOKEN = "alertToken";
    private static final String VOICE_TAG = "voice";
    private static final String CALL_DEADLINE = "callDeadlineElapsed";

    static void setup(Context context) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            channel(manager, CHANNEL, "Chat messages", NotificationManager.IMPORTANCE_DEFAULT);
            channel(manager, INVITE_CHANNEL, "Game invites", NotificationManager.IMPORTANCE_DEFAULT);
            // Android keeps the sound chosen when a channel was created.
            // Move only untouched defaults to the ringtone channel.
            var previous = manager.getNotificationChannel(CALL_ACTIVITY);
            var ring = manager.getNotificationChannel(RING_CHANNEL);
            if (ring == null && (previous == null || canUpgradeRingtone(previous))) {
                ring = new NotificationChannel(RING_CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH);
                ring.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
                ring.setSound(Settings.System.DEFAULT_RINGTONE_URI, RING_AUDIO);
                manager.createNotificationChannel(ring);
            }
            channel(manager, CALL_ACTIVITY, ring == null ? "Incoming calls" : "Missed calls",
                ring == null ? NotificationManager.IMPORTANCE_HIGH : NotificationManager.IMPORTANCE_DEFAULT);
        }
    }

    private static boolean canUpgradeRingtone(NotificationChannel previous) {
        return Build.VERSION.SDK_INT >= 30
            && !previous.hasUserSetImportance() && !previous.hasUserSetSound()
            && previous.getImportance() == NotificationManager.IMPORTANCE_HIGH
            && Settings.System.DEFAULT_NOTIFICATION_URI.equals(previous.getSound())
            && !previous.shouldVibrate() && !previous.shouldShowLights()
            && !previous.canBypassDnd()
            && previous.getLockscreenVisibility() != Notification.VISIBILITY_PUBLIC
            && previous.getLockscreenVisibility() != Notification.VISIBILITY_SECRET;
    }

    static String incomingChannel(Context context) {
        if (Build.VERSION.SDK_INT < 26) return RING_CHANNEL;
        setup(context);
        return context.getSystemService(NotificationManager.class).getNotificationChannel(RING_CHANNEL) != null
            ? RING_CHANNEL : CALL_ACTIVITY;
    }

    static Uri incomingSound(Context context) {
        Uri sound = Settings.System.DEFAULT_RINGTONE_URI;
        if (Build.VERSION.SDK_INT >= 26) {
            var channel = context.getSystemService(NotificationManager.class)
                .getNotificationChannel(incomingChannel(context));
            if (channel == null || channel.getImportance() < NotificationManager.IMPORTANCE_DEFAULT) return null;
            sound = channel.getSound();
        }
        if (sound == null) return null;
        int type = RingtoneManager.getDefaultType(sound);
        if (type >= 0 && RingtoneManager.getActualDefaultRingtoneUri(context, type) == null) return null;
        return sound;
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
            if ("muted".equals(key) || channelFor(key).equals(channel)
                    || ("calls".equals(key) && RING_CHANNEL.equals(channel))) {
                manager.cancel(posted.getTag(), posted.getId());
            }
        }
        return true;
    }

    private static String channelFor(String kind) {
        if ("calls".equals(kind)) return CALL_ACTIVITY;
        if ("invites".equals(kind) || "gameActivity".equals(kind)) return INVITE_CHANNEL;
        if ("updates".equals(kind)) return "app_updates";
        return CHANNEL;
    }

    static boolean hasChatAlerts(Context context) {
        return enabled(context, "messages") || enabled(context, "invites")
            || callsEnabled(context) || enabled(context, "calls");
    }

    static boolean callsEnabled(Context context) {
        return enabled(context, "calls", incomingChannel(context));
    }

    static boolean enabled(Context context, String kind) {
        String option = "gameActivity".equals(kind) ? "invites" : kind;
        return enabled(context, option, channelFor(kind));
    }

    private static boolean enabled(Context context, String option, String channelId) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (!allowed(context, option) || !manager.areNotificationsEnabled()) return false;
        if (Build.VERSION.SDK_INT < 26) return true;
        setup(context);
        var channel = manager.getNotificationChannel(channelId);
        return channel != null && channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    static synchronized boolean post(Context context, int chat, int message, String title, String kind) {
        if (kind == null) kind = "messages";
        if (chat <= 0 || message <= 0 || !enabled(context, kind)) return false;
        var history = context.getSharedPreferences("chat_alerts", Context.MODE_PRIVATE);
        String key = "last_" + kind + "_" + chat;
        if (history.getInt(key, 0) >= message) return true;
        PendingIntent open = alertIntent(context, chat, message, false);
        context.getSystemService(NotificationManager.class).notify("friend-activity-" + kind, chat,
            activityNotification(context, title, channelFor(kind), open).build());
        history.edit().putInt(key, message).apply();
        return true;
    }

    static void remind(Context context, int chat, int message) {
        if (chat <= 0 || message <= 0 || !enabled(context, "messages")) return;
        PendingIntent open = alertIntent(context, chat, message, false);
        context.getSystemService(NotificationManager.class).notify("reply-reminder", message,
            activityNotification(context, "Reminder to reply", CHANNEL, open)
                .setContentText("Open the conversation in Zompa.")
                .build());
    }

    static synchronized void incoming(Context context, int chat, int message, long secondsLeft) {
        if (chat <= 0 || message <= 0 || secondsLeft <= 0 || !callsEnabled(context)) return;
        long deadline = SystemClock.elapsedRealtime() + Math.min(secondsLeft, 120) * 1000;
        postIncoming(context, chat, message, deadline, QuietHours.active(context));
    }

    static synchronized void dismissIncoming(Context context, int message) {
        context.getSystemService(NotificationManager.class).cancel(VOICE_TAG, message);
    }

    static synchronized void quietIncoming(Context context) {
        var manager = context.getSystemService(NotificationManager.class);
        for (var active : manager.getActiveNotifications()) {
            if (!VOICE_TAG.equals(active.getTag())) continue;
            Notification call = active.getNotification();
            if ((call.flags & Notification.FLAG_INSISTENT) == 0) continue;
            int chat = call.extras.getInt(ALERT_CHAT, 0);
            long deadline = call.extras.getLong(CALL_DEADLINE, 0);
            // Cancel the repeating sound, then keep the original answer target and expiry.
            manager.cancel(VOICE_TAG, active.getId());
            if (chat > 0 && callsEnabled(context)) {
                postIncoming(context, chat, active.getId(), deadline, true);
            }
        }
    }

    private static void postIncoming(Context context, int chat, int message, long deadline, boolean quiet) {
        long remaining = deadline - SystemClock.elapsedRealtime();
        if (remaining <= 0) return;
        PendingIntent open = alertIntent(context, chat, message, true);
        Bundle extras = new Bundle();
        extras.putInt(ALERT_CHAT, chat);
        extras.putLong(CALL_DEADLINE, deadline);
        var builder = notification(context, "Incoming Zompa call", incomingChannel(context), open)
            .addExtras(extras)
            .setContentText("Open Zompa to answer.")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setTimeoutAfter(remaining)
            .setOnlyAlertOnce(true)
            .setSilent(quiet);
        Uri sound = quiet ? null : incomingSound(context);
        if (sound != null && Build.VERSION.SDK_INT < 26) builder.setSound(sound);
        Notification call = builder.build();
        if (sound != null) call.flags |= Notification.FLAG_INSISTENT;
        context.getSystemService(NotificationManager.class).notify(VOICE_TAG, message, call);
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

    static Notification connectionNotification(Context context, String channel) {
        PendingIntent open = PendingIntent.getActivity(context, 393, openChats(context),
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompa_icon_monochrome)
            .setContentTitle("Zompa is listening")
            .setContentText("Receiving messages, calls, and game invites")
            .setContentIntent(open)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .build();
    }

    private static NotificationCompat.Builder activityNotification(Context context, String title,
            String channel, PendingIntent open) {
        var builder = notification(context, title, channel, open);
        if (Build.VERSION.SDK_INT < 26 && !QuietHours.active(context)) {
            builder.setDefaults(Notification.DEFAULT_SOUND);
        }
        return builder;
    }

    private static NotificationCompat.Builder notification(Context context, String title, String channel,
            PendingIntent open) {
        var publicVersion = new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompa_icon_monochrome)
            .setContentTitle(title)
            .setContentIntent(open)
            .build();
        return new NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.zompa_icon_monochrome)
            .setContentTitle(title)
            .setContentText("Open Zompa to see what’s new.")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setSilent(QuietHours.active(context))
            .setContentIntent(open)
            .setAutoCancel(true);
    }
}
