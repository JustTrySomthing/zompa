package io.tablecircle.prototype;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.net.Uri;
import android.view.Gravity;
import android.view.View;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.MediaController;
import android.widget.TextView;
import android.widget.VideoView;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

final class ChatPlayback {
    private final Activity activity;
    private final Map<Integer, VideoPreview> videos = new HashMap<>();
    private final Map<Integer, WebPreview> pages = new HashMap<>();
    private final java.util.concurrent.ExecutorService thumbnails =
        java.util.concurrent.Executors.newFixedThreadPool(2);
    private MediaPlayer player;
    private int owner;
    private boolean audioReady;
    private boolean audioFailed;

    ChatPlayback(Activity activity) {
        this.activity = activity;
    }

    private File attachment(String path) throws IOException {
        if (path == null) throw new IOException("Missing attachment");
        File root = new File(activity.getFilesDir(), "chatmail").getCanonicalFile();
        File file = new File(path).getCanonicalFile();
        if (!file.toPath().startsWith(root.toPath()) || !file.isFile()
                || !file.getParentFile().getName().endsWith("-blobs")) {
            throw new IOException("Invalid attachment");
        }
        return file;
    }

    void playAudio(String path, int token) {
        if (owner == token && audioReady && player != null) {
            if (player.isPlaying()) player.pause();
            else player.start();
            return;
        }
        releaseAudio();
        owner = token;
        audioFailed = false;
        try {
            File file = attachment(path);
            MediaPlayer next = new MediaPlayer();
            player = next;
            next.setAudioAttributes(new android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build());
            next.setDataSource(file.getAbsolutePath());
            next.setOnPreparedListener(ready -> {
                if (player != ready) return;
                audioReady = true;
                ready.start();
            });
            next.setOnErrorListener((failed, what, extra) -> {
                if (player == failed) failAudio();
                return true;
            });
            next.setOnCompletionListener(finished -> {
                if (player == finished) finished.seekTo(0);
            });
            next.prepareAsync();
        } catch (Exception unavailable) {
            failAudio();
        }
    }

    private void failAudio() {
        int failed = owner;
        releaseAudio();
        owner = failed;
        audioFailed = true;
    }

    Map<String, Object> audioStatus(int token) {
        var status = new HashMap<String, Object>();
        status.put("active", owner == token && !audioFailed);
        if (owner != token) return status;
        if (audioFailed) status.put("error", true);
        else if (!audioReady || player == null) status.put("loading", true);
        else {
            status.put("playing", player.isPlaying());
            status.put("duration", player.getDuration());
            status.put("position", player.getCurrentPosition());
        }
        return status;
    }

    void seekAudio(int token, int position) {
        if (owner == token && audioReady && player != null) {
            player.seekTo(Math.max(0, Math.min(position, player.getDuration())));
        }
    }

    void stopAudio(int token) {
        if (owner == token) releaseAudio();
    }

    private void releaseAudio() {
        if (player != null) player.release();
        player = null;
        owner = 0;
        audioReady = false;
        audioFailed = false;
    }

    void thumbnail(String path, MethodChannel.Result result) {
        thumbnails.execute(() -> {
            byte[] image = null;
            var retriever = new MediaMetadataRetriever();
            try {
                retriever.setDataSource(attachment(path).getAbsolutePath());
                Bitmap bitmap = android.os.Build.VERSION.SDK_INT >= 27
                    ? retriever.getScaledFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 320, 180)
                    : retriever.getFrameAtTime();
                if (bitmap != null) {
                    try (var output = new ByteArrayOutputStream()) {
                        if (bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)) image = output.toByteArray();
                    } finally {
                        bitmap.recycle();
                    }
                }
            } catch (Exception ignored) {
                // The player can still try formats with no readable thumbnail.
            } finally {
                try { retriever.release(); } catch (Exception ignored) {}
            }
            byte[] frame = image;
            activity.runOnUiThread(() -> result.success(frame));
        });
    }

    PlatformViewFactory factory(boolean browser) {
        return new PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            @Override public PlatformView create(android.content.Context context, int id, Object args) {
                String value = args instanceof String ? (String) args : null;
                if (browser) {
                    var page = new WebPreview(id, value);
                    pages.put(id, page);
                    return page;
                }
                var video = new VideoPreview(id, value);
                videos.put(id, video);
                return video;
            }
        };
    }

    boolean openExternal(Integer id, String original) {
        var page = id == null ? null : pages.get(id);
        Uri destination = webUri(page == null || page.failed ? original : page.view.getUrl());
        if (destination == null) destination = webUri(original);
        if (destination == null) return false;
        try {
            activity.startActivity(new Intent(Intent.ACTION_VIEW, destination)
                .addCategory(Intent.CATEGORY_BROWSABLE));
            return true;
        } catch (RuntimeException failure) {
            return false;
        }
    }

    void pause() {
        releaseAudio();
        for (var video : videos.values()) video.pause();
        for (var page : pages.values()) if (!page.failed) page.view.onPause();
    }

    void resume() {
        for (var page : pages.values()) if (!page.failed) page.view.onResume();
    }

    private static Uri webUri(String value) {
        if (value == null) return null;
        Uri uri = Uri.parse(value);
        String scheme = uri.getScheme();
        return ("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme))
                && uri.getHost() != null && !uri.getHost().trim().isEmpty()
                && uri.getUserInfo() == null ? uri : null;
    }

    private static void enableYouTubeSound(WebView page, String videoId) {
        if (videoId == null || !videoId.matches("[A-Za-z0-9_-]{11}")) return;
        // A YouTube page can start with its own mute preference even when
        // the WebView permits autoplay. Enable sound once, on initial play.
        page.evaluateJavascript("""
            ((id) => {
              if (!['m.youtube.com', 'www.youtube.com', 'youtube.com'].includes(location.hostname)
                  || location.pathname !== '/watch'
                  || new URLSearchParams(location.search).get('v') !== id
                  || window.zompadoSoundStarted === id) return;
              window.zompadoSoundStarted = id;
              function enableSound(event) {
                const video = event.target;
                if (!(video instanceof HTMLVideoElement) || video.paused) return;
                document.removeEventListener('playing', enableSound, true);
                video.muted = false;
                if (video.volume === 0) video.volume = 1;
              }
              document.addEventListener('playing', enableSound, true);
              const playing = Array.from(document.querySelectorAll('video'))
                  .find(video => !video.paused && video.readyState >= 2);
              if (playing) enableSound({target: playing});
            })('""" + videoId + "');", null);
    }

    private final class VideoPreview implements PlatformView {
        private final int id;
        private final FrameLayout view;
        private final VideoView video;
        private final MediaController controls;
        private boolean prepared;
        private boolean autoplay = true;

        VideoPreview(int id, String path) {
            this.id = id;
            view = new FrameLayout(activity);
            view.setBackgroundColor(Color.BLACK);
            video = new VideoView(activity);
            controls = new MediaController(activity);
            video.setMediaController(controls);
            view.addView(video, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
            video.setOnPreparedListener(player -> {
                prepared = true;
                if (autoplay) video.start();
            });
            video.setOnErrorListener((player, what, extra) -> {
                error();
                return true;
            });
            try {
                video.setVideoPath(attachment(path).getAbsolutePath());
            } catch (IOException error) {
                error();
            }
        }

        private void error() {
            video.setVisibility(View.GONE);
            TextView text = new TextView(activity);
            text.setText("Couldn’t play this video.");
            text.setTextColor(Color.WHITE);
            text.setGravity(Gravity.CENTER);
            view.addView(text, new FrameLayout.LayoutParams(-1, -1));
        }

        void pause() {
            autoplay = false;
            if (prepared) video.pause();
            controls.hide();
        }

        @Override public View getView() { return view; }
        @Override public void dispose() {
            videos.remove(id);
            controls.hide();
            video.stopPlayback();
        }
    }

    private final class WebPreview implements PlatformView {
        private final int id;
        private final FrameLayout frame;
        private final WebView view;
        private boolean failed;

        WebPreview(int id, String initial) {
            this.id = id;
            frame = new FrameLayout(activity);
            view = new WebView(activity);
            frame.addView(view, new FrameLayout.LayoutParams(-1, -1));
            var settings = view.getSettings();
            if (android.os.Build.VERSION.SDK_INT >= 26) settings.setSafeBrowsingEnabled(true);
            settings.setAllowFileAccess(false);
            settings.setAllowContentAccess(false);
            settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            Uri uri = webUri(initial);
            boolean youtubePlayback = uri != null && "m.youtube.com".equals(uri.getHost())
                && "/watch".equals(uri.getPath()) && "1".equals(uri.getQueryParameter("autoplay"));
            settings.setMediaPlaybackRequiresUserGesture(!youtubePlayback);
            android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(view, false);
            view.setWebViewClient(new WebViewClient() {
                @Override public void onPageFinished(WebView page, String url) {
                    if (youtubePlayback) enableYouTubeSound(page, uri.getQueryParameter("v"));
                }

                @Override public boolean shouldOverrideUrlLoading(WebView page, WebResourceRequest request) {
                    return webUri(request.getUrl().toString()) == null;
                }

                @Override public boolean onRenderProcessGone(WebView page, android.webkit.RenderProcessGoneDetail detail) {
                    failed = true;
                    frame.removeView(page);
                    page.destroy();
                    TextView text = new TextView(activity);
                    text.setText("The preview stopped. Open it in your browser to continue.");
                    text.setGravity(Gravity.CENTER);
                    frame.addView(text, new FrameLayout.LayoutParams(-1, -1));
                    return true;
                }
            });
            if (uri != null) view.loadUrl(uri.toString());
        }

        @Override public View getView() { return frame; }
        @Override public void dispose() {
            pages.remove(id);
            if (failed) return;
            frame.removeView(view);
            view.stopLoading();
            view.destroy();
        }
    }
}
