package io.tablecircle.prototype;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
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
    private final Activity activity;
    private MethodChannel.Result picker;
    private File capture;
    private String captureName;

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
                    .setClipData(ClipData.newRawUri("Capture destination", output))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
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
                    file = reference(output, outputName);
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
        return reference(file, name);
    }

    private static Map<String, String> reference(File file, String name) {
        Map<String, String> values = new HashMap<>();
        values.put("path", file.getAbsolutePath());
        values.put("name", name);
        return values;
    }

    void card(String vcard, MethodChannel.Result result) {
        if (vcard == null || vcard.trim().isEmpty()) {
            result.error("ATTACHMENT", "The contact card is empty.", null);
            return;
        }
        try {
            File file = File.createTempFile("contact-", ".vcf", directory());
            Files.write(file.toPath(), vcard.getBytes(StandardCharsets.UTF_8));
            result.success(reference(file, "Contact card.vcf"));
        } catch (IOException failure) {
            result.error("ATTACHMENT", "Couldn’t create a contact card.", null);
        }
    }
}
