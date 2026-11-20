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
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.json.JSONObject;

final class LovePlayer implements PlatformView {
    private static final String POLICY = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "
        + "style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; media-src blob: data:; "
        + "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'";
    private final FrameLayout container;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final MethodChannel channel;
    private volatile WebView web;
    private volatile File archive;
    private volatile String originHost;
    private volatile boolean allowPackage;
    private boolean disposed;
    private boolean paused;
    private boolean online;
    private String match;
    private String audio = "100:100:100";
    private final Runnable moves = new Runnable() {
        @Override public void run() {
            var view = web;
            if (view == null || paused || !online || match == null || !match.endsWith("1")) return;
            view.evaluateJavascript("window.zompadoGame?.takeMove()", value -> {
                if (web == view && !paused && match != null && match.endsWith("1") && value != null && value.matches("[0-6]")) {
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
            return new LovePlayer(context, new MethodChannel(messenger, "io.zompado.love/" + id),
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
        if (args.get("audio") instanceof String) setAudio((String) args.get("audio"));
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "match":
                    String state = call.arguments();
                    if (online && state != null && state.matches("[012]{42}:[12]:[012]:[01]")) {
                        match = state;
                        sendMatch();
                    }
                    result.success(null);
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
                String identity = args.get("build") == null ? "import/" + args.get("id")
                    : "official/" + args.get("id");
                String host = "g-" + LoveImport.hex(LoveImport.sha256().digest(
                    identity.getBytes(StandardCharsets.UTF_8))).substring(0, 40) + ".games.zompado.invalid";
                main.post(() -> {
                    if (disposed) return;
                    archive = verified;
                    originHost = host;
                    start(context, mode);
                });
            } catch (Exception ignored) {
                main.post(() -> showMessage("Couldn’t open this game. Reinstall it and try again."));
            }
        }, "zompado-love-verify").start();
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
                ZipEntry manifest = zip.getEntry("zompado.json");
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
    private void start(Context context, String mode) {
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
                view.evaluateJavascript("window.zompadoGame?.start()", null);
            }

            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) showMessage("Couldn’t start the LÖVE player.");
            }

            @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                if (web == view) {
                    web = null;
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
        view.loadUrl("https://" + originHost + "/?mode=" + mode);
        if (paused) view.onPause();
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
            web.evaluateJavascript("window.zompadoGame?.setPaused(" + paused + ")", null);
        }
    }

    private void sendAudio() {
        if (web != null) {
            web.evaluateJavascript("window.zompadoGame?.setAudio(" + JSONObject.quote(audio) + ")", null);
        }
    }

    private void sendMatch() {
        if (web == null || match == null) return;
        web.evaluateJavascript("window.zompadoGame?.setMatch(" + JSONObject.quote(match) + ")", null);
        updatePolling();
    }

    private void updatePolling() {
        main.removeCallbacks(moves);
        if (online && !paused && web != null && match != null && match.endsWith("1")) main.post(moves);
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
        channel.setMethodCallHandler(null);
        main.removeCallbacks(moves);
        var view = web;
        web = null;
        container.removeAllViews();
        if (view != null) {
            view.evaluateJavascript("window.zompadoGame?.flushSaves()", null);
            view.onPause();
            main.postDelayed(view::destroy, 400);
        }
    }
}
