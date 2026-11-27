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

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("org.jetbrains.kotlin.jvm") version "2.4.0" apply false
}

includeBuild("../../../vendor/YMusicV4") {
    dependencySubstitution {
        substitute(module("io.ymusic:dynamic-engine")).using(project(":dynamic-engine"))
        substitute(module("io.ymusic:quickjs")).using(project(":quickjs"))
        substitute(module("io.ymusic:yt-media")).using(project(":yt-media"))
        substitute(module("io.ymusic:download")).using(project(":download"))
        substitute(module("io.ymusic:player")).using(project(":player"))
        substitute(module("io.ymusic:kmp-http-core")).using(project(":kmpHttp:core"))
        substitute(module("io.ymusic:kmp-http-json")).using(project(":kmpHttp:json"))
        substitute(module("io.ymusic:kmp-common")).using(project(":kmpCommon"))
        substitute(module("io.ymusic:project-common")).using(project(":projectCommon"))
        substitute(module("io.ymusic:settings")).using(project(":settings"))
    }
}

include(":app")
include(":replica-backend")
