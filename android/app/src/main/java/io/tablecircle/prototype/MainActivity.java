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
import android.os.SystemClock;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import com.journeyapps.barcodescanner.ScanIntentResult;
import com.journeyapps.barcodescanner.ScanOptions;
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
    private static final int REQUEST_CAMERA = 394;
    private static final int SCAN_INVITE = 395;
    private static final String CAMERA_DENIED = "denied_camera";
    private MethodChannel.Result notificationRequest;
    private MethodChannel.Result micRequest;
    private MethodChannel host;
    private VoicePeer voice;
    private final ChatFiles chatFiles = new ChatFiles(this);
    private boolean openChats;
    private Map<String, Object> chatAlert;
    private Ringtone ringing;
    private int ringingId;
    private int ringingChat;
    private long ringDeadline;
    private MethodChannel.Result inviteScan;
    private MethodChannel.Result cameraSetup;
    private MethodChannel.Result cameraCall;
    private static final int PICK_LOVE = 392;
    private MethodChannel.Result gamePicker;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        flutterEngine.getPlatformViewsController().getRegistry().registerViewFactory(
            "io.zompado.love", new LovePlayer.Factory(flutterEngine.getDartExecutor().getBinaryMessenger()));
        ChatAlerts.setup(this);
        ChatSyncJob.schedule(this);
        readChatIntent(getIntent());
        host = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "io.zompado.host");
        voice = new VoicePeer(this, host);
        flutterEngine.getPlatformViewsController().getRegistry().registerViewFactory(
            "io.zompado.callVideo", new io.flutter.plugin.platform.PlatformViewFactory(
                io.flutter.plugin.common.StandardMessageCodec.INSTANCE) {
                @Override public io.flutter.plugin.platform.PlatformView create(
                        android.content.Context context, int viewId, Object args) {
                    return voice.videoView();
                }
            });
        host.setMethodCallHandler(new MethodChannel.MethodCallHandler() {
                @Override
                public void onMethodCall(MethodCall call, MethodChannel.Result result) {
                switch (call.method) {
                    case "dataPath":
                        result.success(getFilesDir().getAbsolutePath());
                        break;
                    case "chatmailExecutable":
                        openChatmail(result);
                        break;
                    case "checkLoveGame":
                        if (!(call.arguments instanceof Map)) {
                            result.error("LOVE_IMPORT", "Invalid game reference.", null);
                            break;
                        }
                        Map<?, ?> gameReference = (Map<?, ?>) call.arguments;
                        new Thread(() -> {
                            try {
                                LovePlayer.verify(MainActivity.this, gameReference);
                                runOnUiThread(() -> result.success(null));
                            } catch (Exception error) {
                                runOnUiThread(() -> result.error("LOVE_IMPORT", error.getMessage(), null));
                            }
                        }, "zompado-love-check").start();
                        break;
                    case "pickChatFile":
                        chatFiles.pick((String) call.arguments, result);
                        break;
                    case "prepareChatMedia":
                        chatFiles.prepare(call.argument("path"), call.argument("name"), call.argument("mime"),
                            Boolean.TRUE.equals(call.argument("dataSaver")), result);
                        break;
                    case "downloadChatFile":
                        chatFiles.download(call.argument("path"), call.argument("name"), call.argument("mime"), result);
                        break;
                    case "startChatRecording":
                        chatFiles.startRecording(result);
                        break;
                    case "stopChatRecording":
                        result.success(chatFiles.stopRecording(Boolean.TRUE.equals(call.argument("keep"))));
                        break;
                    case "stageContactCard":
                        chatFiles.card((String) call.arguments, result);
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
                    case "requestCamera":
                        requestCameraForSetup(result);
                        break;
                    case "openCameraSettings":
                        openAppSettings();
                        result.success(null);
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
                    case "chatNotificationSettings":
                        result.success(ChatAlerts.settings(MainActivity.this));
                        break;
                    case "setChatNotification":
                        String notificationKey = call.argument("key");
                        boolean notificationValue = Boolean.TRUE.equals(call.argument("value"));
                        if (!ChatAlerts.set(MainActivity.this, notificationKey, notificationValue)) {
                            result.error("NOTIFICATION_SETTINGS", "Couldn’t save notifications.", null);
                            break;
                        }
                        if (!ChatAlerts.allowed(MainActivity.this, "calls")) stopRinging();
                        result.success(null);
                        break;
                    case "openNotificationSettings":
                        openNotificationSettings();
                        result.success(null);
                        break;
                    case "showChatNotification":
                        Integer chat = call.argument("chat");
                        Integer message = call.argument("message");
                        String label = call.argument("label");
                        if (chat != null && message != null && label != null) {
                            ChatAlerts.post(MainActivity.this, chat, message, label, call.argument("kind"));
                        }
                        result.success(null);
                        break;
                    case "showIncomingCall":
                        Integer incoming = call.argument("message");
                        Integer incomingChat = call.argument("chat");
                        Integer secondsLeft = call.argument("secondsLeft");
                        if (incoming != null && incomingChat != null && secondsLeft != null) {
                            if (Boolean.TRUE.equals(call.argument("foreground"))) {
                                ring(incomingChat, incoming, secondsLeft);
                            } else {
                                ChatAlerts.incoming(MainActivity.this, incomingChat, incoming, secondsLeft);
                            }
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
                    case "takeChatAlert":
                        result.success(openChats && chatAlert == null ? new HashMap<>() : chatAlert);
                        openChats = false;
                        chatAlert = null;
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
                    case "requestCallCamera":
                        if (hasCameraPermission()) {
                            result.success(true);
                        } else if (!cameraAvailable() || cameraBlocked()) {
                            result.success(false);
                        } else if (inviteScan == null && cameraSetup == null && cameraCall == null) {
                            cameraCall = result;
                            requestPermissions(new String[] { Manifest.permission.CAMERA }, REQUEST_CAMERA);
                        } else {
                            result.success(false);
                        }
                        break;
                    case "voiceCamera":
                        result.success(voice.camera(call.argument("token"), Boolean.TRUE.equals(call.argument("value"))));
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
                        statuses.put("cameraAvailable", cameraAvailable());
                        statuses.put("camera", hasCameraPermission());
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
                                openNotificationSettings();
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
        if (chatFiles.picked(request, status, data)) return;
        if (request == SCAN_INVITE && inviteScan != null) {
            MethodChannel.Result result = inviteScan;
            inviteScan = null;
            result.success(data == null ? null : ScanIntentResult.parseActivityResult(status, data).getContents());
            return;
        }
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

    private boolean cameraAvailable() {
        return getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY);
    }

    private boolean hasCameraPermission() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean cameraBlocked() {
        return getPreferences(MODE_PRIVATE).getBoolean(CAMERA_DENIED, false)
            && !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA);
    }

    private void openAppSettings() {
        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", getPackageName(), null)));
    }

    private void requestCameraForSetup(MethodChannel.Result result) {
        if (!cameraAvailable() || hasCameraPermission()) {
            result.success(null);
        } else if (inviteScan != null || cameraSetup != null || cameraCall != null) {
            result.error("CAMERA_BUSY", "A camera request is already open.", null);
        } else if (cameraBlocked()) {
            openAppSettings();
            result.success(null);
        } else {
            cameraSetup = result;
            requestPermissions(new String[] { Manifest.permission.CAMERA }, REQUEST_CAMERA);
        }
    }

    private void scanFriendInvite(MethodChannel.Result result) {
        if (inviteScan != null || cameraSetup != null || cameraCall != null) {
            result.error("CAMERA_BUSY", "A camera request is already open.", null);
        } else if (!cameraAvailable()) {
            result.error("CAMERA_UNAVAILABLE", "This device has no camera.", null);
        } else if (hasCameraPermission()) {
            inviteScan = result;
            openInviteScanner();
        } else if (cameraBlocked()) {
            result.error("CAMERA_PERMISSION", "Allow camera access in Android settings.", null);
        } else {
            inviteScan = result;
            requestPermissions(new String[] { Manifest.permission.CAMERA }, REQUEST_CAMERA);
        }
    }

    private void openInviteScanner() {
        ScanOptions options = new ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt("Point the camera at your friend’s invite QR code")
            .setBeepEnabled(false)
            .setOrientationLocked(false);
        try {
            startActivityForResult(options.createScanIntent(this), SCAN_INVITE);
        } catch (RuntimeException error) {
            MethodChannel.Result result = inviteScan;
            inviteScan = null;
            result.error("INVITE_SCAN", "Couldn’t open the camera.", null);
        }
    }

    private void openNotificationSettings() {
        Intent settings = Build.VERSION.SDK_INT >= 26
            ? new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName())
            : new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()));
        startActivity(settings);
    }

    private void ring(int chat, int message, int secondsLeft) {
        stopRinging();
        ringingId = message;
        ringingChat = chat;
        ringDeadline = SystemClock.elapsedRealtime() + secondsLeft * 1000L;
        if (!ChatAlerts.allowed(this, "calls")) return;
        if (getSystemService(AudioManager.class).getRingerMode() != AudioManager.RINGER_MODE_NORMAL) return;
        try {
            Ringtone tone = RingtoneManager.getRingtone(this,
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE));
            if (tone == null) return;
            tone.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build());
            if (Build.VERSION.SDK_INT >= 28) tone.setLooping(true);
            ringing = tone;
            tone.play();
        } catch (RuntimeException ignored) {
            ringing = null;
        }
    }

    private void stopRinging() {
        if (ringing != null) ringing.stop();
        ringing = null;
        ringingId = 0;
        ringingChat = 0;
        ringDeadline = 0;
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (voice != null) voice.setVisible(true);
    }

    @Override
    protected void onStop() {
        if (voice != null) voice.setVisible(false);
        chatFiles.stopRecording(false);
        long remaining = ringDeadline - SystemClock.elapsedRealtime();
        if (ringingId > 0 && remaining > 0) {
            ChatAlerts.incoming(this, ringingChat, ringingId, (remaining + 999) / 1000);
        }
        stopRinging();
        super.onStop();
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (ChatAlerts.OPEN_CHATS.equals(intent.getAction())) {
            readChatIntent(intent);
            if (host != null) host.invokeMethod("openChats", null);
        }
    }

    private void readChatIntent(Intent intent) {
        if (!ChatAlerts.OPEN_CHATS.equals(intent.getAction())) return;
        openChats = true;
        int chat = intent.getIntExtra(ChatAlerts.ALERT_CHAT, 0);
        int message = intent.getIntExtra(ChatAlerts.ALERT_MESSAGE, 0);
        boolean call = intent.getBooleanExtra(ChatAlerts.INCOMING_CALL, false);
        if (ChatAlerts.isTrustedAlert(this, intent) && chat > 0 && message > 0) {
            chatAlert = new HashMap<>();
            chatAlert.put("chat", chat);
            chatAlert.put("message", message);
            chatAlert.put("incomingCall", call);
            intent.removeExtra(ChatAlerts.ALERT_CHAT);
            intent.removeExtra(ChatAlerts.ALERT_MESSAGE);
            intent.removeExtra(ChatAlerts.INCOMING_CALL);
        } else {
            chatAlert = null;
        }
    }

    private void openChatmail(MethodChannel.Result result) {
        Process backgroundCore = ChatSyncJob.claimForApp();
        File core = ChatSyncJob.executable(this);
        String path = core.canExecute() ? core.getAbsolutePath() : null;
        if (backgroundCore == null) {
            result.success(path);
            return;
        }
        new Thread(() -> {
            try {
                backgroundCore.waitFor();
                runOnUiThread(() -> result.success(path));
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                runOnUiThread(() -> result.success(null));
            }
        }, "zompado-chat-handoff").start();
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
        if (requestCode == REQUEST_CAMERA) {
            boolean granted = hasCameraPermission();
            if (grantResults.length > 0) {
                getPreferences(MODE_PRIVATE).edit().putBoolean(CAMERA_DENIED, !granted).apply();
            }
            if (cameraSetup != null) {
                MethodChannel.Result result = cameraSetup;
                cameraSetup = null;
                result.success(null);
            } else if (cameraCall != null) {
                MethodChannel.Result result = cameraCall;
                cameraCall = null;
                result.success(granted);
            } else if (inviteScan != null) {
                if (granted) {
                    openInviteScanner();
                } else {
                    MethodChannel.Result result = inviteScan;
                    inviteScan = null;
                    result.error("CAMERA_PERMISSION", "Allow camera access to scan a QR code.", null);
                }
            }
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
