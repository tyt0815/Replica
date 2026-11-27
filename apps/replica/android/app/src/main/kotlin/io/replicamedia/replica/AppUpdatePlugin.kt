package io.replicamedia.replica

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal object AppUpdatePaths {
    private val apkNamePattern = Regex("""Replica-[A-Za-z0-9._-]+\.apk""")
    private val logNamePattern = Regex("""[A-Za-z0-9._-]+\.(txt|log)""")

    fun isAllowedApk(cacheDir: File, target: File): Boolean {
        return try {
            val allowedDir = File(cacheDir, "update").canonicalFile
            val canonicalTarget = target.canonicalFile
            canonicalTarget.parentFile == allowedDir &&
                apkNamePattern.matches(canonicalTarget.name) &&
                canonicalTarget.isFile
        } catch (_: Exception) {
            false
        }
    }

    fun isAllowedLogFile(cacheDir: File, target: File): Boolean {
        return try {
            val allowedDir = File(cacheDir, "logs").canonicalFile
            val canonicalTarget = target.canonicalFile
            canonicalTarget.parentFile == allowedDir &&
                logNamePattern.matches(canonicalTarget.name) &&
                canonicalTarget.isFile
        } catch (_: Exception) {
            false
        }
    }
}

class AppUpdatePlugin(private val context: Context) {
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "com.tyt0815.replicamusic/update").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> {
                        val publicMusicDir = File(
                            Environment.getExternalStorageDirectory(),
                            "ReplicaMusic",
                        )
                        result.success(
                            mapOf(
                                "version" to BuildConfig.VERSION_NAME,
                                "version_code" to BuildConfig.VERSION_CODE,
                                "cache_dir" to context.cacheDir.absolutePath,
                                "data_dir" to context.filesDir.absolutePath,
                                "storage_dir" to publicMusicDir.absolutePath,
                                "device_name" to readDeviceName(),
                            ),
                        )
                    }
                    "has_storage_permission" -> {
                        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            Environment.isExternalStorageManager()
                        } else {
                            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                                PackageManager.PERMISSION_GRANTED
                        }
                        result.success(granted)
                    }
                    "open_storage_permission_settings" -> {
                        try {
                            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    Uri.parse("package:${context.packageName}"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            } else {
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:${context.packageName}"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            context.startActivity(intent)
                            result.success(true)
                        } catch (_: RuntimeException) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                try {
                                    context.startActivity(
                                        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                    )
                                    result.success(true)
                                } catch (_: RuntimeException) {
                                    result.error(
                                        "settings_unavailable",
                                        "저장소 권한 설정 화면을 열지 못했습니다.",
                                        null,
                                    )
                                }
                            } else {
                                result.error(
                                    "settings_unavailable",
                                    "저장소 권한 설정 화면을 열지 못했습니다.",
                                    null,
                                )
                            }
                        }
                    }
                    "can_install_packages" -> {
                        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            context.packageManager.canRequestPackageInstalls()
                        result.success(allowed)
                    }
                    "open_install_permission_settings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${context.packageName}"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                context.startActivity(intent)
                                result.success(true)
                            } catch (_: RuntimeException) {
                                result.error("settings_unavailable", "설치 권한 설정 화면을 열지 못했습니다.", null)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "install_apk" -> {
                        val rawPath = call.argument<String>("path")
                        if (rawPath.isNullOrBlank()) {
                            result.error("invalid_path", "설치할 APK 경로가 없습니다.", null)
                            return@setMethodCallHandler
                        }
                        val file = File(rawPath)
                        if (!AppUpdatePaths.isAllowedApk(context.cacheDir, file)) {
                            result.error("invalid_apk", "허용된 업데이트 APK 파일이 아닙니다.", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !context.packageManager.canRequestPackageInstalls()
                        ) {
                            result.error("install_permission_required", "알 수 없는 앱 설치 권한이 필요합니다.", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.update_provider",
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            context.startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("install_failed", "패키지 설치 화면을 열지 못했습니다.", null)
                        }
                    }
                    "share_file" -> {
                        val rawPath = call.argument<String>("path")?.trim() ?: ""
                        if (rawPath.isEmpty()) {
                            result.error("invalid_path", "공유할 파일 경로가 없습니다.", null)
                            return@setMethodCallHandler
                        }
                        val file = File(rawPath)
                        if (!AppUpdatePaths.isAllowedLogFile(context.cacheDir, file)) {
                            result.error("invalid_log", "허용된 로그 파일이 아닙니다.", null)
                            return@setMethodCallHandler
                        }
                        val subject = call.argument<String>("subject")?.trim()
                        val text = call.argument<String>("text")
                        try {
                            val uri = FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.update_provider",
                                file,
                            )
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_STREAM, uri)
                                if (!subject.isNullOrEmpty()) {
                                    putExtra(Intent.EXTRA_SUBJECT, subject)
                                }
                                if (!text.isNullOrEmpty()) {
                                    putExtra(Intent.EXTRA_TEXT, text)
                                }
                                clipData = ClipData.newRawUri(file.name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            val chooser = Intent.createChooser(sendIntent, "오류 로그 공유").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            context.startActivity(chooser)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("share_failed", "로그 공유 시트를 열지 못했습니다.", null)
                        }
                    }
                    "open_url" -> {
                        val rawUrl = call.argument<String>("url")?.trim() ?: ""
                        if (!rawUrl.startsWith("https://")) {
                            result.error("invalid_url", "지원하지 않는 URL입니다.", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(rawUrl))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("open_url_failed", "브라우저를 열지 못했습니다.", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun readDeviceName(): String {
        val candidates = listOf(
            runCatching {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            }.getOrNull(),
            runCatching {
                Settings.System.getString(context.contentResolver, "device_name")
            }.getOrNull(),
            Build.MODEL,
        )
        for (raw in candidates) {
            val cleaned = raw?.trim().orEmpty()
            if (cleaned.isNotEmpty()) {
                return cleaned
            }
        }
        return "Android"
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
