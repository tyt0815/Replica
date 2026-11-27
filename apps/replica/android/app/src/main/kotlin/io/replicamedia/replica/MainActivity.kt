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
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.replicamedia.replica.backend.ReplicaBackend
import io.ymusic.dynamicengine.DynamicEngineManager
import io.ymusic.dynamicengine.androidEngineCacheStore
import io.ymusic.dynamicengine.embeddedEngineJsSource
import io.ymusic.dynamicengine.player.DynamicEnginePlayer
import io.ymusic.dynamicengine.yt.ytRefreshSession
import kmphttp.KmpHttpClient
import kmphttp.create
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.lang.reflect.Method
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlin.time.Duration.Companion.seconds

class MainActivity : AudioServiceActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val backendScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val playerJsExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "replica-player-js").apply { isDaemon = true }
    }

    private var backendChannel: MethodChannel? = null
    private var playerBridge: YMusicPlayerBridge? = null
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

    private lateinit var cookieJar: WebViewCookieJar
    private lateinit var engineManager: DynamicEngineManager
    private lateinit var backend: ReplicaBackend

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        cookieJar = WebViewCookieJar()
        val httpClient = KmpHttpClient.create {
            cookieJar = this@MainActivity.cookieJar
            defaultExecuteTimeout = 30.seconds
        }
        val cacheStore = androidEngineCacheStore(applicationContext)
        engineManager = DynamicEngineManager(
            client = httpClient,
            appVersion = BuildConfig.VERSION_CODE,
            jsSource = embeddedEngineJsSource(),
            cacheStore = cacheStore,
            cookieJar = cookieJar,
        )
        backendScope.launch {
            runCatching { engineManager.start() }
        }
        backend = ReplicaBackend(
            httpClient = httpClient,
            cookieProvider = { cookieJar.youtubeCookieHeader() },
            engineManager = engineManager,
            playerEngineFactory = {
                DynamicEnginePlayer.create(
                    client = httpClient,
                    appVersion = BuildConfig.VERSION_CODE,
                    dispatcher = playerJsExecutor.asCoroutineDispatcher(),
                    cacheStore = cacheStore,
                    cookieJar = cookieJar,
                    videoSurface = null,
                    main = engineManager,
                )
            },
            coreVersion = BuildConfig.VERSION_NAME,
        )

        backendChannel = MethodChannel(messenger, "io.replicamedia.replica/backend").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "invoke" -> {
                        val requestJson = call.argument<String>("request").orEmpty()
                        backendScope.launch {
                            val responseJson = backend.invoke(requestJson)
                            mainHandler.post { result.success(responseJson) }
                        }
                    }
                    "updateProgress" -> {
                        val (done, total) = backend.readUpdateDownloadProgress()
                        result.success(mapOf("downloaded_bytes" to done, "total_bytes" to total))
                    }
                    "trackProgress" -> {
                        val map = backend.readTrackDownloadProgress().mapValues { (_, pair) ->
                            mapOf("downloaded_bytes" to pair.first, "total_bytes" to pair.second)
                        }
                        result.success(map)
                    }
                    "cancelUpdate" -> {
                        backend.cancelUpdateDownload()
                        result.success(true)
                    }
                    "cancelTrack" -> {
                        val videoId = call.argument<String>("video_id").orEmpty()
                        backend.cancelTrackDownload(videoId)
                        result.success(true)
                    }
                    "fetchThumbnail" -> {
                        val url = call.argument<String>("url").orEmpty()
                        val cacheDir = call.argument<String>("cache_dir")
                            ?.takeIf { it.isNotBlank() }
                            ?.let(::File)
                            ?: applicationContext.cacheDir
                        backendScope.launch {
                            val path = runCatching { backend.fetchThumbnail(url, cacheDir) }.getOrNull()
                            mainHandler.post { result.success(path) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        playerBridge = YMusicPlayerBridge(applicationContext).also { it.attach(messenger) }
        updatePlugin = AppUpdatePlugin(applicationContext).also { it.attach(messenger) }
        ensureNotificationPermission()

        accountChannel = MethodChannel(messenger, "com.tyt0815.replicamusic/account").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "session" -> result.success(WebLoginActivity.readSession(applicationContext))
                    "logout" -> {
                        WebLoginActivity.clearSession(applicationContext)
                        backendScope.launch { runCatching { engineManager.ytRefreshSession() } }
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
                backendScope.launch { runCatching { engineManager.ytRefreshSession() } }
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
        backendChannel?.setMethodCallHandler(null)
        backendChannel = null
        playerBridge?.detach()
        playerBridge = null
        updatePlugin?.detach()
        updatePlugin = null
        accountChannel?.setMethodCallHandler(null)
        accountChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        backendScope.cancel()
        playerJsExecutor.shutdown()
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
