package io.replicamedia.replica

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.ymusic.player.LocalPlayer
import io.ymusic.player.LocalPlayerContext
import io.ymusic.player.PlayableItem
import io.ymusic.player.PlaybackState
import io.ymusic.player.createLocalPlayer
import io.ymusic.player.isEnded
import io.ymusic.player.isPlaying
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

class YMusicPlayerBridge(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var channel: MethodChannel? = null
    private var ymusicPlayer: LocalPlayer? = null
    private var exoPlayer: ExoPlayer? = null
    private var lastPlaying: Boolean? = null
    private var lastState: PlaybackState? = null
    private var lastDurationMs: Long = -1L
    private var pendingLoad: MethodChannel.Result? = null

    fun attach(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, "io.replicamedia.replica/player")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            mainHandler.post {
                try {
                    when (call.method) {
                        "init" -> {
                            ensurePlayer()
                            result.success(true)
                        }
                        "loadFile" -> {
                            val path = call.argument<String>("path").orEmpty()
                            val startMs = (call.argument<Number>("initialPositionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                            ensurePlayer()
                            finishLoad()
                            pendingLoad = result
                            lastDurationMs = -1L
                            val ym = ymusicPlayer
                            if (ym != null) {
                                ym.load(
                                    source = PlayableItem.LocalMedia(uri = path),
                                    startPositionMs = startMs,
                                    playWhenReady = false,
                                )
                            } else {
                                val exo = exoPlayer!!
                                val uri = if (path.startsWith("file://") || path.startsWith("content://")) {
                                    Uri.parse(path)
                                } else {
                                    Uri.fromFile(File(path))
                                }
                                exo.setMediaItem(MediaItem.fromUri(uri), startMs)
                                exo.prepare()
                            }
                        }
                        "play" -> {
                            ensurePlayer()
                            ymusicPlayer?.play() ?: exoPlayer?.play()
                            result.success(true)
                        }
                        "pause" -> {
                            ymusicPlayer?.pause() ?: exoPlayer?.pause()
                            result.success(true)
                        }
                        "seek" -> {
                            val posMs = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                            ymusicPlayer?.seekTo(posMs) ?: exoPlayer?.seekTo(posMs)
                            result.success(true)
                        }
                        "stop" -> {
                            finishLoad()
                            ymusicPlayer?.stop() ?: exoPlayer?.stop()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (t: Throwable) {
                    if (pendingLoad === result) pendingLoad = null
                    result.error("player_error", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun finishLoad(error: String? = null) {
        val result = pendingLoad ?: return
        pendingLoad = null
        if (error == null) result.success(null) else result.error("player_error", error, null)
    }

    private fun ensurePlayer() {
        if (ymusicPlayer != null || exoPlayer != null) return
        val ym = runCatching {
            createLocalPlayer(LocalPlayerContext(context.applicationContext)).also { it.init() }
        }.getOrNull()
        if (ym != null) {
            ymusicPlayer = ym
            scope.launch {
                ym.status.collect { status ->
                    val state = status.state
                    if (state is PlaybackState.Prepared && !state.buffering) finishLoad()
                    if (state is PlaybackState.Error) finishLoad(state.error.message ?: "재생 오류")
                    val isPlaying = state.isPlaying()
                    if (lastPlaying != isPlaying) {
                        lastPlaying = isPlaying
                        channel?.invokeMethod("playing", isPlaying)
                    }
                    if (status.state.isEnded() && lastState?.isEnded() != true) {
                        channel?.invokeMethod("completed", null)
                    }
                    val err = status.state as? PlaybackState.Error
                    if (err != null && lastState !is PlaybackState.Error) {
                        channel?.invokeMethod("error", err.error.message)
                    }
                    lastState = status.state
                }
            }
            scope.launch {
                ym.progress.collect { prog ->
                    channel?.invokeMethod("position", prog.positionMs)
                    if (prog.durationMs > 0L && prog.durationMs != lastDurationMs) {
                        lastDurationMs = prog.durationMs
                        channel?.invokeMethod("duration", prog.durationMs)
                    }
                }
            }
            return
        }

        val attrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val exo = ExoPlayer.Builder(context.applicationContext)
            .setLooper(Looper.getMainLooper())
            .setAudioAttributes(attrs, false)
            .setHandleAudioBecomingNoisy(true)
            .build()
        exo.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (lastPlaying != isPlaying) {
                    lastPlaying = isPlaying
                    channel?.invokeMethod("playing", isPlaying)
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    finishLoad()
                    val dur = exo.duration
                    if (dur > 0L && dur != lastDurationMs) {
                        lastDurationMs = dur
                        channel?.invokeMethod("duration", dur)
                    }
                } else if (playbackState == Player.STATE_ENDED) {
                    channel?.invokeMethod("completed", null)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                finishLoad(error.message ?: "재생 오류")
                channel?.invokeMethod("error", error.message ?: "재생 오류")
            }
        })
        exoPlayer = exo
        scope.launch {
            while (isActive) {
                if (exo.isPlaying) {
                    channel?.invokeMethod("position", exo.currentPosition.coerceAtLeast(0L))
                    val dur = exo.duration
                    if (dur > 0L && dur != lastDurationMs) {
                        lastDurationMs = dur
                        channel?.invokeMethod("duration", dur)
                    }
                }
                delay(200L)
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        mainHandler.post {
            finishLoad()
            ymusicPlayer?.release()
            ymusicPlayer = null
            exoPlayer?.release()
            exoPlayer = null
        }
        scope.cancel()
    }
}
