package io.tablecircle.prototype;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.Comparator;

final class AppLog {
    private static final int MAX_BYTES = 96 * 1024;
    private static final String WATERMARK = "last-exit";
    private static boolean installed;

    private AppLog() {}

    static synchronized void install(Context context) {
        if (installed) return;
        installed = true;
        Context app = context.getApplicationContext();
        var previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, error) -> {
            try {
                failure(app, "Uncaught Android error", error);
            } finally {
                if (previous != null) previous.uncaughtException(thread, error);
            }
        });
        record(app, "App process started");
        new Thread(() -> collectExits(app), "zompado-app-log").start();
    }

    static void failure(Context context, String stage, Throwable error) {
        var summary = new StringBuilder(stage);
        for (int cause = 0; error != null && cause < 3; cause++, error = error.getCause()) {
            summary.append('\n').append(error.getClass().getName());
            var frames = error.getStackTrace();
            for (int i = 0; i < Math.min(12, frames.length); i++) {
                var frame = frames[i];
                summary.append("\n  ").append(frame.getClassName()).append('.')
                    .append(frame.getMethodName()).append(':').append(frame.getLineNumber());
            }
        }
        record(context, summary.toString());
    }

    static synchronized void record(Context context, String entry) {
        var file = file(context);
        FileOutputStream pending = null;
        try {
            byte[] recent = content(file);
            byte[] added = (timestamp(System.currentTimeMillis()) + " · " + entry + "\n\n").getBytes(StandardCharsets.UTF_8);
            int length = Math.min(recent.length, Math.max(0, MAX_BYTES - added.length));
            if (length < recent.length) {
                while (length > 0 && recent[length - 1] != '\n') length--;
            }
            pending = file.startWrite();
            pending.write(added, 0, Math.min(added.length, MAX_BYTES));
            pending.write(recent, 0, length);
            file.finishWrite(pending);
        } catch (IOException | RuntimeException ignored) {
            if (pending != null) file.failWrite(pending);
        }
    }

    static synchronized String read(Context context) throws IOException {
        String version = "unknown";
        try {
            var info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            long build = Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
            version = info.versionName + " (build " + build + ")";
        } catch (PackageManager.NameNotFoundException ignored) {}
        String entries = new String(content(file(context)), StandardCharsets.UTF_8);
        return "Zompado " + version + "\nAndroid " + Build.VERSION.RELEASE + " (API "
            + Build.VERSION.SDK_INT + ") · " + Build.MANUFACTURER + " " + Build.MODEL
            + "\n\n" + (entries.isEmpty() ? "No activity recorded." : entries);
    }

    static synchronized void clear(Context context) {
        preferences(context).edit().putLong(WATERMARK, System.currentTimeMillis()).commit();
        file(context).delete();
    }

    static synchronized void collectExits(Context context) {
        if (Build.VERSION.SDK_INT < 30) return;
        var preferences = preferences(context);
        long watermark = preferences.getLong(WATERMARK, 0);
        try {
            var manager = context.getSystemService(ActivityManager.class);
            var exits = new ArrayList<>(manager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 8));
            exits.sort(Comparator.comparingLong(ApplicationExitInfo::getTimestamp));
            for (var exit : exits) {
                long timestamp = exit.getTimestamp();
                if (timestamp <= watermark) continue;
                String reason = switch (exit.getReason()) {
                    case ApplicationExitInfo.REASON_CRASH -> "Android crash";
                    case ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash";
                    case ApplicationExitInfo.REASON_ANR -> "App stopped responding";
                    default -> null;
                };
                if (reason != null) {
                    String details = "";
                    if (Build.VERSION.SDK_INT >= 31 && exit.getReason() == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                        try (var trace = exit.getTraceInputStream()) {
                            if (trace != null) details = "\n" + NativeCrashSummary.format(readTrace(trace));
                        } catch (IOException | RuntimeException ignored) {}
                    }
                    record(context, "Previous process exit at " + timestamp(timestamp)
                        + " · " + reason + " · status " + exit.getStatus() + details);
                }
                watermark = timestamp;
            }
            preferences.edit().putLong(WATERMARK, watermark).apply();
        } catch (RuntimeException ignored) {
            // A device may not make historical exit information available.
        }
    }

    private static byte[] readTrace(InputStream trace) throws IOException {
        var output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int left = 4 * 1024 * 1024;
        while (left > 0) {
            int count = trace.read(buffer, 0, Math.min(buffer.length, left));
            if (count <= 0) break;
            output.write(buffer, 0, count);
            left -= count;
        }
        return output.toByteArray();
    }

    private static String timestamp(long millis) {
        var format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date(millis));
    }

    private static android.content.SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("app-log", Context.MODE_PRIVATE);
    }

    private static AtomicFile file(Context context) {
        return new AtomicFile(new File(context.getFilesDir(), "app-log.txt"));
    }

    private static byte[] content(AtomicFile file) throws IOException {
        try {
            return file.readFully();
        } catch (FileNotFoundException empty) {
            return new byte[0];
        }
    }
}
