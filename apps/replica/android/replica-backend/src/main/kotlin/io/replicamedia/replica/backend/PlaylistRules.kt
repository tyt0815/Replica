package io.replicamedia.replica.backend

object PlaylistRules {
    const val SUFFIX = ".rm"
    const val HISTORY_PREFIX = "History."

    private const val REMOVE_TOKEN_PREFIX = "yplrm1"

    fun setVideoId(removeToken: String?): String? {
        val parts = removeToken?.split(':', limit = 3) ?: return null
        if (parts.size != 3 || parts[0] != REMOVE_TOKEN_PREFIX || parts[1].isBlank()) return null
        return parts[2].takeIf { it.isNotBlank() }
    }

    fun removeToken(playlistId: String, setVideoId: String): String {
        val membershipId = setVideoId.removePrefix("$playlistId:")
        return "$REMOVE_TOKEN_PREFIX:$playlistId:$membershipId"
    }

    fun movesAfter(currentIds: List<String>, desiredIds: List<String>): List<Pair<Int, Int>> {
        check(currentIds.size == desiredIds.size) { "원격 음악 재생목록의 곡 수가 다릅니다." }
        val entriesById = currentIds.indices.groupBy { currentIds[it] }.mapValues { ArrayDeque(it.value) }
        val desired = desiredIds.map { id ->
            checkNotNull(entriesById[id]?.removeFirstOrNull()) { "원격 음악 재생목록의 곡 구성이 다릅니다." }
        }
        val order = currentIds.indices.toMutableList()
        return buildList {
            for ((previous, entry) in desired.zipWithNext()) {
                if (order.indexOf(entry) == order.indexOf(previous) + 1) continue
                order.remove(entry)
                order.add(order.indexOf(previous) + 1, entry)
                add(entry to previous)
            }
        }
    }

    fun isReplicaPlaylist(rawTitle: String): Boolean {
        val trimmed = rawTitle.trim()
        return trimmed.endsWith(SUFFIX) && trimmed.length > SUFFIX.length
    }

    fun toDisplayTitle(rawTitle: String): String {
        var core = rawTitle.trim()
        while (core.endsWith(SUFFIX)) {
            core = core.removeSuffix(SUFFIX).trimEnd()
        }
        if (core.startsWith(HISTORY_PREFIX) && core.length > HISTORY_PREFIX.length) {
            return core.removePrefix(HISTORY_PREFIX).trim()
        }
        val dot = core.lastIndexOf('.')
        if (dot > 0) {
            val tail = core.substring(dot + 1)
            if (tail.length in 9..13 && tail.all { it.isDigit() }) {
                return core.substring(0, dot).trimEnd()
            }
        }
        return core
    }

    fun toRemoteTitle(displayTitle: String): String? {
        val clean = toDisplayTitle(displayTitle).trim()
        if (clean.isEmpty()) return null
        return "$clean$SUFFIX"
    }

    fun sanitizeFileName(raw: String, fallback: String): String {
        val cleaned = raw
            .replace(Regex("""[\\/:*?"<>|\r\n\t]+"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()
            .trim('.')
        return cleaned.ifEmpty { fallback }.take(120)
    }
}
