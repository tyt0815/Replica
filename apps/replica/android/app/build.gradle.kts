plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.replicamedia.replica"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.replicamedia.replica"
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

val searchAssets = layout.buildDirectory.dir("generated/ymusic/assets")
val bundleSearch by tasks.registering(Exec::class) {
    val appRoot = rootDir.parentFile
    inputs.file(appRoot.resolve("engine/search.ts"))
    inputs.dir(appRoot.resolve("../../vendor/YMusicV4/engine-js/src"))
    outputs.dir(searchAssets)
    workingDir(appRoot)
    val args = listOf("npx", "--yes", "esbuild@0.25.12", "engine/search.ts", "--bundle",
        "--global-name=ReplicaSearch", "--define:versions.app=1",
        "--outfile=" + searchAssets.get().file("search.js").asFile.absolutePath)
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) listOf("cmd", "/c") + args else args)
}
android.sourceSets["main"].assets.srcDir(searchAssets.get().asFile)
tasks.named("preBuild").configure { dependsOn(bundleSearch) }
