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
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

public final class ChatSyncJob extends JobService {
    private static final int JOB_ID = 291;
    private static final Object OWNER = new Object();
    private static Process jobCore;
    private static boolean appOwnsCore;
    private Worker active;

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

    static Process claimForApp() {
        synchronized (OWNER) {
            appOwnsCore = true;
            if (jobCore != null) stopCore(jobCore);
            return jobCore;
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
        ChatListenerService.resumeListening();
    }

    static boolean canListen() {
        synchronized (OWNER) {
            return !appOwnsCore && jobCore == null;
        }
    }

    static File profile(Context context) {
        return new File(context.getFilesDir(), "chatmail");
    }

    static boolean hasProfile(Context context) {
        return new File(profile(context), "accounts.toml").isFile();
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        synchronized (OWNER) {
            if (appOwnsCore) return false;
        }
        if (ChatListenerService.isRunning() || !hasProfile(this)
                || !ChatAlerts.hasChatAlerts(this)) return false;
        Handler main = new Handler(Looper.getMainLooper());
        Worker poll = new Worker(this, false, finished -> main.post(() -> {
            if (active == finished) {
                active = null;
                jobFinished(params, false);
            }
            ChatListenerService.resumeListening();
        }));
        active = poll;
        poll.worker.start();
        main.postDelayed(() -> {
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

    static final class Worker implements Runnable {
        final Context context;
        final boolean live;
        final java.util.function.Consumer<Worker> finished;
        final Thread worker = new Thread(this, "zompa-chat-sync");
        Process core;
        volatile boolean stopped;

        Worker(Context context, boolean live, java.util.function.Consumer<Worker> finished) {
            this.context = context.getApplicationContext();
            this.live = live;
            this.finished = finished;
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
                    File profile = profile(context);
                    ProcessBuilder builder = new ProcessBuilder(executable(context).getPath()).directory(profile);
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
                    }, "zompa-chat-errors").start();
                }
                try (Rpc rpc = new Rpc(core)) {
                    JSONArray accounts = (JSONArray) rpc.call("get_all_account_ids");
                    if (accounts.length() == 0) return;
                    int account = accounts.getInt(0);
                    if (!Boolean.TRUE.equals(rpc.call("is_configured", account))) return;
                    if (live) {
                        rpc.call("start_io", account);
                        notifyFresh(rpc, account);
                        while (!stopped) receiveEvents(rpc, account);
                    } else {
                        rpc.call("background_fetch", 25);
                        notifyFresh(rpc, account);
                    }
                }
            } catch (Exception ignored) {
                // The next scheduled check can retry network or process failures.
            } finally {
                if (core != null) {
                    stopCore(core);
                    // Release the account only after the process has dropped its file lock.
                    Thread.interrupted();
                    try {
                        core.waitFor();
                    } catch (InterruptedException ignored) {
                        Thread.currentThread().interrupt();
                    }
                    synchronized (OWNER) {
                        if (jobCore == core) jobCore = null;
                    }
                }
                finished.accept(this);
            }
        }

        void receiveEvents(Rpc rpc, int account) throws Exception {
            JSONArray events = (JSONArray) rpc.call("get_next_event_batch");
            HashSet<Integer> incoming = new HashSet<>();
            for (int i = 0; i < events.length(); i++) {
                JSONObject entry = events.optJSONObject(i);
                if (entry == null || entry.optInt("contextId") != account) continue;
                JSONObject event = entry.optJSONObject("event");
                if (event == null) continue;
                switch (event.optString("kind")) {
                    case "IncomingMsg":
                        incoming.add(event.optInt("msgId"));
                        break;
                    case "IncomingCall":
                        incoming.add(event.optInt("msg_id"));
                        break;
                    case "CallEnded":
                    case "IncomingCallAccepted":
                        int id = event.optInt("msg_id");
                        if (id > 0) {
                            ChatAlerts.dismissIncoming(context, id);
                            incoming.add(id);
                        }
                        break;
                    default:
                        break;
                }
            }
            incoming.remove(0);
            if (!incoming.isEmpty()) notifyMessages(rpc, account, new ArrayList<>(incoming));
        }

        void notifyFresh(Rpc rpc, int account) throws Exception {
            JSONArray ids = (JSONArray) rpc.call("get_fresh_msgs", account);
            var fresh = new ArrayList<Integer>();
            for (int i = 0; i < ids.length(); i++) fresh.add(ids.getInt(i));
            notifyMessages(rpc, account, fresh);
        }

        void notifyMessages(Rpc rpc, int account, ArrayList<Integer> ids) throws Exception {
            ids.sort(Comparator.reverseOrder());
            HashSet<String> notified = new HashSet<>();
            for (int offset = 0; offset < ids.size(); offset += 40) {
                JSONArray batch = new JSONArray();
                for (int i = offset; i < Math.min(offset + 40, ids.size()); i++) {
                    batch.put(ids.get(i));
                }
                JSONObject messages = (JSONObject) rpc.call("get_messages", account, batch);
                for (int i = 0; i < batch.length(); i++) {
                    int id = batch.getInt(i);
                    JSONObject msg = messages.optJSONObject(Integer.toString(id));
                    try {
                        notifyMessage(rpc, account, id, msg, notified);
                    } catch (RpcError stale) {
                        // A deleted message or chat should not block the rest of the batch.
                    }
                }
            }
        }

        private void notifyMessage(Rpc rpc, int account, int id, JSONObject msg,
                HashSet<String> notified) throws Exception {
            if (msg == null || !"message".equals(msg.optString("kind"))
                    || !msg.optBoolean("showPadlock") || msg.optInt("fromId") <= 1) return;
            int chat = msg.optInt("chatId");
            boolean call = "Call".equals(msg.optString("viewType"));
            if (chat <= 0 || (!call && (msg.optBoolean("isInfo")
                    || msg.optInt("state") != 10))) return;
            JSONObject info = (JSONObject) rpc.call("get_full_chat_by_id", account, chat);
            if (!"Single".equals(info.optString("chatType")) || !info.optBoolean("isEncrypted")
                    || info.optBoolean("isSelfTalk") || info.optBoolean("isDeviceChat")
                    || info.optBoolean("isMuted") || info.optBoolean("isContactRequest")) return;
            if (call) {
                JSONObject details = (JSONObject) rpc.call("call_info", account, id);
                String state = details.getJSONObject("state").optString("kind");
                if (!info.optBoolean("canSend")) return;
                if ("Alerting".equals(state)) {
                    long secondsLeft = Math.min(120, msg.optLong("timestamp") + 120
                        - System.currentTimeMillis() / 1000);
                    if ("2".equals(rpc.call("get_config", account, "who_can_call_me"))) return;
                    synchronized (OWNER) {
                        if (stopped || appOwnsCore) return;
                        ChatAlerts.incoming(context, chat, id, secondsLeft);
                    }
                    return;
                }
                ChatAlerts.dismissIncoming(context, id);
                if (!"Missed".equals(state)) return;
            }
            synchronized (OWNER) {
                if (stopped || appOwnsCore) return;
                String text = msg.optString("text");
                String kind = call ? "calls" : text.startsWith("ZOMPADO_MATCH_V1 ") ? "invites" : "messages";
                String title = call ? "Missed Zompa call" : "New message";
                if ("invites".equals(kind)) {
                    try {
                        JSONObject event = new JSONObject(text.substring("ZOMPADO_MATCH_V1 ".length()));
                        String type = event.optString("type");
                        title = switch (type) {
                            case "invite" -> "New game invitation";
                            case "accept" -> "Your friend is ready to play";
                            case "decline" -> "Game invitation declined";
                            case "quit" -> "Your friend ended the match";
                            case "move", "next", "turn" -> "New game activity";
                            case "resume" -> event.optInt("rev") == 1 ? "Your game is ready" : null;
                            default -> null;
                        };
                        if (title == null) return;
                        if (!"invite".equals(type)) kind = "gameActivity";
                    } catch (org.json.JSONException ignored) {
                        kind = "messages";
                    }
                }
                String key = chat + ":" + kind;
                if (notified.contains(key)) return;
                if (ChatAlerts.post(context, chat, id, title, kind)) notified.add(key);
            }
        }
    }

    private static final class RpcError extends IOException {
        private static final long serialVersionUID = 1L;

        RpcError() {
            super("Chatmail request failed.");
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
            if (response.optInt("id") != id) {
                throw new IOException("Chatmail response did not match the request.");
            }
            if (response.has("error")) throw new RpcError();
            return response.get("result");
        }

        @Override
        public void close() throws IOException {
            try { writer.close(); } finally { reader.close(); }
        }
    }
}
