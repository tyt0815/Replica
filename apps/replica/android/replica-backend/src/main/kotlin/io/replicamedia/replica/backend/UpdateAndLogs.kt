package io.replicamedia.replica.backend

import kmphttp.KmpHttpClient
import kmphttp.RedirectOptions
import kmphttp.RequestBuilder
import kmphttp.asyncSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okio.Buffer
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class UpdateAndLogs(
    private val httpClient: KmpHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val downloadedBytes = AtomicLong(0L)
    private val totalBytes = AtomicLong(0L)
    private val cancelled = AtomicBoolean(false)

    fun readUpdateProgress(): Pair<Long, Long> = downloadedBytes.get() to totalBytes.get()

    fun cancelUpdateDownload() {
        cancelled.set(true)
    }

    private data class SemVer(val major: Int, val minor: Int, val patch: Int) : Comparable<SemVer> {
        override fun compareTo(other: SemVer): Int =
            compareValuesBy(this, other, SemVer::major, SemVer::minor, SemVer::patch)
        override fun toString(): String = "$major.$minor.$patch"
    }

    private fun parseVersion(raw: String): SemVer? {
        val core = raw.trim().substringBefore('+').trim().removePrefix("v")
        val parts = core.split('.')
        if (parts.size != 3) return null
        val ma = parts[0].toIntOrNull() ?: return null
        val mi = parts[1].toIntOrNull() ?: return null
        val pa = parts[2].toIntOrNull() ?: return null
        return SemVer(ma, mi, pa)
    }

    suspend fun checkLatestRelease(currentVersionRaw: String): JsonObject {
        val current = parseVersion(currentVersionRaw)
            ?: throw IllegalArgumentException("현재 버전 형식이 올바르지 않습니다: $currentVersionRaw")
        val req = RequestBuilder()
            .url(RELEASES_API_URL)
            .get()
            .header("User-Agent", USER_AGENT)
            .header("Accept", "application/vnd.github+json")
            .build()
        val resp = httpClient.execute(req)
        val body = resp.body.string()
        if (resp.code !in 200..299) {
            throw IllegalStateException("GitHub 릴리스 조회 오류 (${resp.code})")
        }
        val releases = json.parseToJsonElement(body).jsonArray

        var bestVer: SemVer? = null
        var bestObj: JsonObject? = null
        var bestName: String? = null
        var bestUrl: String? = null
        var bestSize: Long? = null
        var bestSha: String? = null

        for (el in releases) {
            val obj = el.jsonObject
            if (obj["draft"]?.jsonPrimitive?.booleanOrNull == true) continue
            val tag = obj["tag_name"]?.jsonPrimitive?.content ?: continue
            val ver = parseVersion(tag) ?: continue
            val assets = obj["assets"]?.jsonArray ?: continue
            val apk = assets.firstOrNull { a ->
                val n = a.jsonObject["name"]?.jsonPrimitive?.content ?: ""
                n.startsWith("Replica-") && n.endsWith(".apk")
            }?.jsonObject ?: continue
            val name = apk["name"]?.jsonPrimitive?.content ?: continue
            val url = apk["browser_download_url"]?.jsonPrimitive?.content ?: continue
            if (!url.startsWith(RELEASE_DOWNLOAD_PREFIX)) continue
            val size = apk["size"]?.jsonPrimitive?.longOrNull
            val sha = apk["digest"]?.jsonPrimitive?.content
                ?.trim()?.removePrefix("sha256:")
                ?.lowercase()
                ?.takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }

            if (bestVer == null || ver > bestVer) {
                bestVer = ver
                bestObj = obj
                bestName = name
                bestUrl = url
                bestSize = size
                bestSha = sha
            }
        }

        if (bestVer == null || bestObj == null) {
            return buildJsonObject {
                put("update_available", false)
                put("current_version", current.toString())
                put("latest_version", current.toString())
                put("tag_name", "")
                put("release_notes", "")
            }
        }

        return buildJsonObject {
            put("update_available", bestVer > current)
            put("current_version", current.toString())
            put("latest_version", bestVer.toString())
            put("tag_name", bestObj["tag_name"]?.jsonPrimitive?.content ?: "")
            put("release_notes", bestObj["body"]?.jsonPrimitive?.content?.trim() ?: "")
            bestName?.let { put("asset_name", it) }
            bestUrl?.let { put("asset_url", it) }
            bestSize?.let { put("asset_size", it) }
            bestSha?.let { put("sha256", it) }
        }
    }

    suspend fun downloadUpdateApk(
        assetUrl: String,
        expectedSha256: String?,
        cacheDir: File,
    ): JsonObject {
        if (!assetUrl.startsWith(RELEASE_DOWNLOAD_PREFIX)) {
            throw IllegalArgumentException("허용되지 않은 업데이트 다운로드 주소입니다.")
        }
        val uri = URI(assetUrl)
        val fileName = uri.path.substringAfterLast('/')
        if (!Regex("""Replica-[A-Za-z0-9._-]+\.apk""").matches(fileName)) {
            throw IllegalArgumentException("업데이트 APK 파일 이름이 올바르지 않습니다.")
        }

        val updateDir = File(cacheDir, "update").apply { mkdirs() }
        val finalFile = File(updateDir, fileName)
        val partFile = File(updateDir, "$fileName.part")

        cancelled.set(false)
        downloadedBytes.set(0L)
        totalBytes.set(0L)

        val req = RequestBuilder()
            .url(assetUrl)
            .get()
            .header("User-Agent", USER_AGENT)
            .build()
        val resp = httpClient.execute(req, RedirectOptions(followRedirects = true, followSslRedirects = true))
        if (resp.code !in 200..299) {
            throw IllegalStateException("업데이트 다운로드 오류 (${resp.code})")
        }
        val expectedLen = resp.headers["Content-Length"]?.toLongOrNull() ?: 0L
        totalBytes.set(expectedLen)

        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            val source = resp.body.asyncSource()
            val buf = Buffer()
            FileOutputStream(partFile).use { fos ->
                while (true) {
                    if (cancelled.get()) throw IllegalStateException("업데이트 다운로드가 취소되었습니다.")
                    val read = source.read(buf, 64L * 1024L)
                    if (read <= 0L) break
                    val bytes = buf.readByteArray()
                    total += bytes.size
                    if (total > MAX_APK_BYTES) {
                        throw IllegalStateException("APK 파일 크기가 허용 한도를 초과했습니다.")
                    }
                    digest.update(bytes)
                    fos.write(bytes)
                    downloadedBytes.set(total)
                }
                fos.flush()
            }
            totalBytes.set(total)
            downloadedBytes.set(total)
            if (expectedLen > 0L && total != expectedLen) {
                throw IllegalStateException("업데이트 파일 다운로드가 중단되어 불완전합니다.")
            }
            val actualSha = digest.digest().joinToString("") { "%02x".format(it) }
            val cleanExpected = expectedSha256?.trim()?.removePrefix("sha256:")?.lowercase()
            if (!cleanExpected.isNullOrEmpty() && actualSha != cleanExpected) {
                throw IllegalStateException("다운로드한 APK의 무결성 검증(SHA-256)에 실패했습니다.")
            }
            if (finalFile.exists()) finalFile.delete()
            if (!partFile.renameTo(finalFile)) {
                throw IllegalStateException("APK 파일 이동에 실패했습니다.")
            }
            return buildJsonObject {
                put("path", finalFile.absolutePath)
                put("sha256", actualSha)
                put("bytes", total)
            }
        } catch (t: Throwable) {
            partFile.delete()
            downloadedBytes.set(0L)
            totalBytes.set(0L)
            throw t
        }
    }

    private fun reportsFile(dataDir: File): File = File(dataDir, "error_reports.json")

    fun listErrorReports(dataDir: File): JsonArray {
        val file = reportsFile(dataDir)
        if (!file.isFile) return JsonArray(emptyList())
        return runCatching {
            json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonArray
        }.getOrElse { JsonArray(emptyList()) }
    }

    fun enqueueErrorReport(
        dataDir: File,
        fingerprint: String,
        title: String,
        body: String,
    ): JsonObject {
        dataDir.mkdirs()
        val existing = listErrorReports(dataDir).map { it.jsonObject }.toMutableList()
        if (existing.any { it["fingerprint"]?.jsonPrimitive?.content == fingerprint }) {
            return buildJsonObject {
                put("added", false)
                put("count", existing.size)
            }
        }
        val entry = buildJsonObject {
            put("id", UUID.randomUUID().toString())
            put("fingerprint", fingerprint)
            put("title", title)
            put("body", body)
            put("created_at_ms", System.currentTimeMillis())
        }
        existing.add(0, entry)
        val trimmed = existing.take(100)
        reportsFile(dataDir).writeText(JsonArray(trimmed).toString(), Charsets.UTF_8)
        return buildJsonObject {
            put("added", true)
            put("count", trimmed.size)
        }
    }

    fun clearErrorReports(dataDir: File) {
        reportsFile(dataDir).delete()
    }

    companion object {
        private const val RELEASES_API_URL =
            "https://api.github.com/repos/tyt0815/Replica/releases?per_page=10"
        private const val RELEASE_DOWNLOAD_PREFIX =
            "https://github.com/tyt0815/Replica/releases/download/"
        private const val USER_AGENT = "replica-updater"
        private const val MAX_APK_BYTES = 256L * 1024L * 1024L
    }
}
