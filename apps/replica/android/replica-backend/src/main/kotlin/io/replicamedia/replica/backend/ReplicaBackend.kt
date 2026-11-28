package io.replicamedia.replica.backend

import io.ymusic.download.SabrSpecBuilder
import io.ymusic.dynamicengine.DynamicEngineManager
import io.ymusic.dynamicengine.player.DynamicEnginePlayer
import io.ymusic.dynamicengine.yt.YtFeedItem
import io.ymusic.dynamicengine.yt.YtPlaylistTarget
import io.ymusic.dynamicengine.yt.addToPlaylist
import io.ymusic.dynamicengine.yt.createPlaylist
import io.ymusic.dynamicengine.yt.extractAccountLibrary
import io.ymusic.dynamicengine.yt.extractPlaylistDetail
import io.ymusic.dynamicengine.yt.removeFromPlaylist
import io.ymusic.dynamicengine.yt.search
import io.ymusic.dynamicengine.yt.ytAccountInfo
import io.ymusic.ytmedia.YOUTUBE_USER_AGENT
import io.ymusic.ytmedia.sabr.AdaptiveFormat
import io.ymusic.ytmedia.sabr.DownloadFile
import io.ymusic.ytmedia.sabr.SabrProgress
import io.ymusic.ytmedia.sabr.SabrSession
import io.ymusic.ytmedia.sabr.SabrTrack
import kmphttp.KmpHttpClient
import kmphttp.RequestBuilder
import kmphttp.asyncSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okio.Buffer
import okio.BufferedSink
import okio.appendingSink
import okio.buffer
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

class ReplicaBackend(
    private val httpClient: KmpHttpClient,
    private val cookieProvider: () -> String,
    private val engineManager: DynamicEngineManager,
    private val playerEngineFactory: () -> DynamicEnginePlayer,
    val coreVersion: String = "0.5.1",
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val innertube = InnertubeSupplement(httpClient, cookieProvider)
    private val updateAndLogs = UpdateAndLogs(httpClient)

    private val playerMutex = Mutex()
    private var cachedPlayerEngine: DynamicEnginePlayer? = null
    private var playerInitialized = false

    private val trackProgress = ConcurrentHashMap<String, Pair<Long, Long>>()
    private val activeDownloads = ConcurrentHashMap<String, Job>()

    fun readUpdateDownloadProgress(): Pair<Long, Long> = updateAndLogs.readUpdateProgress()

    fun readTrackDownloadProgress(): Map<String, Pair<Long, Long>> = HashMap(trackProgress)

    fun cancelUpdateDownload() = updateAndLogs.cancelUpdateDownload()

    fun cancelTrackDownload(videoId: String) {
        val key = videoId.trim()
        activeDownloads.remove(key)?.cancel()
        trackProgress.remove(key)
    }

    private suspend fun ensurePlayerEngine(): DynamicEnginePlayer {
        val existing = cachedPlayerEngine
        if (existing != null && playerInitialized) return existing
        val created = existing ?: playerEngineFactory().also { cachedPlayerEngine = it }
        if (!playerInitialized) {
            created.init()
            playerInitialized = true
        }
        return created
    }

    suspend fun fetchThumbnail(url: String, cacheDir: File): String? {
        if (!url.startsWith("https://") && !url.startsWith("http://")) return null
        val thumbsDir = File(cacheDir, "thumbs").apply { mkdirs() }
        val key = MessageDigest.getInstance("SHA-256")
            .digest(url.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val target = File(thumbsDir, "$key.img")
        if (target.isFile && target.length() > 0L) return target.absolutePath

        val part = File(thumbsDir, "$key.part")
        val req = RequestBuilder()
            .url(url)
            .get()
            .header("User-Agent", YOUTUBE_USER_AGENT)
            .build()
        val resp = httpClient.execute(req)
        if (resp.code !in 200..299) return null
        return try {
            val source = resp.body.asyncSource()
            val buf = Buffer()
            FileOutputStream(part).use { fos ->
                while (true) {
                    val read = source.read(buf, 32L * 1024L)
                    if (read <= 0L) break
                    fos.write(buf.readByteArray())
                }
                fos.flush()
            }
            if (target.exists()) target.delete()
            if (part.renameTo(target)) target.absolutePath else null
        } catch (_: Throwable) {
            part.delete()
            null
        }
    }

    suspend fun invoke(requestJson: String): String {
        return try {
            val req = json.parseToJsonElement(requestJson).jsonObject
            val op = req["op"]?.jsonPrimitive?.content
                ?: return errorJson("요청에 op 필드가 없습니다.")
            val data = dispatch(op, req)
            buildJsonObject {
                put("ok", true)
                put("data", data)
            }.toString()
        } catch (ce: CancellationException) {
            throw ce
        } catch (t: Throwable) {
            errorJson(t.message ?: t.javaClass.simpleName)
        }
    }

    private fun errorJson(message: String): String = buildJsonObject {
        put("ok", false)
        put("error", message)
    }.toString()

    private suspend fun dispatch(op: String, req: JsonObject): JsonObject = when (op) {
        "search" -> handleSearch(req)
        "account_profile" -> handleAccountProfile()
        "list_playlists" -> handleListPlaylists()
        "playlist_tracks" -> handlePlaylistTracks(req)
        "create_playlist" -> handleCreatePlaylist(req)
        "rename_playlist" -> handleRenamePlaylist(req)
        "delete_playlist" -> handleDeletePlaylist(req)
        "add_to_playlist" -> handleAddToPlaylist(req)
        "remove_from_playlist" -> handleRemoveFromPlaylist(req)
        "sync_playlist_tracks" -> handleSyncPlaylistTracks(req)
        "record_history_track" -> handleRecordHistoryTrack(req)
        "trim_history_playlist" -> handleTrimHistoryPlaylist(req)
        "download_track" -> handleDownloadTrack(req)
        "list_downloaded" -> handleListDownloaded(req)
        "delete_downloaded" -> handleDeleteDownloaded(req)
        "storage_usage" -> handleStorageUsage(req)
        "check_update" -> handleCheckUpdate(req)
        "download_update" -> handleDownloadUpdate(req)
        "enqueue_error_report" -> handleEnqueueErrorReport(req)
        "list_error_reports" -> handleListErrorReports(req)
        "clear_error_reports" -> handleClearErrorReports(req)
        else -> throw IllegalArgumentException("지원하지 않는 요청입니다: $op")
    }

    private suspend fun handleSearch(req: JsonObject): JsonObject {
        val query = req["query"]?.jsonPrimitive?.content?.trim().orEmpty()
        if (query.isEmpty()) return buildJsonObject { put("tracks", JsonArray(emptyList())) }
        val page = engineManager.search(query = query)
        val items = page.sections.flatMap { it.items }.filter { it.kind == YtFeedItem.KIND_VIDEO }
        val tracks = buildJsonArray {
            for (item in items) {
                add(trackJson(item))
            }
        }
        return buildJsonObject { put("tracks", tracks) }
    }

    private suspend fun handleAccountProfile(): JsonObject {
        val info = engineManager.ytAccountInfo(refresh = true)
        return buildJsonObject {
            put("profile", buildJsonObject {
                put("signed_in", info.signedIn)
                put("name", info.name.orEmpty())
                put("handle", info.handle.orEmpty())
                put("avatar_url", info.thumbs.lastOrNull()?.url.orEmpty())
            })
        }
    }

    private suspend fun handleListPlaylists(): JsonObject {
        val playlists = mutableListOf<JsonObject>()
        val seen = mutableSetOf<String>()
        var continuation: String? = null
        val seenPages = mutableSetOf<String>()
        while (true) {
            val page = engineManager.extractAccountLibrary(continuation = continuation)
            for (section in page.sections) {
                for (item in section.items) {
                    if (item.kind != YtFeedItem.KIND_PLAYLIST) continue
                    val id = item.id.trim()
                    if (id.isEmpty() || !seen.add(id)) continue
                    if (!PlaylistRules.isReplicaPlaylist(item.title)) continue
                    val count = item.itemCount?.filter { it.isDigit() }?.toIntOrNull() ?: 0
                    playlists.add(
                        buildJsonObject {
                            put("id", id)
                            put("remote_title", item.title)
                            put("display_title", PlaylistRules.toDisplayTitle(item.title))
                            put("track_count", count)
                            put("thumbnail", item.thumbs.lastOrNull()?.url.orEmpty())
                        },
                    )
                }
            }
            val next = page.continuation
            if (next.isNullOrBlank()) break
            check(seenPages.add(next)) { "보관함 페이지가 반복되었습니다." }
            continuation = next
        }
        return buildJsonObject { put("playlists", JsonArray(playlists)) }
    }

    private suspend fun fetchAllPlaylistItems(playlistId: String): List<YtFeedItem> {
        val out = mutableListOf<YtFeedItem>()
        var continuation: String? = null
        val seenContinuations = mutableSetOf<String>()
        while (true) {
            val page = engineManager.extractPlaylistDetail(
                url = "/playlist?list=$playlistId",
                continuation = continuation,
            )
            for (section in page.sections) {
                for (item in section.items) {
                    if (item.kind == YtFeedItem.KIND_VIDEO) {
                        out.add(item)
                    }
                }
            }
            val next = page.continuation
            if (next.isNullOrBlank()) break
            check(seenContinuations.add(next)) { "재생목록 페이지가 반복되었습니다." }
            continuation = next
        }
        return out
    }

    private suspend fun handlePlaylistTracks(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        if (playlistId.isEmpty()) throw IllegalArgumentException("playlist_id가 필요합니다.")
        val items = fetchAllPlaylistItems(playlistId)
        val tracks = buildJsonArray {
            for (item in items) {
                add(trackJson(item))
            }
        }
        return buildJsonObject { put("tracks", tracks) }
    }

    private suspend fun handleCreatePlaylist(req: JsonObject): JsonObject {
        val rawTitle = (req["remote_title"] ?: req["title"])?.jsonPrimitive?.content?.trim().orEmpty()
        val remoteTitle = if (PlaylistRules.isReplicaPlaylist(rawTitle)) {
            rawTitle
        } else {
            PlaylistRules.toRemoteTitle(rawTitle) ?: throw IllegalArgumentException("재생목록 이름이 비어 있습니다.")
        }
        val description = req["description"]?.jsonPrimitive?.content
        val videoIds = req["video_ids"]?.jsonArray?.mapNotNull { it.jsonPrimitive.content.takeIf { s -> s.isNotBlank() } }.orEmpty()
        val auth = (req["session"] ?: req["auth"]) as? JsonObject

        val playlistId = if (videoIds.isNotEmpty()) {
            engineManager.createPlaylist(remoteTitle, YtPlaylistTarget.PRIVATE, videoIds)
        } else {
            innertube.createEmptyPlaylist(remoteTitle, description, auth)
        }
        return buildJsonObject {
            put("playlist", buildJsonObject {
                put("id", playlistId)
                put("remote_title", remoteTitle)
                put("display_title", PlaylistRules.toDisplayTitle(remoteTitle))
                put("track_count", videoIds.size)
            })
        }
    }

    private suspend fun handleRenamePlaylist(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val newTitle = (req["new_remote_title"] ?: req["new_title"])?.jsonPrimitive?.content?.trim().orEmpty()
        require(newTitle.isNotBlank())
        val auth = (req["session"] ?: req["auth"]) as? JsonObject
        innertube.renamePlaylist(playlistId, newTitle, auth)
        return buildJsonObject { put("renamed", true) }
    }

    private suspend fun handleDeletePlaylist(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val auth = (req["session"] ?: req["auth"]) as? JsonObject
        innertube.deletePlaylist(playlistId, auth)
        return buildJsonObject { put("deleted", true) }
    }

    private suspend fun handleAddToPlaylist(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val videoId = req["video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        engineManager.addToPlaylist(playlistId, videoId)
        return buildJsonObject { put("added", true) }
    }

    private suspend fun handleRemoveFromPlaylist(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val setVideoId = req["set_video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val videoId = req["video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val token = if (setVideoId.isNotEmpty()) {
            PlaylistRules.removeToken(playlistId, setVideoId)
        } else {
            fetchAllPlaylistItems(playlistId).firstOrNull { it.id == videoId }?.removeToken
                ?: throw IllegalStateException("삭제할 곡의 토큰을 찾지 못했습니다.")
        }
        engineManager.removeFromPlaylist(token)
        return buildJsonObject { put("removed", true) }
    }

    private suspend fun handleSyncPlaylistTracks(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val desiredIds = req["video_ids"]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty()
        val auth = (req["session"] ?: req["auth"]) as? JsonObject

        return syncPlaylistTracks(playlistId, desiredIds, auth, fetchAllPlaylistItems(playlistId), req["new_remote_title"]?.jsonPrimitive?.content)
    }

    private suspend fun syncPlaylistTracks(
        playlistId: String,
        desiredIds: List<String>,
        auth: JsonObject?,
        current: List<YtFeedItem>,
        newTitle: String? = null,
    ): JsonObject {
        val desiredCounts = desiredIds.groupingBy { it }.eachCount().toMutableMap()

        val removeActions = mutableListOf<JsonObject>()
        for (item in current) {
            val left = desiredCounts[item.id] ?: 0
            if (left > 0) {
                desiredCounts[item.id] = left - 1
            } else {
                val setId = requireNotNull(PlaylistRules.setVideoId(item.removeToken))
                removeActions.add(buildJsonObject {
                    put("action", "ACTION_REMOVE_VIDEO")
                    put("setVideoId", setId)
                })
            }
        }
        if (removeActions.isNotEmpty()) {
            innertube.editPlaylistActions(playlistId, JsonArray(removeActions), auth)
        }

        val existingCounts = current.groupingBy { it.id }.eachCount().toMutableMap()
        val addActions = mutableListOf<JsonObject>()
        for (vid in desiredIds) {
            val have = existingCounts[vid] ?: 0
            if (have > 0) {
                existingCounts[vid] = have - 1
            } else {
                addActions.add(buildJsonObject {
                    put("action", "ACTION_ADD_VIDEO")
                    put("addedVideoId", vid)
                })
            }
        }
        if (addActions.isNotEmpty()) {
            innertube.editPlaylistActions(playlistId, JsonArray(addActions), auth)
        }

        var items = if (addActions.isEmpty() && removeActions.isEmpty()) current else fetchAllPlaylistItems(playlistId)
        if (items.map { it.id } != desiredIds) {
            val ordered = items.toMutableList()
            check(ordered.size == desiredIds.size) { "원격 재생목록의 곡 수가 다릅니다." }
            val moves = buildJsonArray {
                for ((index, id) in desiredIds.withIndex()) {
                    if (ordered[index].id == id) continue
                    val source = (index + 1 until ordered.size).first { ordered[it].id == id }
                    val moved = ordered.removeAt(source)
                    ordered.add(index, moved)
                    add(buildJsonObject {
                        put("action", "ACTION_MOVE_VIDEO_AFTER")
                        put("setVideoId", requireNotNull(PlaylistRules.setVideoId(moved.removeToken)))
                        if (index > 0) {
                            put("movedSetVideoIdPredecessor", requireNotNull(PlaylistRules.setVideoId(ordered[index - 1].removeToken)))
                        }
                    })
                }
            }
            for (batch in moves.chunked(50)) {
                innertube.editPlaylistActions(playlistId, JsonArray(batch), auth)
            }
            items = fetchAllPlaylistItems(playlistId)
            check(items.map { it.id } == desiredIds) { "원격 재생목록의 곡 순서를 확인할 수 없습니다." }
        }
        newTitle?.takeIf { it.isNotBlank() }?.let {
            innertube.renamePlaylist(playlistId, it, auth)
        }
        return buildJsonObject {
            put("synced", true)
            put("tracks", JsonArray(items.map { trackJson(it) }))
        }
    }

    private suspend fun handleRecordHistoryTrack(req: JsonObject): JsonObject {
        val playlistId = req["playlist_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val videoId = req["video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        require(playlistId.isNotBlank() && videoId.isNotBlank())
        val items = fetchAllPlaylistItems(playlistId)
        val limit = req["max_tracks"]?.jsonPrimitive?.content?.toIntOrNull() ?: 100
        val desired = (listOf(videoId) + items.map { it.id }.filter { it != videoId }).take(limit)
        return syncPlaylistTracks(playlistId, desired, req["session"] as? JsonObject, items)
    }

    private suspend fun handleTrimHistoryPlaylist(req: JsonObject): JsonObject {
        val playlistId = req.getValue("playlist_id").jsonPrimitive.content
        val limit = req.getValue("max_tracks").jsonPrimitive.content.toInt()
        val items = fetchAllPlaylistItems(playlistId)
        return syncPlaylistTracks(playlistId, items.take(limit).map { it.id }, req["session"] as? JsonObject, items)
    }

    private suspend fun handleDownloadTrack(req: JsonObject): JsonObject {
        val storageDir = File(req["storage_dir"]?.jsonPrimitive?.content?.trim().orEmpty())
        val trackObj = req["track"]?.jsonObject ?: throw IllegalArgumentException("track 정보가 없습니다.")
        val videoId = trackObj["video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val title = trackObj["title"]?.jsonPrimitive?.content?.trim().orEmpty().ifEmpty { videoId }
        val artist = trackObj["artist"]?.jsonPrimitive?.content?.trim().orEmpty()
        val duration = trackObj["duration"]?.jsonPrimitive?.content?.trim().orEmpty()
        val thumbnail = trackObj["thumbnail"]?.jsonPrimitive?.content?.trim().orEmpty()
        val preferredFormat = (req["format"] ?: req["preferred_format"])?.jsonPrimitive?.content?.lowercase() ?: "opus"

        if (videoId.isEmpty()) throw IllegalArgumentException("video_id가 비어 있습니다.")
        storageDir.mkdirs()
        val metaDir = File(storageDir, ".meta").apply { mkdirs() }
        File(storageDir, ".nomedia").apply { if (!exists()) createNewFile() }

        val job = currentCoroutineContext()[Job]
        if (job != null) activeDownloads[videoId] = job
        trackProgress[videoId] = 0L to 0L

        try {
            val resolved = playerMutex.withLock {
                val player = ensurePlayerEngine()
                player.preload(videoId)
                val playerResp = player.cachedPlayerResponse(videoId).toString()
                val poToken = runCatching { player.mintContentPoToken(videoId) }.getOrNull()
                SabrSpecBuilder.resolve(videoId, playerResp, poToken)
            }

            val audioFormats = resolved.spec.formats.filter { it.mimeType.startsWith("audio/") }
            val chosen = selectAudioFormat(audioFormats, preferredFormat)
                ?: throw IllegalStateException("다운로드 가능한 오디오 스트림을 찾지 못했습니다.")

            val ext = if (chosen.mimeType.contains("webm") || chosen.mimeType.contains("opus")) "webm" else "m4a"
            val baseName = PlaylistRules.sanitizeFileName(title, videoId)
            var finalFile = File(storageDir, "$baseName.$ext")
            var suffix = 2
            while (finalFile.exists() && !matchesMetaFile(metaDir, videoId, finalFile)) {
                finalFile = File(storageDir, "$baseName ($suffix).$ext")
                suffix++
            }
            val partFile = File(metaDir, "$videoId.${chosen.itag}.${System.nanoTime()}.$ext.part")

            val downloadFile = LocalDownloadFile(partFile)
            try {
                SabrSession().download(
                    client = httpClient,
                    userAgent = resolved.spec.userAgent ?: YOUTUBE_USER_AGENT,
                    spec = resolved.spec,
                    audio = SabrTrack(chosen, downloadFile),
                    progress = SabrProgress { audioDone, audioLen, _, _ ->
                        trackProgress[videoId] = audioDone to audioLen
                    },
                )
            } finally {
                downloadFile.close()
            }

            if (finalFile.exists()) finalFile.delete()
            if (!partFile.renameTo(finalFile)) {
                partFile.copyTo(finalFile, overwrite = true)
                partFile.delete()
            }

            val metaObj = buildJsonObject {
                put("video_id", videoId)
                put("title", title)
                put("artist", artist.ifEmpty { resolved.artist.orEmpty() })
                put("duration", duration)
                put("thumbnail", thumbnail)
                put("file_path", finalFile.absolutePath)
                put("file_name", finalFile.name)
                put("bytes", finalFile.length())
                put("downloaded_at_ms", System.currentTimeMillis())
            }
            File(metaDir, "$videoId.json").writeText(metaObj.toString(), Charsets.UTF_8)

            return buildJsonObject { put("downloaded", metaObj) }
        } finally {
            activeDownloads.remove(videoId)
            trackProgress.remove(videoId)
        }
    }

    private fun selectAudioFormat(formats: List<AdaptiveFormat>, preferred: String): AdaptiveFormat? {
        if (formats.isEmpty()) return null
        val wantOpus = preferred == "opus"
        val primary = formats.filter {
            val isOpus = it.mimeType.contains("opus") || it.mimeType.contains("webm")
            if (wantOpus) isOpus else !isOpus
        }
        val pool = primary.ifEmpty { formats }
        val nonDrc = pool.filter { !it.isDrc }.ifEmpty { pool }
        return nonDrc.maxByOrNull { it.clen }
    }

    private fun matchesMetaFile(metaDir: File, videoId: String, candidate: File): Boolean {
        val meta = File(metaDir, "$videoId.json")
        if (!meta.isFile) return false
        return runCatching {
            val obj = json.parseToJsonElement(meta.readText(Charsets.UTF_8)).jsonObject
            obj["file_path"]?.jsonPrimitive?.content == candidate.absolutePath
        }.getOrDefault(false)
    }

    private fun handleListDownloaded(req: JsonObject): JsonObject {
        val storageDir = File(req["storage_dir"]?.jsonPrimitive?.content?.trim().orEmpty())
        val metaDir = File(storageDir, ".meta")
        if (!metaDir.isDirectory) return buildJsonObject { put("tracks", JsonArray(emptyList())) }
        val tracks = mutableListOf<JsonObject>()
        metaDir.listFiles { f -> f.isFile && f.name.endsWith(".json") }
            ?.sortedByDescending { it.lastModified() }
            ?.forEach { metaFile ->
                val obj = runCatching { json.parseToJsonElement(metaFile.readText(Charsets.UTF_8)).jsonObject }.getOrNull()
                    ?: return@forEach
                val filePath = obj["file_path"]?.jsonPrimitive?.content.orEmpty()
                if (filePath.isNotEmpty() && File(filePath).isFile) {
                    tracks.add(obj)
                } else {
                    metaFile.delete()
                }
            }
        return buildJsonObject { put("tracks", JsonArray(tracks)) }
    }

    private fun handleDeleteDownloaded(req: JsonObject): JsonObject {
        val storageDir = File(req["storage_dir"]?.jsonPrimitive?.content?.trim().orEmpty())
        val videoId = req["video_id"]?.jsonPrimitive?.content?.trim().orEmpty()
        val metaFile = File(File(storageDir, ".meta"), "$videoId.json")
        if (metaFile.isFile) {
            runCatching {
                val obj = json.parseToJsonElement(metaFile.readText(Charsets.UTF_8)).jsonObject
                val path = obj["file_path"]?.jsonPrimitive?.content.orEmpty()
                if (path.isNotEmpty()) File(path).delete()
            }
            metaFile.delete()
        }
        return buildJsonObject { put("deleted", true) }
    }

    private fun handleStorageUsage(req: JsonObject): JsonObject {
        val storageDir = File(req["storage_dir"]?.jsonPrimitive?.content?.trim().orEmpty())
        var bytes = 0L
        var files = 0
        if (storageDir.isDirectory) {
            storageDir.walkTopDown().forEach { f ->
                if (f.isFile && f.name != ".nomedia") {
                    bytes += f.length()
                    if (!f.parentFile.name.equals(".meta")) files++
                }
            }
        }
        return buildJsonObject {
            put("bytes", bytes)
            put("files", files)
        }
    }

    private suspend fun handleCheckUpdate(req: JsonObject): JsonObject {
        val currentVersion = req["current_version"]?.jsonPrimitive?.content ?: coreVersion
        val result = updateAndLogs.checkLatestRelease(currentVersion)
        return buildJsonObject { put("update", result) }
    }

    private suspend fun handleDownloadUpdate(req: JsonObject): JsonObject {
        val url = req["asset_url"]?.jsonPrimitive?.content.orEmpty()
        val sha = req["sha256"]?.jsonPrimitive?.content
        val cacheDir = File(req["cache_dir"]?.jsonPrimitive?.content.orEmpty())
        val downloaded = updateAndLogs.downloadUpdateApk(url, sha, cacheDir)
        return buildJsonObject { put("downloaded", downloaded) }
    }

    private fun handleEnqueueErrorReport(req: JsonObject): JsonObject {
        val dataDir = File(req["data_dir"]?.jsonPrimitive?.content.orEmpty())
        val fp = req["fingerprint"]?.jsonPrimitive?.content.orEmpty()
        val title = req["title"]?.jsonPrimitive?.content.orEmpty()
        val body = req["body"]?.jsonPrimitive?.content.orEmpty()
        return updateAndLogs.enqueueErrorReport(dataDir, fp, title, body)
    }

    private fun handleListErrorReports(req: JsonObject): JsonObject {
        val dataDir = File(req["data_dir"]?.jsonPrimitive?.content.orEmpty())
        return buildJsonObject { put("reports", updateAndLogs.listErrorReports(dataDir)) }
    }

    private fun handleClearErrorReports(req: JsonObject): JsonObject {
        val dataDir = File(req["data_dir"]?.jsonPrimitive?.content.orEmpty())
        updateAndLogs.clearErrorReports(dataDir)
        return buildJsonObject { put("cleared", true) }
    }

    private fun trackJson(item: YtFeedItem): JsonObject = buildJsonObject {
        put("video_id", item.id)
        put("title", item.title)
        put("artist", item.channelTitle ?: item.subtitleLine1.orEmpty())
        put("duration", item.duration.orEmpty())
        put("thumbnail", item.thumbs.lastOrNull()?.url.orEmpty())
        PlaylistRules.setVideoId(item.removeToken)?.let { put("set_video_id", it) }
    }

    private class LocalDownloadFile(private val file: File) : DownloadFile {
        private var sink: BufferedSink? = null
        override fun length(): Long = if (file.exists()) file.length() else 0L
        override fun appendSink(): BufferedSink {
            sink?.close()
            return file.appendingSink().buffer().also { sink = it }
        }
        override fun close() {
            runCatching { sink?.close() }
            sink = null
        }
    }
}
