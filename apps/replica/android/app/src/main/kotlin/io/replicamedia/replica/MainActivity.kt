package io.replicamedia.replica

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.webkit.WebView
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.reflect.Method
import kotlin.math.roundToInt

class MainActivity : AudioServiceActivity() {
    private var parser: WebView? = null
    private var updatePlugin: AppUpdatePlugin? = null
    private var accountChannel: MethodChannel? = null
    private var volumeChannel: MethodChannel? = null
    private var volumeObserver: ContentObserver? = null
    private var volumeReceiver: BroadcastReceiver? = null
    private var semGetFineVolumeMethod: Method? = null
    private var semSetFineVolumeMethod: Method? = null
    private var lastReportedVolume: Double = -1.0
    private var pendingLoginResult: MethodChannel.Result? = null
    private var notificationPermissionRequested = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val bundle by lazy { assets.open("search.js").bufferedReader().use { it.readText() } }
        MethodChannel(messenger, "replica/search").setMethodCallHandler { call, result ->
            if (call.method != "parse") {
                result.notImplemented()
            } else {
                val runtime = parser ?: WebView(this).also {
                    it.settings.javaScriptEnabled = true
                    it.settings.blockNetworkLoads = true
                    parser = it
                }
                val payload = JSONObject.quote(call.arguments as String)
                runtime.evaluateJavascript(bundle + "\nReplicaSearch.videos(JSON.parse(" + payload + "))") {
                    if (it == null || it == "null") result.error("parse", "검색 결과를 읽을 수 없습니다.", null)
                    else result.success(it)
                }
            }
        }

        updatePlugin = AppUpdatePlugin(applicationContext).also { it.attach(messenger) }
        ensureNotificationPermission()

        accountChannel = MethodChannel(messenger, "com.tyt0815.replicamusic/account").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "session" -> result.success(WebLoginActivity.readSession(applicationContext))
                    "logout" -> {
                        WebLoginActivity.clearSession(applicationContext)
                        result.success(true)
                    }
                    "login" -> {
                        if (pendingLoginResult != null) {
                            result.error("busy", "로그인이 이미 진행 중입니다.", null)
                            return@setMethodCallHandler
                        }
                        pendingLoginResult = result
                        @Suppress("DEPRECATION")
                        startActivityForResult(Intent(this, WebLoginActivity::class.java), REQ_LOGIN)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        initFineVolumeReflection(audioManager)

        volumeChannel = MethodChannel(messenger, "com.tyt0815.replicamusic/volume").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> result.success(readMediaVolumeRatio(audioManager))
                    "set" -> {
                        val vol = (call.argument<Number>("volume")?.toDouble() ?: 0.5)
                            .coerceIn(0.0, 1.0)
                        applyMediaVolumeRatio(audioManager, vol)
                        val updated = readMediaVolumeRatio(audioManager)
                        lastReportedVolume = updated
                        result.success(updated)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        val mainHandler = Handler(Looper.getMainLooper())
        val emitIfChanged = {
            val current = readMediaVolumeRatio(audioManager)
            if (kotlin.math.abs(current - lastReportedVolume) > 0.0005) {
                lastReportedVolume = current
                mainHandler.post {
                    volumeChannel?.invokeMethod("changed", current)
                }
            }
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val streamType = intent?.getIntExtra(
                    "android.media.EXTRA_VOLUME_STREAM_TYPE",
                    AudioManager.STREAM_MUSIC,
                ) ?: AudioManager.STREAM_MUSIC
                if (streamType == AudioManager.STREAM_MUSIC) {
                    emitIfChanged()
                }
            }
        }
        volumeReceiver = receiver
        val filter = IntentFilter().apply {
            addAction("android.media.VOLUME_CHANGED_ACTION")
            addAction("android.media.STREAM_MUTE_CHANGED_ACTION")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }

        val observer = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                super.onChange(selfChange)
                emitIfChanged()
            }
        }
        volumeObserver = observer
        contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            observer,
        )
    }

    private fun initFineVolumeReflection(audioManager: AudioManager) {
        try {
            val clazz = audioManager.javaClass
            semGetFineVolumeMethod = clazz.getMethod("semGetFineVolume", Int::class.javaPrimitiveType)
            semSetFineVolumeMethod = clazz.getMethod(
                "semSetFineVolume",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            )
        } catch (_: Throwable) {
            semGetFineVolumeMethod = null
            semSetFineVolumeMethod = null
        }
    }

    private fun readMediaVolumeRatio(audioManager: AudioManager): Double {
        val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maxVol <= 0) return 0.5
        val getter = semGetFineVolumeMethod
        if (getter != null) {
            try {
                val fine = (getter.invoke(audioManager, AudioManager.STREAM_MUSIC) as? Int) ?: -1
                val maxFine = maxVol * 10
                if (fine in 0..maxFine && maxFine > 0) {
                    return (fine.toDouble() / maxFine.toDouble()).coerceIn(0.0, 1.0)
                }
            } catch (_: Throwable) {}
        }
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return (current.toDouble() / maxVol.toDouble()).coerceIn(0.0, 1.0)
    }

    private fun applyMediaVolumeRatio(audioManager: AudioManager, ratio: Double) {
        val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (maxVol <= 0) return
        val setter = semSetFineVolumeMethod
        if (setter != null) {
            try {
                val maxFine = maxVol * 10
                val targetFine = (ratio * maxFine).roundToInt().coerceIn(0, maxFine)
                setter.invoke(audioManager, AudioManager.STREAM_MUSIC, targetFine, 0)
                return
            } catch (_: Throwable) {}
        }
        val target = (ratio * maxVol).roundToInt().coerceIn(0, maxVol)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_LOGIN) {
            val callback = pendingLoginResult
            pendingLoginResult = null
            if (resultCode == Activity.RESULT_OK) {
                callback?.success(WebLoginActivity.readSession(applicationContext))
            } else {
                callback?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        volumeReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Throwable) {}
        }
        volumeReceiver = null
        volumeObserver?.let { contentResolver.unregisterContentObserver(it) }
        volumeObserver = null
        volumeChannel?.setMethodCallHandler(null)
        volumeChannel = null
        updatePlugin?.detach()
        updatePlugin = null
        accountChannel?.setMethodCallHandler(null)
        accountChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        parser?.destroy()
        super.onDestroy()
    }

    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || notificationPermissionRequested) {
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            return
        }
        notificationPermissionRequested = true
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
    }

    companion object {
        private const val REQ_LOGIN = 4091
        private const val REQ_POST_NOTIFICATIONS = 4092
    }
}
