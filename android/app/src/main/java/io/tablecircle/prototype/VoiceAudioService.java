package io.tablecircle.prototype;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

public final class VoiceAudioService extends Service {
    private static final String CHANNEL = "active_voice_call";
    private static final int NOTICE = 394;

    static void begin(Context context) {
        Intent service = new Intent(context, VoiceAudioService.class);
        // The call starts from the visible Activity. startService avoids the
        // foreground-start deadline if the user hangs up before the service starts.
        context.startService(service);
    }

    static void finish(Context context) {
        context.stopService(new Intent(context, VoiceAudioService.class));
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHANNEL, "Ongoing calls", NotificationManager.IMPORTANCE_LOW));
        }
        var notification = ChatAlerts.notification(this, "Zompado call", CHANNEL, NOTICE);
        notification.flags |= android.app.Notification.FLAG_ONGOING_EVENT;
        notification.flags &= ~android.app.Notification.FLAG_AUTO_CANCEL;
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTICE, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
            } else {
                startForeground(NOTICE, notification);
            }
        } catch (SecurityException | IllegalStateException denied) {
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
