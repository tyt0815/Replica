package io.replicamedia.replica.backend

object PlaylistRules {
    const val SUFFIX = ".rm"
    const val HISTORY_PREFIX = "History."

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
