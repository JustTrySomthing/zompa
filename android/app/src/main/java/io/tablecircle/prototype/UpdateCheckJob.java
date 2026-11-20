package io.tablecircle.prototype;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.core.app.NotificationCompat;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

public final class UpdateCheckJob extends JobService {
    private static final int JOB_ID = 290;
    private static final int LIMIT = 128 * 1024;
    private static final String PREFS = "zompado_updates";
    private static final String CHANNEL = "app_updates";
    private static final String NOTIFIED = "notified_update_build";
    private static final String CACHE_KEY = "background_update_build";
    private static final String FEED =
        "https://raw.githubusercontent.com/JustTrySomthing/zompado/main/update.json";
    private volatile Thread worker;

    static int cachedBuild(Context context) {
        return context.getSharedPreferences(PREFS, MODE_PRIVATE).getInt(CACHE_KEY, 0);
    }

    static void schedule(Context context, boolean enabled) {
        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        if (!enabled) {
            scheduler.cancel(JOB_ID);
            return;
        }
        if (scheduler.getPendingJob(JOB_ID) != null) return;
        scheduler.schedule(new JobInfo.Builder(JOB_ID, new ComponentName(context, UpdateCheckJob.class))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(TimeUnit.DAYS.toMillis(1))
            .build());
    }

    @Override
    public boolean onStartJob(JobParameters parameters) {
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
            try {
                int build = readBuild();
                if (!Thread.currentThread().isInterrupted() && build > 0) {
                    SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
                    prefs.edit().putInt(CACHE_KEY, build).apply();
                    notifyUpdate(build, prefs);
                }
            } catch (Exception ignored) {
                // Keep the last successful result. A manual check can be made from Settings.
            } finally {
                if (!Thread.currentThread().isInterrupted()) jobFinished(parameters, false);
            }
            }
        }, "zompado-update-check");
        worker = thread;
        thread.start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters parameters) {
        Thread thread = worker;
        if (thread != null) thread.interrupt();
        return false;
    }

    @SuppressWarnings("deprecation")
    private void notifyUpdate(int build, SharedPreferences prefs)
        throws android.content.pm.PackageManager.NameNotFoundException {
        int installed = getPackageManager().getPackageInfo(getPackageName(), 0).versionCode;
        if (build <= installed || build <= prefs.getInt(NOTIFIED, 0)) return;
        if (!ChatAlerts.allowed(this, "updates")) return;
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (!manager.areNotificationsEnabled()) return;
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) return;
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(new NotificationChannel(
                CHANNEL, "App updates", NotificationManager.IMPORTANCE_DEFAULT));
            if (manager.getNotificationChannel(CHANNEL).getImportance()
                    == NotificationManager.IMPORTANCE_NONE) return;
        }
        Intent open = new Intent(this, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent target = PendingIntent.getActivity(
            this, JOB_ID, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        manager.notify(JOB_ID, new NotificationCompat.Builder(this, CHANNEL)
            .setSilent(QuietHours.active(this))
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Zompado update available")
            .setContentText("Open Zompado to see the new version.")
            .setContentIntent(target)
            .setAutoCancel(true)
            .build());
        prefs.edit().putInt(NOTIFIED, build).apply();
    }

    private static int readBuild() throws Exception {
        HttpsURLConnection connection = (HttpsURLConnection) new URL(FEED).openConnection();
        connection.setConnectTimeout(12000);
        connection.setReadTimeout(12000);
        connection.setInstanceFollowRedirects(false);
        try {
            if (connection.getResponseCode() != 200) return 0;
            try (InputStream input = connection.getInputStream();
                 ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096];
                for (int size; (size = input.read(buffer)) != -1;) {
                    if (Thread.currentThread().isInterrupted() || bytes.size() + size > LIMIT) return 0;
                    bytes.write(buffer, 0, size);
                }
                JSONObject json = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
                return json.optInt("schema") == 1 && "arm64-v8a".equals(json.optString("abi"))
                    ? json.optInt("build") : 0;
            }
        } finally {
            connection.disconnect();
        }
    }
}
