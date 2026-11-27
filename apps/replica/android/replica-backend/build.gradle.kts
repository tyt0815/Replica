import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    testImplementation(kotlin("test-junit"))
    api("io.ymusic:dynamic-engine")
    api("io.ymusic:yt-media")
    api("io.ymusic:download")
    api("io.ymusic:kmp-http-core")
    api("io.ymusic:kmp-http-json")
    api("io.ymusic:kmp-common")
    api("io.ymusic:project-common")
    api("io.ymusic:settings")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    implementation("com.squareup.okio:okio:3.10.2")
}
