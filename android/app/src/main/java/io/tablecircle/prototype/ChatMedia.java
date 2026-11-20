package io.tablecircle.prototype;

import android.content.Context;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.SonicAudioProcessor;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Presentation;
import androidx.media3.transformer.AudioEncoderSettings;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.DefaultEncoderFactory;
import androidx.media3.transformer.EditedMediaItem;
import androidx.media3.transformer.Effects;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.Transformer;
import androidx.media3.transformer.VideoEncoderSettings;
import java.io.File;
import java.util.Collections;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

/** Uses Relay Lab's AAC/H.264 preparation and keeps a source if encoding doesn't make it smaller. */
@UnstableApi
final class ChatMedia {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    static void prepare(Context context, File source, String mime, boolean saver, Consumer<File> receive) {
        boolean video = mime.startsWith("video/");
        if ((!video && !mime.startsWith("audio/")) || source.length() <= 1_000_000L) {
            receive.accept(null);
            return;
        }
        new Thread(() -> {
            long duration;
            int height;
            MediaMetadataRetriever metadata = new MediaMetadataRetriever();
            try {
                metadata.setDataSource(source.getAbsolutePath());
                duration = Long.parseLong(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
                boolean rotated = "90".equals(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION))
                    || "270".equals(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION));
                String size = metadata.extractMetadata(rotated ? MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
                    : MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT);
                height = size == null ? 480 : Integer.parseInt(size);
            } catch (Exception unsupported) {
                MAIN.post(() -> receive.accept(null));
                return;
            } finally {
                try { metadata.release(); } catch (Exception ignored) {}
            }
            MAIN.post(() -> export(context, source, video, saver, duration, height, receive));
        }, "zompado-media-metadata").start();
    }

    private static void export(Context context, File source, boolean video, boolean saver,
            long duration, int height, Consumer<File> receive) {
        if (duration <= 0) {
            receive.accept(null);
            return;
        }
        File output;
        try {
            output = File.createTempFile("prepared-", video ? ".mp4" : ".m4a", source.getParentFile());
            if (!output.delete()) {
                receive.accept(null);
                return;
            }
        } catch (Exception unavailable) {
            receive.accept(null);
            return;
        }
        new Export(context, source, output, video, saver, duration, height, receive).start();
    }

    private static final class Export implements Transformer.Listener {
        final Context context;
        final File source, output;
        final boolean video, saver;
        final long duration;
        final int height;
        final Consumer<File> receive;
        final Runnable timeout = this::cancel;
        Transformer transformer;
        boolean finished;

        Export(Context context, File source, File output, boolean video, boolean saver,
                long duration, int height, Consumer<File> receive) {
            this.context = context;
            this.source = source;
            this.output = output;
            this.video = video;
            this.saver = saver;
            this.duration = duration;
            this.height = height;
            this.receive = receive;
        }

        void start() {
            long target = (saver ? 6_000_000_000L : 8_000_000_000L) / Math.max(duration, 1000L);
            int audioRate = video ? (saver ? 48_000 : 64_000)
                : (int) Math.max(48_000, Math.min(target, saver ? 64_000 : 96_000));
            int videoRate = (int) Math.max(saver ? 240_000 : 320_000,
                Math.min(target - audioRate, saver ? 1_000_000 : 1_400_000));
            try {
                var audio = new SonicAudioProcessor();
                audio.setOutputSampleRateHz(32_000);
                var effects = new Effects(Collections.singletonList(audio), video
                    ? Collections.singletonList(Presentation.createForHeight(Math.max(2, Math.min(height, saver ? 360 : 480))))
                    : Collections.emptyList());
                var edited = new EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source)))
                    .setRemoveVideo(!video).setEffects(effects).build();
                var builder = new Transformer.Builder(context).setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(new DefaultEncoderFactory.Builder(context)
                        .setRequestedAudioEncoderSettings(new AudioEncoderSettings.Builder().setBitrate(audioRate).build())
                        .setRequestedVideoEncoderSettings(new VideoEncoderSettings.Builder().setBitrate(videoRate).build())
                        .build())
                    .addListener(this);
                if (video) builder.setVideoMimeType(MimeTypes.VIDEO_H264);
                transformer = builder.build();
                MAIN.postDelayed(timeout, TimeUnit.MINUTES.toMillis(12));
                transformer.start(edited, output.getAbsolutePath());
            } catch (RuntimeException error) {
                finish(false);
            }
        }

        private void cancel() {
            try { if (transformer != null) transformer.cancel(); } finally { finish(false); }
        }

        @Override public void onCompleted(Composition composition, ExportResult result) {
            finish(true);
        }

        @Override public void onError(Composition composition, ExportResult result, ExportException error) {
            finish(false);
        }

        private void finish(boolean success) {
            if (finished) return;
            finished = true;
            MAIN.removeCallbacks(timeout);
            long size = output.length();
            if (success && size > 0 && size < source.length()) {
                receive.accept(output);
            } else {
                output.delete();
                receive.accept(null);
            }
        }
    }
}
