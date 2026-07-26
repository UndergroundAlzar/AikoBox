// Must be imported: inside a Kotlin build script `java` resolves to Gradle's own `java`
// extension, which shadows the java.* package root.
import java.util.Properties

plugins {
    id("com.android.application")
    // Kotlin comes from Flutter's built-in Kotlin support; applying KGP explicitly is
    // deprecated as of Flutter 3.44 and fails the build in a future release.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties =
    Properties().apply {
        if (hasReleaseKeystore) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }

android {
    namespace = "com.aikobox.app"
    compileSdk = 36
    // Pinned rather than flutter.ndkVersion: libbox.aar is built against r28 and the
    // 16 KB page alignment it produces is required on Android 15+ devices.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aikobox.app"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // arm64-v8a only, by product decision. libbox.aar ships no other ABI, so any
        // other filter would produce an APK that installs and then crashes on first use.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        // Release signing is supplied by CI from secrets. When key.properties is absent
        // (every local build, and CI on a fork) the release build falls back to the debug
        // key so `flutter build apk --release` still works — the artifact is then clearly
        // marked unsigned in the release notes, exactly as the desktop beta is.
        if (hasReleaseKeystore) {
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
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            // libbox.so is a 60 MB Go binary. Leaving it uncompressed lets the loader mmap
            // it straight from the APK instead of extracting a second copy to /data.
            useLegacyPackaging = false

            // defaultConfig.ndk.abiFilters covers what the NDK builds and what Flutter
            // contributes, but under AGP 9 it does NOT filter .so files that arrive
            // prebuilt inside an AAR — jni's libdartjni.so and androidx.datastore's
            // libdatastore_shared_counter.so were both landing in the APK for all three
            // ABIs. This app is arm64-only by product decision (libbox.aar ships no other
            // ABI), so anything under another ABI directory is dead weight that also makes
            // the APK look multi-ABI to the Play Store.
            excludes += setOf(
                "**/armeabi/**",
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
                "**/mips/**",
                "**/mips64/**",
                "**/riscv64/**",
            )
        }
    }

    lint {
        // The build must not be gated on lint warnings from generated Flutter sources.
        checkReleaseBuilds = false
    }
}

flutter {
    source = "../.."
}

dependencies {
    // libbox.aar is NOT committed (see .gitignore). It is produced by
    // .github/workflows/android-libbox.yml from SagerNet/sing-box v1.13.14 and verified
    // against scripts/resources-lock.android.json before Gradle ever sees it, mirroring
    // the desktop resources-lock discipline.
    implementation(files("libs/libbox.aar"))

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
