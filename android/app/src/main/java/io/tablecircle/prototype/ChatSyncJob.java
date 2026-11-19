package io.tablecircle.prototype;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

public final class ChatSyncJob extends JobService {
    private static final int JOB_ID = 291;
    private static final Object OWNER = new Object();
    private static Process jobCore;
    private static boolean appOwnsCore;
    private Poll active;

    static File executable(Context context) {
        return new File(context.getApplicationInfo().nativeLibraryDir, "libchatmail_rpc.so");
    }

    static void schedule(Context context) {
        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        if (scheduler.getPendingJob(JOB_ID) != null) return;
        scheduler.schedule(new JobInfo.Builder(JOB_ID, new ComponentName(context, ChatSyncJob.class))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(TimeUnit.MINUTES.toMillis(15))
            .setPersisted(true)
            .build());
    }

    static void claimForApp() {
        synchronized (OWNER) {
            appOwnsCore = true;
            if (jobCore != null) stopCore(jobCore);
        }
    }

    private static void stopCore(Process process) {
        if (Build.VERSION.SDK_INT >= 26) process.destroyForcibly();
        else process.destroy();
    }

    static void releaseFromApp() {
        synchronized (OWNER) {
            appOwnsCore = false;
        }
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        synchronized (OWNER) {
            if (appOwnsCore) return false;
        }
        File profile = new File(getFilesDir(), "chatmail");
        if (!ChatAlerts.enabled(this) || !new File(profile, "accounts.toml").isFile()) return false;
        Poll poll = new Poll(params, profile);
        active = poll;
        poll.worker.start();
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            if (active == poll) poll.stop();
        }, 45000);
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        if (active != null) {
            active.stop();
            active = null;
        }
        return false;
    }

    private final class Poll implements Runnable {
        final JobParameters params;
        final File profile;
        final Thread worker = new Thread(this, "zompado-chat-sync");
        Process core;
        volatile boolean stopped;

        Poll(JobParameters params, File profile) {
            this.params = params;
            this.profile = profile;
        }

        void stop() {
            synchronized (OWNER) {
                stopped = true;
                if (core != null) stopCore(core);
            }
            worker.interrupt();
        }

        @Override
        public void run() {
            try {
                synchronized (OWNER) {
                    if (stopped || appOwnsCore || jobCore != null) return;
                    ProcessBuilder builder = new ProcessBuilder(executable(ChatSyncJob.this).getPath())
                        .directory(profile);
                    if (Build.VERSION.SDK_INT >= 26) builder.redirectError(new File("/dev/null"));
                    builder.environment().put("DC_ACCOUNTS_PATH", profile.getPath());
                    builder.environment().put("RUST_LOG", "off");
                    core = builder.start();
                    jobCore = core;
                }
                if (Build.VERSION.SDK_INT < 26) {
                    var stderr = core.getErrorStream();
                    new Thread(() -> {
                        try (var input = stderr) {
                            byte[] buffer = new byte[2048];
                            while (input.read(buffer) != -1) {
                                // Drain stderr separately so it cannot corrupt JSON-RPC.
                            }
                        } catch (IOException ignored) {
                            // The process has closed the error pipe.
                        }
                    }, "zompado-chat-errors").start();
                }
                try (Rpc rpc = new Rpc(core)) {
                    JSONArray accounts = (JSONArray) rpc.call("get_all_account_ids");
                    if (accounts.length() == 0) return;
                    int account = accounts.getInt(0);
                    if (!Boolean.TRUE.equals(rpc.call("is_configured", account))) return;
                    rpc.call("start_io", account);
                    long deadline = SystemClock.elapsedRealtime() + 25000;
                    while (SystemClock.elapsedRealtime() < deadline) {
                        Thread.sleep(2000);
                        if (((Number) rpc.call("get_connectivity", account)).intValue() >= 4000) break;
                    }
                    notifyFresh(rpc, account);
                    rpc.call("stop_io", account);
                }
            } catch (Exception ignored) {
                // The next scheduled check can retry network or process failures.
            } finally {
                synchronized (OWNER) {
                    if (core != null) core.destroy();
                    if (jobCore == core) jobCore = null;
                }
                new Handler(Looper.getMainLooper()).post(() -> {
                    if (active == this) {
                        active = null;
                        jobFinished(params, false);
                    }
                });
            }
        }

        void notifyFresh(Rpc rpc, int account) throws Exception {
            JSONArray ids = (JSONArray) rpc.call("get_fresh_msgs", account);
            HashSet<Integer> notified = new HashSet<>();
            for (int offset = 0; offset < ids.length(); offset += 40) {
                JSONArray batch = new JSONArray();
                for (int i = offset; i < Math.min(offset + 40, ids.length()); i++) {
                    batch.put(ids.getInt(i));
                }
                JSONObject messages = (JSONObject) rpc.call("get_messages", account, batch);
                for (int i = 0; i < batch.length(); i++) {
                    int id = batch.getInt(i);
                    JSONObject msg = messages.optJSONObject(Integer.toString(id));
                    if (msg == null || !"message".equals(msg.optString("kind"))
                            || !msg.optBoolean("showPadlock") || msg.optInt("fromId") == 1) continue;
                    int chat = msg.optInt("chatId");
                    if (chat <= 0 || notified.contains(chat)) continue;
                    JSONObject info = (JSONObject) rpc.call("get_full_chat_by_id", account, chat);
                    if (!"Single".equals(info.optString("chatType")) || !info.optBoolean("isEncrypted")
                            || info.optBoolean("isSelfTalk") || info.optBoolean("isDeviceChat")) continue;
                    synchronized (OWNER) {
                        if (stopped || appOwnsCore) return;
                        String title = "Call".equals(msg.optString("viewType"))
                            ? "New call activity" : "New friend activity";
                        ChatAlerts.post(ChatSyncJob.this, chat, id, title);
                    }
                    notified.add(chat);
                }
            }
        }
    }

    private static final class Rpc implements AutoCloseable {
        final BufferedReader reader;
        final BufferedWriter writer;
        int next;

        Rpc(Process process) {
            reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));
            writer = new BufferedWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));
        }

        Object call(String method, Object... args) throws Exception {
            JSONArray params = new JSONArray();
            for (Object arg : args) params.put(arg);
            int id = ++next;
            JSONObject request = new JSONObject().put("jsonrpc", "2.0").put("id", id)
                .put("method", method).put("params", params);
            writer.write(request.toString());
            writer.newLine();
            writer.flush();
            String line = reader.readLine();
            if (line == null) throw new IOException("Chatmail stopped.");
            JSONObject response = new JSONObject(line);
            if (response.optInt("id") != id || response.has("error")) {
                throw new IOException("Chatmail request failed.");
            }
            return response.get("result");
        }

        @Override
        public void close() throws IOException {
            try { writer.close(); } finally { reader.close(); }
        }
    }
}
