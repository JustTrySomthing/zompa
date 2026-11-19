package io.tablecircle.prototype;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;
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
    private static final String PREFS = "table_circle_updates";
    private static final String CACHE_KEY = "background_update_build";
    private static final String FEED =
        "https://raw.githubusercontent.com/JustTrySomthing/table-circle/main/update.json";
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
        Thread thread = new Thread(() -> {
            try {
                int build = readBuild();
                if (!Thread.currentThread().isInterrupted() && build > 0) {
                    SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
                    prefs.edit().putInt(CACHE_KEY, build).apply();
                }
            } catch (Exception ignored) {
                // Keep the last successful result. A manual check can be made from Settings.
            } finally {
                if (!Thread.currentThread().isInterrupted()) jobFinished(parameters, false);
            }
        }, "table-circle-update-check");
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
