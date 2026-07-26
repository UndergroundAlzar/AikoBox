allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// file_picker 11.0.2 assumes that anyone on AGP 9 has AGP's built-in Kotlin support turned
// on, so its android/build.gradle does `if (!isAgp9OrAbove) apply plugin: kotlin-android`.
// This project must keep `android.builtInKotlin=false` (app_links 7.2.1 applies KGP itself
// and hard-fails when built-in Kotlin is also on), so under AGP 9.0.1 nothing at all
// compiles file_picker's .kt sources: `:file_picker:assembleRelease` succeeds while
// producing an AAR that contains only R.class, and `:app:compileReleaseJavaWithJavac` then
// dies on the generated GeneratedPluginRegistrant with
// "cannot find symbol: class FilePickerPlugin".
//
// Applying KGP to that one module restores the pre-AGP-9 behaviour it was written for.
// Scoped by name rather than applied broadly so no other plugin's Kotlin setup is touched.
subprojects {
    if (name == "file_picker") {
        plugins.withId("com.android.library") {
            if (!plugins.hasPlugin("org.jetbrains.kotlin.android")) {
                apply(plugin = "org.jetbrains.kotlin.android")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
