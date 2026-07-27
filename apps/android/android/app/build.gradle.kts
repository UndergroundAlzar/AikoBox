import org.gradle.api.GradleException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val libboxAar = layout.projectDirectory.file("libs/libbox.aar")
val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties =
    Properties().apply {
        if (signingPropertiesFile.isFile) {
            signingPropertiesFile.inputStream().use(::load)
        }
    }

android {
    namespace = "com.aikobox.app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aikobox.app"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    signingConfigs {
        if (signingPropertiesFile.isFile) {
            create("release") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes +=
                setOf(
                    "lib/armeabi-v7a/**",
                    "lib/x86/**",
                    "lib/x86_64/**",
                )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files(libboxAar))
    implementation("androidx.core:core-ktx:1.17.0")
    testImplementation("junit:junit:4.13.2")
}

tasks.configureEach {
    if (name == "preBuild") {
        doFirst {
            if (!libboxAar.asFile.isFile) {
                throw GradleException(
                    "Missing apps/android/android/app/libs/libbox.aar. " +
                        "Build sing-box v1.13.14 (commit 25a600d) with " +
                        "`go run ./cmd/internal/build_libbox -target android -platform android/arm64`, " +
                        "then copy libbox.aar to ${libboxAar.asFile}.",
                )
            }
        }
    }
}
