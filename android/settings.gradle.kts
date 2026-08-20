pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// CargoKit in pub-cache still uses Project.exec, removed in Gradle 9.
run {
    val patch = file("gradle/cargokit-plugin.gradle")
    if (!patch.isFile) return@run
    val hosted =
        System.getenv("PUB_CACHE")?.let { java.io.File(it, "hosted/pub.dev") }
            ?: System.getenv("LOCALAPPDATA")?.let {
                java.io.File(it, "Pub/Cache/hosted/pub.dev")
            }
            ?: java.io.File(System.getProperty("user.home"), ".pub-cache/hosted/pub.dev")
    if (!hosted.isDirectory) return@run
    hosted.listFiles()?.forEach { pkgDir ->
        val pkgName = pkgDir.name
        if (
            pkgName.startsWith("irondash_engine_context-") ||
            pkgName.startsWith("super_native_extensions-")
        ) {
            val target = java.io.File(pkgDir, "cargokit/gradle/plugin.gradle")
            if (target.isFile) {
                patch.copyTo(target, overwrite = true)
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
