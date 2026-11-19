package io.tablecircle.prototype;

import android.Manifest;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodCall;

public final class MainActivity extends FlutterActivity {
    private static final int REQUEST_NOTIFICATIONS = 390;
    private static final int REQUEST_MIC = 393;
    private MethodChannel.Result notificationRequest;
    private MethodChannel.Result micRequest;
    private MethodChannel host;
    private VoicePeer voice;
    private boolean openChats;
    private Ringtone ringing;
    private int ringingId;
    private boolean scanningInvite;
    private static final int PICK_LOVE = 392;
    private MethodChannel.Result gamePicker;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        ChatAlerts.setup(this);
        ChatSyncJob.schedule(this);
        openChats = ChatAlerts.OPEN_CHATS.equals(getIntent().getAction());
        host = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "io.zompado.host");
        voice = new VoicePeer(this, host);
        host.setMethodCallHandler(new MethodChannel.MethodCallHandler() {
                @Override
                public void onMethodCall(MethodCall call, MethodChannel.Result result) {
                switch (call.method) {
                    case "dataPath":
                        result.success(getFilesDir().getAbsolutePath());
                        break;
                    case "chatmailExecutable":
                        ChatSyncJob.claimForApp();
                        File core = ChatSyncJob.executable(MainActivity.this);
                        result.success(core.canExecute() ? core.getAbsolutePath() : null);
                        break;
                    case "importLoveGame":
                        pickLoveGame(result);
                        break;
                    case "removeLoveGame":
                        String id = call.argument("id");
                        if (id == null || !id.matches("[0-9a-f]{64}")) {
                            result.error("LOVE_IMPORT", "Game could not be found.", null);
                            break;
                        }
                        File game = new File(loveDirectory(), id + ".love");
                        result.success(!game.exists() || game.delete());
                        break;
                    case "scanFriendInvite":
                        scanFriendInvite(result);
                        break;
                    case "shareGameLink":
                    case "shareFriendInvite":
                        String invite = call.argument("invite");
                        if (invite == null || invite.isEmpty()) {
                            result.error("FRIEND_INVITE", "Invite is unavailable.", null);
                            break;
                        }
                        Intent shareInvite = new Intent(Intent.ACTION_SEND);
                        shareInvite.setType("text/plain");
                        shareInvite.putExtra(Intent.EXTRA_TEXT, invite);
                        startActivity(Intent.createChooser(shareInvite,
                            call.method.equals("shareGameLink") ? "Share game" : "Share friend invite"));
                        result.success(null);
                        break;
                    case "showChatNotification":
                        Integer chat = call.argument("chat");
                        Integer message = call.argument("message");
                        String label = call.argument("label");
                        if (chat != null && message != null && label != null) {
                            ChatAlerts.post(MainActivity.this, chat, message, label);
                        }
                        result.success(null);
                        break;
                    case "showIncomingCall":
                        Integer incoming = call.argument("message");
                        if (incoming != null) {
                            if (Boolean.TRUE.equals(call.argument("foreground"))) ring(incoming);
                            else ChatAlerts.incoming(MainActivity.this, incoming);
                        }
                        result.success(null);
                        break;
                    case "dismissIncomingCall":
                        Integer ended = call.argument("message");
                        if (ended != null) {
                            if (ringingId == ended) stopRinging();
                            getSystemService(NotificationManager.class).cancel("voice", ended);
                        }
                        result.success(null);
                        break;
                    case "takeOpenChats":
                        result.success(openChats);
                        openChats = false;
                        break;
                    case "requestMicrophone":
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                                == PackageManager.PERMISSION_GRANTED) {
                            result.success(true);
                        } else if (micRequest == null) {
                            micRequest = result;
                            requestPermissions(new String[] { Manifest.permission.RECORD_AUDIO }, REQUEST_MIC);
                        } else {
                            result.success(false);
                        }
                        break;
                    case "voiceStart":
                        voice.start(call.argument("token"), call.argument("ice"), call.argument("offer"), result);
                        break;
                    case "voiceAnswer":
                        voice.answer(call.argument("token"), call.argument("answer"), result);
                        break;
                    case "voiceEnd":
                        voice.end(call.argument("token"));
                        result.success(null);
                        break;
                    case "voiceMute":
                        result.success(voice.mute(call.argument("token"), Boolean.TRUE.equals(call.argument("value"))));
                        break;
                    case "voiceSpeaker":
                        result.success(voice.speaker(call.argument("token"), Boolean.TRUE.equals(call.argument("value"))));
                        break;
                    case "setupStatus":
                        HashMap<String, Boolean> statuses = new HashMap<>();
                        statuses.put("notifications", updateAlertsEnabled());
                        statuses.put("microphone", checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                            == PackageManager.PERMISSION_GRANTED);
                        statuses.put("updateInstall", Build.VERSION.SDK_INT < 26
                            || getPackageManager().canRequestPackageInstalls());
                        result.success(statuses);
                        break;
                    case "requestUpdateNotifications":
                        if (Build.VERSION.SDK_INT >= 33
                                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                                    != PackageManager.PERMISSION_GRANTED
                                && !getPreferences(MODE_PRIVATE).getBoolean("asked_update_alerts", false)) {
                            if (notificationRequest != null) {
                                result.error("NOTIFICATION_REQUEST", "A permission prompt is already open.", null);
                                break;
                            }
                            notificationRequest = result;
                            getPreferences(MODE_PRIVATE).edit().putBoolean("asked_update_alerts", true).apply();
                            requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS },
                                REQUEST_NOTIFICATIONS);
                        } else {
                            if (!updateAlertsEnabled()) {
                                Intent notificationSettings = Build.VERSION.SDK_INT >= 26
                                    ? new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                        .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())
                                    : new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:" + getPackageName()));
                                startActivity(notificationSettings);
                            }
                            result.success(null);
                        }
                        break;
                    case "openUpdateInstallSettings":
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:" + getPackageName())));
                        }
                        result.success(null);
                        break;
                    case "scheduleUpdates":
                        UpdateCheckJob.schedule(MainActivity.this, Boolean.TRUE.equals(call.argument("enabled")));
                        result.success(null);
                        break;
                    case "backgroundUpdateBuild":
                        result.success(UpdateCheckJob.cachedBuild(MainActivity.this));
                        break;
                    case "installUpdate":
                        try {
                            String path = call.argument("path");
                            Integer version = call.argument("build");
                            result.success(installUpdate(path, version));
                        } catch (IOException | PackageManager.NameNotFoundException | RuntimeException error) {
                            result.error("INSTALL_UPDATE", error.getMessage(), null);
                        }
                        break;
                    default:
                        result.notImplemented();
                }
                }
            });
    }

    private File loveDirectory() {
        return new File(getFilesDir(), "imported-love");
    }

    private void pickLoveGame(MethodChannel.Result result) {
        if (gamePicker != null) {
            result.error("LOVE_IMPORT", "A game import is already open.", null);
            return;
        }
        Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*");
        try {
            gamePicker = result;
            startActivityForResult(picker, PICK_LOVE);
        } catch (RuntimeException error) {
            gamePicker = null;
            result.error("LOVE_IMPORT", "Couldn’t open the Android file picker.", null);
        }
    }

    @Override
    protected void onActivityResult(int request, int status, Intent data) {
        super.onActivityResult(request, status, data);
        if (request != PICK_LOVE || gamePicker == null) return;
        MethodChannel.Result result = gamePicker;
        Uri source = data == null ? null : data.getData();
        if (status != RESULT_OK || source == null) {
            gamePicker = null;
            result.success(null);
            return;
        }
        new Thread(() -> {
            try {
                final Map<String, Object> imported =
                    LoveImport.stage(getContentResolver(), source, loveDirectory());
                runOnUiThread(() -> {
                    gamePicker = null;
                    result.success(imported);
                });
            } catch (IOException error) {
                String message = error instanceof java.util.zip.ZipException
                    ? "This file isn’t a readable .love archive."
                    : error.getMessage();
                runOnUiThread(() -> {
                    gamePicker = null;
                    result.error("LOVE_IMPORT", message, null);
                });
            } catch (RuntimeException error) {
                runOnUiThread(() -> {
                    gamePicker = null;
                    result.error("LOVE_IMPORT", "Couldn’t read this game.", null);
                });
            }
        }, "zompado-love-import").start();
    }

    private void scanFriendInvite(MethodChannel.Result result) {
        if (scanningInvite) {
            result.error("INVITE_SCAN", "Scanner is already open.", null);
            return;
        }
        scanningInvite = true;
        GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build();
        try {
            GmsBarcodeScanning.getClient(this, options).startScan()
                .addOnCompleteListener(task -> {
                    scanningInvite = false;
                    if (task.isCanceled()) {
                        result.success(null);
                    } else if (task.isSuccessful()) {
                        result.success(task.getResult().getRawValue());
                    } else {
                        result.error("INVITE_SCAN", "Couldn’t open the QR scanner.", null);
                    }
                });
        } catch (RuntimeException error) {
            scanningInvite = false;
            result.error("INVITE_SCAN", "Couldn’t open the QR scanner.", null);
        }
    }

    private void ring(int message) {
        stopRinging();
        if (getSystemService(AudioManager.class).getRingerMode() != AudioManager.RINGER_MODE_NORMAL) return;
        try {
            Ringtone tone = RingtoneManager.getRingtone(this,
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE));
            if (tone == null) return;
            tone.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build());
            if (Build.VERSION.SDK_INT >= 28) tone.setLooping(true);
            ringing = tone;
            ringingId = message;
            tone.play();
        } catch (RuntimeException ignored) {
            stopRinging();
        }
    }

    private void stopRinging() {
        if (ringing != null) ringing.stop();
        ringing = null;
        ringingId = 0;
    }

    @Override
    protected void onStop() {
        stopRinging();
        super.onStop();
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (ChatAlerts.OPEN_CHATS.equals(intent.getAction())) {
            openChats = true;
            if (host != null) host.invokeMethod("openChats", null);
        }
    }

    @Override
    public void cleanUpFlutterEngine(FlutterEngine engine) {
        stopRinging();
        if (voice != null) voice.dispose();
        if (host != null) host.setMethodCallHandler(null);
        ChatSyncJob.releaseFromApp();
        super.cleanUpFlutterEngine(engine);
    }

    private boolean updateAlertsEnabled() {
        return getSystemService(NotificationManager.class).areNotificationsEnabled();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_NOTIFICATIONS && notificationRequest != null) {
            notificationRequest.success(null);
            notificationRequest = null;
        }
        if (requestCode == REQUEST_MIC && micRequest != null) {
            micRequest.success(grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED);
            micRequest = null;
        }
    }

    @SuppressWarnings("deprecation")
    private String installUpdate(String path, Integer expectedVersion)
        throws IOException, PackageManager.NameNotFoundException {
        if (path == null || expectedVersion == null || expectedVersion < 1) {
            throw new IOException("Update is missing.");
        }
        File expected = new File(new File(getFilesDir(), "updates"), expectedVersion + ".apk").getCanonicalFile();
        if (!new File(path).getCanonicalFile().equals(expected) || !expected.isFile()) {
            throw new IOException("Update file is missing.");
        }
        PackageManager manager = getPackageManager();
        PackageInfo running = manager.getPackageInfo(getPackageName(), PackageManager.GET_SIGNATURES);
        PackageInfo incoming = manager.getPackageArchiveInfo(expected.getPath(), PackageManager.GET_SIGNATURES);
        if (incoming == null || !getPackageName().equals(incoming.packageName)
                || incoming.versionCode != expectedVersion || incoming.versionCode <= running.versionCode
                || running.signatures == null || running.signatures.length == 0
                || !Arrays.equals(running.signatures, incoming.signatures)) {
            throw new IOException("This APK doesn’t match the installed app’s identity, version, or signing certificate.");
        }
        if (Build.VERSION.SDK_INT >= 26 && !manager.canRequestPackageInstalls()) {
            startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + getPackageName())));
            return "permission";
        }
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".updates", expected);
        Intent installer = new Intent(Intent.ACTION_VIEW);
        installer.setDataAndType(uri, "application/vnd.android.package-archive");
        installer.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(installer);
        return "installer";
    }
}
