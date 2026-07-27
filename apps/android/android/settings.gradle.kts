pluginManagement {
    val flutterSdkPath =
        providers.gradleProperty("flutter.sdk").orNull
            ?: System.getenv("FLUTTER_ROOT")
            ?: run {
                val properties = java.util.Properties()
                val localProperties = file("local.properties")
                if (localProperties.exists()) {
                    localProperties.inputStream().use(properties::load)
                }
                properties.getProperty("flutter.sdk")
            }

    require(!flutterSdkPath.isNullOrBlank()) {
        "Flutter SDK not found. Set flutter.sdk in apps/android/android/local.properties or set FLUTTER_ROOT."
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

rootProject.name = "aikobox_android"
include(":app")
