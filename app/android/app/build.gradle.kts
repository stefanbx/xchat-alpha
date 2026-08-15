import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key. Android will only install an update over an app signed by the SAME key,
// so this one is load-bearing for the whole self-update story: lose it and no existing install can
// ever be updated in place again. It therefore lives OUTSIDE the repo (key.properties is ignored by
// git and points at ~/.xchat), and a checkout without it still builds — it just falls back to the
// debug key, which is fine for `flutter run` and useless for publishing.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile")?.let { file(it).exists() } == true

android {
    namespace = "xno.xchat.xchat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true   // required by flutter_local_notifications
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "xno.xchat.xchat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
            // NOTE: a universal APK carries the native libs (libflutter.so + libapp.so) once PER ABI, so
            // the default build ships arm64-v8a + armeabi-v7a + x86_64. `ndk.abiFilters` here is IGNORED by
            // `flutter build apk` (Flutter injects -Ptarget-platform=all), so the distributed release MUST
            // be built with an explicit target-platform. As of 2.3.8 we ship arm64-v8a ONLY:
            //   flutter build apk --release --target-platform android-arm64
            // ~26.9 MB (all ABIs) -> ~11 MB. arm64 is every phone shipped since ~2019 (Play has required
            // 64-bit since Aug 2019); this drops x86_64 (emulator-only) AND armeabi-v7a (pre-2019 32-bit
            // phones). To keep old 32-bit devices, use `--target-platform android-arm64,android-arm`.
        }
    }

    // Compress native libraries in the APK (extractNativeLibs=true) so the download matches the prior
    // releases (~21 MB) instead of ballooning to ~55 MB with uncompressed .so — a smaller self-update.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
