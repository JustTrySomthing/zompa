package io.tablecircle.prototype;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import androidx.core.app.NotificationCompat;
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
    private static final String CHAT_CHANNEL = "friend_activity";
    private MethodChannel.Result notificationRequest;
    private boolean scanningInvite;
    private static final int PICK_LOVE = 392;
    private MethodChannel.Result gamePicker;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager.class).createNotificationChannel(
                new NotificationChannel(CHAT_CHANNEL, "Friend activity",
                    NotificationManager.IMPORTANCE_DEFAULT));
        }
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "io.zompado.host")
            .setMethodCallHandler(new MethodChannel.MethodCallHandler() {
                @Override
                public void onMethodCall(MethodCall call, MethodChannel.Result result) {
                switch (call.method) {
                    case "dataPath":
                        result.success(getFilesDir().getAbsolutePath());
                        break;
                    case "chatmailExecutable":
                        File core = new File(getApplicationInfo().nativeLibraryDir, "libchatmail_rpc.so");
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
                        showChatNotification(call.argument("chat"), call.argument("label"));
                        result.success(null);
                        break;
                    case "setupStatus":
                        HashMap<String, Boolean> statuses = new HashMap<>();
                        statuses.put("notifications", updateAlertsEnabled());
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

    private void showChatNotification(Integer chat, String label) {
        if (chat == null || label == null || !updateAlertsEnabled()) return;
        Intent intent = new Intent(this, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent open = PendingIntent.getActivity(this, 391, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        getSystemService(NotificationManager.class).notify("friend-activity", chat,
            new NotificationCompat.Builder(this, CHAT_CHANNEL)
                .setSmallIcon(R.drawable.zompado_icon_monochrome)
                .setContentTitle(label)
                .setContentText("Open Zompado to see what’s new.")
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build());
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
