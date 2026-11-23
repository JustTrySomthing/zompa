package io.tablecircle.prototype;

import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.TextView;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class LovePlayer implements PlatformView {
    private static final String POLICY = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "
        + "style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; media-src blob: data:; "
        + "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'";
    private static final Pattern MATCH_STATE =
        Pattern.compile("[012]{42}:[12]:[012]:([01])(?::[0-3]:[0-3])?");
    private final FrameLayout container;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final MethodChannel channel;
    private volatile WebView web;
    private volatile File archive;
    private volatile String originHost;
    private volatile boolean allowPackage;
    private boolean disposed;
    private boolean paused;
    private String instructions;
    private boolean online;
    private MethodChannel.Result leaving;
    private String match;
    private boolean moveAllowed;
    private String audio = "100:100:100";
    private final Runnable moves = new Runnable() {
        @Override public void run() {
            var view = web;
            if (view == null || paused || !moveAllowed) return;
            view.evaluateJavascript("window.zompaGame?.takeMove()", value -> {
                if (web == view && !paused && moveAllowed && value != null && value.matches("[0-6]")) {
                    channel.invokeMethod("move", Integer.parseInt(value));
                }
            });
            main.postDelayed(this, 180);
        }
    };

    static final class Factory extends PlatformViewFactory {
        private final BinaryMessenger messenger;

        Factory(BinaryMessenger messenger) {
            super(StandardMessageCodec.INSTANCE);
            this.messenger = messenger;
        }

        @Override public PlatformView create(Context context, int id, Object args) {
            return new LovePlayer(context, new MethodChannel(messenger, "io.zompa.love/" + id),
                args instanceof Map ? (Map<?, ?>) args : Collections.emptyMap());
        }
    }

    private LovePlayer(Context context, MethodChannel channel, Map<?, ?> args) {
        this.channel = channel;
        container = new FrameLayout(context);
        container.setBackgroundColor(0xff181423);
        String mode = "online".equals(args.get("mode")) ? "online"
            : "local".equals(args.get("mode")) ? "local" : "solo";
        online = mode.equals("online");
        int build = "drop-four".equals(args.get("id")) && args.get("build") instanceof Integer
            ? (Integer) args.get("build") : 0;
        String save = Boolean.TRUE.equals(args.get("localSaves")) && !online
            ? (Boolean.TRUE.equals(args.get("fresh")) ? "new" : "resume") : "";
        if (args.get("audio") instanceof String) setAudio((String) args.get("audio"));
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "match":
                    String state = call.arguments();
                    if (online && state != null) {
                        var parsed = MATCH_STATE.matcher(state);
                        if (parsed.matches()) {
                            match = state;
                            moveAllowed = "1".equals(parsed.group(1));
                            sendMatch();
                        }
                    }
                    result.success(null);
                    break;
                case "instructions":
                    result.success(instructions);
                    break;
                case "audio":
                    setAudio(call.arguments());
                    result.success(null);
                    break;
                case "pause":
                    paused = Boolean.TRUE.equals(call.arguments);
                    if (web != null) {
                        if (!paused) web.onResume();
                        sendPause();
                        if (paused) web.onPause();
                    }
                    updatePolling();
                    result.success(null);
                    break;
                case "leave":
                    if (save.isEmpty()) result.success(null);
                    else leave(Boolean.TRUE.equals(call.arguments), result);
                    break;
                default:
                    result.notImplemented();
            }
        });

        if (Build.VERSION.SDK_INT < 29) {
            showMessage("Playing downloaded games requires Android 10 or later.");
            return;
        }
        showMessage("Opening game…");
        new Thread(() -> {
            try {
                File verified = verify(context, args);
                String help = readInstructions(verified);
                String identity = args.get("build") == null ? "import/" + args.get("id")
                    : "official/" + args.get("id");
                String host = gameHost(identity);
                main.post(() -> {
                    if (disposed) return;
                    archive = verified;
                    instructions = help;
                    originHost = host;
                    start(context, mode, save, build);
                });
            } catch (Exception ignored) {
                main.post(() -> showMessage("Couldn’t open this game. Reinstall it and try again."));
            }
        }, "zompa-love-verify").start();
    }

    private static String readInstructions(File file) {
        try (ZipFile zip = new ZipFile(file)) {
            ZipEntry entry = zip.getEntry("how-to-play.txt");
            if (entry == null || entry.getSize() < 1 || entry.getSize() > 16384) return null;
            byte[] bytes = new byte[(int) entry.getSize()];
            try (var in = new java.io.DataInputStream(zip.getInputStream(entry))) {
                in.readFully(bytes);
            }
            return new String(bytes, StandardCharsets.UTF_8).trim();
        } catch (IOException ignored) {
            return null;
        }
    }

    private static String gameHost(String identity) {
        return "g-" + LoveImport.hex(LoveImport.sha256().digest(
            identity.getBytes(StandardCharsets.UTF_8))).substring(0, 40) + ".games.zompado.invalid";
    }

    static void manageLocalSaves(Context context, Map<?, ?> args, boolean discard, MethodChannel.Result result) {
        Object id = args.get("id");
        Object build = args.get("build");
        if (!(id instanceof String) || !((String) id).matches("[a-z0-9][a-z0-9-]{0,63}")
                || !(build instanceof Integer) || (Integer) build < 1) {
            result.error("LOVE_SAVE", "Invalid game reference.", null);
            return;
        }
        int legacyBuild = "drop-four".equals(id) ? (Integer) build : 0;
        String modes = Boolean.TRUE.equals(args.get("passAndPlay"))
            ? "['solo','local']" : "['solo']";
        Object mode = args.get("mode");
        if (discard && !"solo".equals(mode) && !("local".equals(mode) && Boolean.TRUE.equals(args.get("passAndPlay")))) {
            result.error("LOVE_SAVE", "Invalid game mode.", null);
            return;
        }
        if (Build.VERSION.SDK_INT < 29) {
            if (discard) result.error("LOVE_SAVE", "Saved games require Android 10 or later.", null);
            else result.success(Collections.emptyList());
            return;
        }
        String failure = discard ? "Couldn’t quit the saved game." : "Couldn’t check the saved games.";
        String operation = discard
            ? "discardLocalSave(" + JSONObject.quote((String) mode) + ", " + legacyBuild + ").then(() => [])"
            : "readLocalSaves(" + legacyBuild + ", " + modes + ")";
        final String script;
        final WebView probe;
        try (var input = context.getAssets().open("love/local-saves.js")) {
            var bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            for (int count; (count = input.read(buffer)) != -1;) bytes.write(buffer, 0, count);
            script = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
            probe = new WebView(context);
        } catch (IOException | RuntimeException error) {
            result.error("LOVE_SAVE", failure, null);
            return;
        }
        var handler = new Handler(Looper.getMainLooper());
        class Probe {
            boolean done;

            void finish(ArrayList<String> modes) {
                if (done) return;
                done = true;
                handler.post(probe::destroy);
                if (modes == null) result.error("LOVE_SAVE", failure, null);
                else result.success(discard ? null : modes);
            }
        }
        var request = new Probe();
        var settings = probe.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setBlockNetworkLoads(true);
        probe.setWebViewClient(new WebViewClient() {
            @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                request.finish(null);
                return true;
            }
        });
        probe.setWebChromeClient(new WebChromeClient() {
            @Override public void onReceivedTitle(WebView view, String title) {
                if (title == null || !title.startsWith("zompado-saves:")) return;
                try {
                    var entries = new JSONArray(title.substring("zompado-saves:".length()));
                    var modes = new ArrayList<String>();
                    for (int i = 0; i < entries.length(); i++) {
                        String mode = entries.getString(i);
                        if (mode.equals("solo") || mode.equals("local")) modes.add(mode);
                    }
                    request.finish(modes);
                } catch (JSONException error) {
                    request.finish(null);
                }
            }
        });
        handler.postDelayed(() -> request.finish(null), 8000);
        probe.loadDataWithBaseURL("https://" + gameHost("official/" + id) + "/",
            "<!doctype html><meta charset=utf-8><script>" + script
            + "\n" + operation + ".then(modes => {"
            + "document.title = 'zompado-saves:' + JSON.stringify(modes);"
            + "}, () => {document.title = 'zompado-saves:error';});</script>",
            "text/html", "UTF-8", null);
    }

    static File verify(Context context, Map<?, ?> args) throws Exception {
        String id = args.get("id") instanceof String ? (String) args.get("id") : "";
        Object build = args.get("build");
        String expected = args.get("sha") instanceof String ? (String) args.get("sha") : "";
        File root = context.getFilesDir().getCanonicalFile();
        File file;
        if (build instanceof Integer && (Integer) build > 0
                && id.matches("[a-z0-9]+(?:-[a-z0-9]+)*") && id.length() <= 64
                && expected.matches("[a-f0-9]{64}")) {
            file = new File(root, "games/" + id + "/" + build + ".zomp");
        } else if (build == null && id.matches("[a-f0-9]{64}")) {
            file = new File(root, "imported-love/" + id + ".love");
            expected = id;
        } else {
            throw new IOException("Invalid game reference");
        }
        if (!file.equals(file.getCanonicalFile()) || !file.isFile()
                || file.length() == 0 || file.length() > LoveImport.MAX_PACKAGE_BYTES) {
            throw new IOException("Game file is unavailable");
        }
        var hash = LoveImport.sha256();
        try (var input = new FileInputStream(file)) {
            byte[] buffer = new byte[32768];
            for (int count; (count = input.read(buffer)) != -1;) hash.update(buffer, 0, count);
        }
        if (!LoveImport.hex(hash.digest()).equals(expected)) throw new IOException("Game file changed");
        LoveImport.validate(file);
        if (build != null) {
            try (var zip = new ZipFile(file)) {
                ZipEntry manifest = zip.getEntry("zompa.json");
                if (manifest == null) manifest = zip.getEntry("zompado.json");
                if (manifest == null || manifest.getSize() < 1 || manifest.getSize() > 4096) {
                    throw new IOException("Missing game manifest");
                }
                var bytes = new ByteArrayOutputStream();
                try (var input = zip.getInputStream(manifest)) {
                    byte[] buffer = new byte[512];
                    for (int count; (count = input.read(buffer)) != -1;) {
                        if (bytes.size() + count > 4096) throw new IOException("Game manifest is too large");
                        bytes.write(buffer, 0, count);
                    }
                }
                var info = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
                if (info.optInt("schema") != 1 || !id.equals(info.optString("id"))
                        || !build.equals(info.optInt("build")) || !"love-11.5".equals(info.optString("runtime"))
                        || !"main.lua".equals(info.optString("entry"))) {
                    throw new IOException("Incompatible game manifest");
                }
            }
        }
        return file;
    }

    @SuppressWarnings("deprecation")
    private void start(Context context, String mode, String save, int build) {
        WebView view;
        try {
            view = new WebView(context);
        } catch (RuntimeException missingWebView) {
            showMessage("Android System WebView is unavailable. Update or enable it to play.");
            return;
        }
        web = view;
        var settings = view.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setBlockNetworkLoads(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setMediaPlaybackRequiresUserGesture(true);
        settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(view, false);
        view.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest request) {
                request.deny();
            }

            @Override public void onReceivedTitle(WebView view, String title) {
                if (web != view || leaving == null) return;
                if ("zompa-save:ok".equals(title)) finishLeave(true);
                else if ("zompa-save:error".equals(title)) finishLeave(false);
            }
        });
        view.setDownloadListener((url, agent, disposition, mime, length) -> {});
        view.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return true;
            }

            @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                Uri url = request.getUrl();
                if (!"GET".equals(request.getMethod()) || !"https".equals(url.getScheme())
                        || !originHost.equals(url.getHost()) || url.getPort() != -1
                        || url.getEncodedUserInfo() != null) return denied();
                String path = url.getEncodedPath();
                if (path == null) return denied();
                try {
                    switch (path) {
                        case "/": return asset(context, "index.html", "text/html");
                        case "/player.js": return asset(context, "player.js", "application/javascript");
                        case "/local-saves.js": return asset(context, "local-saves.js", "application/javascript");
                        case "/player.css": return asset(context, "player.css", "text/css");
                        case "/love.js": return asset(context, "love.js", "application/javascript");
                        case "/love.wasm": return asset(context, "love.wasm", "application/wasm");
                        case "/game.love":
                            return allowPackage
                                ? response("application/octet-stream", new FileInputStream(archive))
                                : denied();
                        default: return denied();
                    }
                } catch (IOException | RuntimeException error) {
                    return denied();
                }
            }

            @Override public void onPageFinished(WebView view, String url) {
                if (disposed || web != view || !url.startsWith("https://" + originHost + "/")) return;
                if (Build.VERSION.SDK_INT < 29 || view.getWebViewRenderProcess() == null) {
                    web = null;
                    container.removeView(view);
                    view.destroy();
                    showMessage("This device’s WebView can’t run games in a separate renderer.");
                    return;
                }
                sendMatch();
                allowPackage = true;
                sendAudio();
                sendPause();
                view.evaluateJavascript("window.zompaGame?.start()", null);
            }

            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) showMessage("Couldn’t start the LÖVE player.");
            }

            @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                if (web == view) {
                    web = null;
                    if (leaving != null) finishLeave(false);
                    main.removeCallbacks(moves);
                    showMessage("The game stopped. Go back to the library and reopen it.");
                }
                container.removeView(view);
                view.destroy();
                return true;
            }
        });
        container.removeAllViews();
        container.addView(view, new FrameLayout.LayoutParams(-1, -1));
        view.loadUrl("https://" + originHost + "/?mode=" + mode
            + (save.isEmpty() ? "" : "&save=" + save + "&build=" + build));
        if (paused) view.onPause();
    }

    private void leave(boolean quit, MethodChannel.Result result) {
        if (web == null) {
            if (quit) result.error("LOVE_SAVE", "The game is not ready.", null);
            else result.success(null);
            return;
        }
        if (leaving != null) {
            result.error("LOVE_SAVE", "A save operation is already running.", null);
            return;
        }
        leaving = result;
        web.onResume();
        web.evaluateJavascript("Boolean(window.zompaGame && (window.zompaGame.leave("
            + quit + "), true))", accepted -> {
                if (leaving == result && !"true".equals(accepted)) finishLeave(!quit);
            });
        main.postDelayed(() -> {
            if (leaving == result) finishLeave(false);
        }, 8000);
    }

    private void finishLeave(boolean saved) {
        var result = leaving;
        leaving = null;
        if (saved) result.success(null);
        else result.error("LOVE_SAVE", "Couldn’t finish saving this game.", null);
    }

    private static WebResourceResponse asset(Context context, String filename, String mime) throws IOException {
        return response(mime, context.getAssets().open("love/" + filename));
    }

    private static WebResourceResponse response(String mime, InputStream stream) {
        Map<String, String> headers = new HashMap<>();
        headers.put("Content-Security-Policy", POLICY);
        headers.put("X-Content-Type-Options", "nosniff");
        headers.put("Cache-Control", "no-store");
        return new WebResourceResponse(mime, mime.startsWith("text/") || mime.endsWith("javascript") ? "UTF-8" : null,
            200, "OK", headers, stream);
    }

    private static WebResourceResponse denied() {
        return new WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden",
            Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
    }

    private void setAudio(String settings) {
        if (settings == null || !settings.matches("(100|[1-9]?[0-9]):(100|[1-9]?[0-9]):(100|[1-9]?[0-9])")) return;
        audio = settings;
        sendAudio();
    }

    private void sendPause() {
        if (web != null) {
            web.evaluateJavascript("window.zompaGame?.setPaused(" + paused + ")", null);
        }
    }

    private void sendAudio() {
        if (web != null) {
            web.evaluateJavascript("window.zompaGame?.setAudio(" + JSONObject.quote(audio) + ")", null);
        }
    }

    private void sendMatch() {
        if (web == null || match == null) return;
        web.evaluateJavascript("window.zompaGame?.setMatch(" + JSONObject.quote(match) + ")", null);
        updatePolling();
    }

    private void updatePolling() {
        main.removeCallbacks(moves);
        if (!paused && web != null && moveAllowed) main.post(moves);
    }

    private void showMessage(String message) {
        if (disposed) return;
        container.removeAllViews();
        var label = new TextView(container.getContext());
        label.setTextColor(0xffffffff);
        label.setText(message);
        label.setGravity(android.view.Gravity.CENTER);
        label.setPadding(24, 24, 24, 24);
        container.addView(label, new FrameLayout.LayoutParams(-1, -1));
    }

    @Override public View getView() { return container; }

    @Override public void dispose() {
        disposed = true;
        if (leaving != null) finishLeave(false);
        channel.setMethodCallHandler(null);
        main.removeCallbacks(moves);
        var view = web;
        web = null;
        container.removeAllViews();
        if (view != null) {
            view.evaluateJavascript("window.zompaGame?.flushSaves()", null);
            view.onPause();
            main.postDelayed(view::destroy, 400);
        }
    }
}
