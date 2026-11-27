package io.replicamedia.replica.backend

import kmphttp.KmpHttpClient
import kmphttp.MediaTypeX.toMediaTypeOrNull
import kmphttp.RequestBody
import kmphttp.RequestBuilder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.security.MessageDigest

class InnertubeSupplement(
    private val httpClient: KmpHttpClient,
    private val cookieProvider: () -> String,
) {
    private val json = Json { ignoreUnknownKeys = true }

    private fun extractCookie(cookieHeader: String, name: String): String? {
        return cookieHeader.split(';')
            .map { it.trim() }
            .firstOrNull { it.startsWith("$name=") }
            ?.substringAfter('=')
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    private fun buildSapisidHash(cookieHeader: String): String? {
        val sapisid = extractCookie(cookieHeader, "SAPISID")
            ?: extractCookie(cookieHeader, "__Secure-3PAPISID")
            ?: return null
        val ts = System.currentTimeMillis() / 1000L
        val payload = "$ts $sapisid https://www.youtube.com"
        val digest = MessageDigest.getInstance("SHA-1")
            .digest(payload.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "SAPISIDHASH ${ts}_$digest"
    }

    private suspend fun postInnertube(
        endpoint: String,
        bodyFields: Map<String, kotlinx.serialization.json.JsonElement>,
        auth: JsonObject?,
    ): JsonObject {
        val cookieHeader = auth?.get("cookie")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            ?: cookieProvider()
        val clientVersion = auth?.get("client_version")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
            ?: "2.20250201.00.00"
        val visitorData = auth?.get("visitor_data")?.jsonPrimitive?.content?.takeIf { it.isNotBlank() }
        val authUser = auth?.get("auth_user")?.jsonPrimitive?.content?.toIntOrNull() ?: 0
        val delegated = auth?.get("delegated_session_id")?.jsonPrimitive?.content
            ?.takeIf { it.isNotBlank() && it != "null" }

        val payload = buildJsonObject {
            put("context", buildJsonObject {
                put("client", buildJsonObject {
                    put("clientName", "WEB")
                    put("clientVersion", clientVersion)
                    put("hl", "ko")
                    put("gl", "KR")
                    if (visitorData != null) put("visitorData", visitorData)
                })
                if (delegated != null) {
                    put("user", buildJsonObject { put("onBehalfOfUser", delegated) })
                }
            })
            for ((k, v) in bodyFields) {
                put(k, v)
            }
        }

        val reqBuilder = RequestBuilder()
            .url("https://www.youtube.com/youtubei/v1/$endpoint?prettyPrint=false")
            .post(RequestBody.create("application/json; charset=utf-8".toMediaTypeOrNull(), payload.toString()))
            .header("Origin", "https://www.youtube.com")
            .header("Referer", "https://www.youtube.com/")
            .header("X-Origin", "https://www.youtube.com")
            .header("X-Youtube-Client-Name", "1")
            .header("X-Youtube-Client-Version", clientVersion)
            .header("X-Goog-AuthUser", authUser.toString())
            .header("User-Agent", DESKTOP_UA)
        if (cookieHeader.isNotBlank()) {
            reqBuilder.header("Cookie", cookieHeader)
            buildSapisidHash(cookieHeader)?.let { reqBuilder.header("Authorization", it) }
        }
        if (visitorData != null) {
            reqBuilder.header("X-Goog-Visitor-Id", visitorData)
        }
        if (delegated != null) {
            reqBuilder.header("X-Goog-PageId", delegated)
        }

        val response = httpClient.execute(reqBuilder.build())
        val text = response.body.string()
        if (response.code !in 200..299) {
            throw IllegalStateException("YouTube API 오류 (${response.code})")
        }
        return json.parseToJsonElement(text).jsonObject
    }

    suspend fun createEmptyPlaylist(
        title: String,
        description: String?,
        auth: JsonObject?,
    ): String {
        val fields = mutableMapOf<String, kotlinx.serialization.json.JsonElement>(
            "title" to JsonPrimitive(title),
            "privacyStatus" to JsonPrimitive("PRIVATE"),
        )
        if (!description.isNullOrBlank()) {
            fields["description"] = JsonPrimitive(description)
        }
        val root = postInnertube("playlist/create", fields, auth)
        return root["playlistId"]?.jsonPrimitive?.content
            ?: throw IllegalStateException("생성된 재생목록 ID를 받지 못했습니다.")
    }

    suspend fun renamePlaylist(
        playlistId: String,
        newTitle: String,
        auth: JsonObject?,
    ) {
        val actions = buildJsonArray {
            add(buildJsonObject {
                put("action", "ACTION_SET_PLAYLIST_NAME")
                put("playlistName", newTitle)
            })
        }
        postInnertube(
            "browse/edit_playlist",
            mapOf("playlistId" to JsonPrimitive(playlistId), "actions" to actions),
            auth,
        )
    }

    suspend fun deletePlaylist(playlistId: String, auth: JsonObject?) {
        postInnertube(
            "playlist/delete",
            mapOf("playlistId" to JsonPrimitive(playlistId)),
            auth,
        )
    }

    suspend fun editPlaylistActions(
        playlistId: String,
        actions: JsonArray,
        auth: JsonObject?,
    ) {
        if (actions.isEmpty()) return
        postInnertube(
            "browse/edit_playlist",
            mapOf("playlistId" to JsonPrimitive(playlistId), "actions" to actions),
            auth,
        )
    }

    companion object {
        const val DESKTOP_UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    }
}
