import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.replicamedia.replica"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "io.replicamedia.replica"
        minSdk = 28
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val signingFile = file(System.getenv("REPLICA_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.replica-signing/key.properties")
    signingConfigs.create("distribution") {
        if (signingFile.isFile) {
            val values = Properties().apply { signingFile.inputStream().use { load(it) } }
            storeFile = signingFile.resolveSibling(values.getProperty("storeFile"))
            storePassword = values.getProperty("storePassword")
            keyAlias = values.getProperty("keyAlias")
            keyPassword = values.getProperty("keyPassword")
        } else {
            storeFile = signingFile.resolveSibling("replica.p12")
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("distribution")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(project(":replica-backend"))
    implementation("io.ymusic:dynamic-engine")
    implementation("io.ymusic:player")
    implementation("androidx.media3:media3-exoplayer:1.9.2")
    implementation("io.ymusic:quickjs")
    implementation("io.ymusic:kmp-http-core")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

flutter {
    source = "../.."
}
