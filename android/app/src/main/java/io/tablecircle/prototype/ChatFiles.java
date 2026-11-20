package io.tablecircle.prototype;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.media.MediaRecorder;
import android.os.Build;
import android.webkit.MimeTypeMap;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import androidx.core.content.FileProvider;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;

final class ChatFiles {
    private static final int REQUEST = 398;
    private static final int SAVE_REQUEST = 399;
    private final Activity activity;
    private MethodChannel.Result picker;
    private File capture;
    private String captureName;
    private MethodChannel.Result saver;
    private File download;
    private MediaRecorder microphone;
    private File recording;

    ChatFiles(Activity activity) {
        this.activity = activity;
    }

    private File directory() throws IOException {
        File directory = new File(activity.getCacheDir(), "chat-files");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("No attachment storage");
        return directory;
    }

    private Uri uri(File file) {
        return FileProvider.getUriForFile(activity, activity.getPackageName() + ".chatfiles", file);
    }

    void pick(String type, MethodChannel.Result result) {
        if (picker != null) {
            result.error("ATTACHMENT", "The file picker is already open.", null);
            return;
        }
        try {
            Intent intent;
            if ("capture-photo".equals(type) || "capture-video".equals(type)) {
                boolean video = "capture-video".equals(type);
                captureName = video ? "Recorded video.mp4" : "Photo.jpg";
                capture = File.createTempFile("capture-", video ? ".mp4" : ".jpg", directory());
                Uri output = uri(capture);
                intent = new Intent(video ? MediaStore.ACTION_VIDEO_CAPTURE : MediaStore.ACTION_IMAGE_CAPTURE)
                    .putExtra(MediaStore.EXTRA_OUTPUT, output)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                intent.setClipData(ClipData.newRawUri("Capture destination", output));
            } else if ("capture-audio".equals(type)) {
                intent = new Intent(MediaStore.Audio.Media.RECORD_SOUND_ACTION);
            } else {
                intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE);
                if ("text/vcard".equals(type)) {
                    intent.setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES,
                        new String[] {"text/vcard", "text/x-vcard", "application/vcard", "application/octet-stream"});
                } else {
                    intent.setType(type == null ? "*/*" : type);
                }
            }
            picker = result;
            activity.startActivityForResult(intent, REQUEST);
        } catch (Exception unavailable) {
            if (capture != null) capture.delete();
            capture = null;
            picker = null;
            result.error("ATTACHMENT", "Android couldn’t open this option. Try selecting a file.", null);
        }
    }

    boolean picked(int request, int status, Intent data) {
        if (request == SAVE_REQUEST) return saved(status, data);
        if (request != REQUEST) return false;
        MethodChannel.Result result = picker;
        picker = null;
        File output = capture;
        String outputName = captureName;
        capture = null;
        if (result == null) return true;
        if (status != Activity.RESULT_OK) {
            if (output != null) output.delete();
            result.success(null);
            return true;
        }
        new Thread(() -> {
            try {
                Map<String, String> file;
                if (output != null && output.length() > 0) {
                    file = reference(output, outputName, mimeForName(outputName));
                } else {
                    if (output != null) output.delete();
                    file = copyDocument(data == null ? null : data.getData());
                }
                activity.runOnUiThread(() -> result.success(file));
            } catch (Exception failure) {
                if (output != null) output.delete();
                activity.runOnUiThread(() -> result.error("ATTACHMENT", "Couldn’t read this file.", null));
            }
        }, "zompado-attachment").start();
        return true;
    }

    private Map<String, String> copyDocument(Uri source) throws IOException {
        if (source == null) throw new IOException("Missing attachment");
        var resolver = activity.getContentResolver();
        String name = "Attachment";
        try (var cursor = resolver.query(source, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && cursor.getString(0) != null) name = cursor.getString(0);
        }
        int dot = name.lastIndexOf('.');
        String extension = dot < 0 ? "" : name.substring(dot);
        if (!extension.matches("\\.[a-zA-Z0-9]{1,10}")) extension = ".attachment";
        File file = File.createTempFile("draft-", extension, directory());
        try (var input = resolver.openInputStream(source)) {
            if (input == null) throw new IOException("Missing attachment stream");
            Files.copy(input, file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception failure) {
            file.delete();
            throw failure;
        }
        String mime = resolver.getType(source);
        if (mime == null || "application/octet-stream".equals(mime)) mime = mimeForName(name);
        return reference(file, name, mime);
    }

    private static String mimeForName(String name) {
        int dot = name.lastIndexOf('.');
        String mime = dot < 0 ? null : MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase(java.util.Locale.ROOT));
        return mime == null ? "application/octet-stream" : mime;
    }

    private static Map<String, String> reference(File file, String name, String mime) {
        Map<String, String> values = new HashMap<>();
        values.put("path", file.getAbsolutePath());
        values.put("name", name);
        values.put("mime", mime);
        return values;
    }

    @androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
    void prepare(String path, String name, String mime, boolean saver, MethodChannel.Result result) {
        try {
            File input = new File(path).getCanonicalFile();
            if (!directory().getCanonicalFile().equals(input.getParentFile()) || !input.isFile()) {
                throw new IOException("Invalid attachment path");
            }
            ChatMedia.prepare(activity.getApplicationContext(), input, mime, saver, output -> {
                if (output == null) {
                    result.success(null);
                    return;
                }
                int dot = name.lastIndexOf('.');
                String stem = dot > 0 ? name.substring(0, dot) : name;
                boolean video = mime.startsWith("video/");
                result.success(reference(output, stem + (video ? ".mp4" : ".m4a"), video ? "video/mp4" : "audio/mp4"));
            });
        } catch (Exception failure) {
            result.error("ATTACHMENT", "Couldn’t prepare this attachment.", null);
        }
    }

    void download(String path, String name, String mime, MethodChannel.Result result) {
        if (saver != null) {
            result.error("ATTACHMENT", "The file picker is already open.", null);
            return;
        }
        try {
            File source = new File(path).getCanonicalFile();
            File accounts = new File(activity.getFilesDir(), "chatmail").getCanonicalFile();
            if (!source.toPath().startsWith(accounts.toPath()) || !source.isFile()
                    || !source.getParentFile().getName().endsWith("-blobs")) {
                throw new IOException("Invalid chat attachment");
            }
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType(mime == null ? mimeForName(name) : mime)
                .putExtra(Intent.EXTRA_TITLE, name.replace('/', '_').replace('\\', '_'));
            saver = result;
            download = source;
            activity.startActivityForResult(intent, SAVE_REQUEST);
        } catch (Exception failure) {
            saver = null;
            download = null;
            result.error("ATTACHMENT", "Couldn’t open a destination.", null);
        }
    }

    private boolean saved(int status, Intent data) {
        MethodChannel.Result result = saver;
        File source = download;
        saver = null;
        download = null;
        if (result == null) return true;
        Uri destination = data == null ? null : data.getData();
        if (status != Activity.RESULT_OK || destination == null) {
            result.success(false);
            return true;
        }
        new Thread(() -> {
            try (var output = activity.getContentResolver().openOutputStream(destination, "wt")) {
                if (output == null) throw new IOException("Missing destination");
                Files.copy(source.toPath(), output);
                activity.runOnUiThread(() -> result.success(true));
            } catch (Exception failure) {
                activity.runOnUiThread(() -> result.error("ATTACHMENT", "Couldn’t save the file.", null));
            }
        }, "zompado-save-attachment").start();
        return true;
    }

    @SuppressWarnings("deprecation")
    void startRecording(MethodChannel.Result result) {
        if (microphone != null) {
            result.error("RECORDING", "A recording is already in progress.", null);
            return;
        }
        try {
            recording = File.createTempFile("recording-", ".m4a", directory());
            microphone = Build.VERSION.SDK_INT >= 31 ? new MediaRecorder(activity) : new MediaRecorder();
            microphone.setAudioSource(MediaRecorder.AudioSource.MIC);
            microphone.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            microphone.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            microphone.setAudioChannels(1);
            microphone.setAudioSamplingRate(32_000);
            microphone.setAudioEncodingBitRate(48_000);
            microphone.setOutputFile(recording.getAbsolutePath());
            microphone.prepare();
            microphone.start();
            result.success(null);
        } catch (Exception failure) {
            stopRecording(false);
            result.error("RECORDING", "Couldn’t start recording.", null);
        }
    }

    Map<String, String> stopRecording(boolean keep) {
        var recorder = microphone;
        var file = recording;
        microphone = null;
        recording = null;
        if (recorder != null) {
            try { recorder.stop(); } catch (RuntimeException invalid) { keep = false; }
            finally { recorder.release(); }
        }
        if (file == null) return null;
        if (keep && file.length() > 0) return reference(file, "Voice recording.m4a", "audio/mp4");
        file.delete();
        return null;
    }

    void card(String vcard, MethodChannel.Result result) {
        if (vcard == null || vcard.trim().isEmpty()) {
            result.error("ATTACHMENT", "The contact card is empty.", null);
            return;
        }
        try {
            File file = File.createTempFile("contact-", ".vcf", directory());
            Files.write(file.toPath(), vcard.getBytes(StandardCharsets.UTF_8));
            result.success(reference(file, "Contact card.vcf", "text/vcard"));
        } catch (IOException failure) {
            result.error("ATTACHMENT", "Couldn’t create a contact card.", null);
        }
    }
}
