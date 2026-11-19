plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val chatmailNativeLibraries = layout.buildDirectory.dir("chatmail/jniLibs")
val chatmailInstaller = rootProject.file("../tools/install_chatmail_core.sh")
val chatmailExecutable = chatmailNativeLibraries.map { it.file("arm64-v8a/libchatmail_rpc.so") }

val androidSdkLocation = androidComponents.sdkComponents.sdkDirectory
val installChatmailCore by tasks.registering(Exec::class) {
    environment("ANDROID_SDK_ROOT", androidSdkLocation.get().asFile.absolutePath)
    inputs.file(chatmailInstaller)
    outputs.file(chatmailExecutable)
    commandLine("bash", chatmailInstaller.absolutePath, chatmailExecutable.get().asFile.absolutePath)
}
val loveAssets = layout.buildDirectory.dir("love-runtime/assets")
val loveInstaller = rootProject.file("../tools/install_love_runtime.sh")
val installLoveRuntime by tasks.registering(Exec::class) {
    inputs.file(loveInstaller)
    outputs.dir(loveAssets)
    commandLine("bash", loveInstaller.absolutePath, loveAssets.get().asFile.absolutePath)
}
tasks.named("preBuild") {
    dependsOn(installChatmailCore, installLoveRuntime)
}

android {
    namespace = "io.tablecircle.prototype"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Preserve native library extraction from the original APK.
    packaging {
        jniLibs.useLegacyPackaging = true
        jniLibs.keepDebugSymbols.add("**/libchatmail_rpc.so")
    }

    sourceSets["main"].jniLibs.srcDir(chatmailNativeLibraries.get().asFile)
    sourceSets["main"].assets.srcDir(loveAssets.get().asFile)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the original Android ID so existing installs can upgrade in place.
        applicationId = "io.tablecircle.prototype"
        // Chatmail ships for ARM64. Match that ABI when packaging WebRTC.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (System.getenv("ZOMPADO_KEYSTORE") != null) {
            create("distribution") {
                storeFile = file(System.getenv("ZOMPADO_KEYSTORE"))
                storePassword = System.getenv("ZOMPADO_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ZOMPADO_KEY_ALIAS")
                keyPassword = System.getenv("ZOMPADO_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.findByName("distribution") ?: signingConfigs.getByName("debug")
        }
    }
}


flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core:1.13.1")
    implementation("io.github.webrtc-sdk:android:150.7871.01")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
