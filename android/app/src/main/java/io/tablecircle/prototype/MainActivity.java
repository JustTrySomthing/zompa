package io.tablecircle.prototype;

import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import androidx.core.content.FileProvider;
import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public final class MainActivity extends FlutterActivity {
    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "io.tablecircle.host")
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "dataPath":
                        result.success(getFilesDir().getAbsolutePath());
                        break;
                    case "scheduleUpdates":
                        UpdateCheckJob.schedule(this, Boolean.TRUE.equals(call.argument("enabled")));
                        result.success(null);
                        break;
                    case "backgroundUpdateBuild":
                        result.success(UpdateCheckJob.cachedBuild(this));
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
            });
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
