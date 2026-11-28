package io.replicamedia.replica.backend

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PlaylistRulesTest {
    @Test
    fun movesEntriesAfterAnExplicitPredecessorWhenTheHeadChanges() {
        assertEquals(listOf(0 to 2, 1 to 0), PlaylistRules.movesAfter(listOf("a", "b", "c"), listOf("c", "a", "b")))
        assertEquals(listOf(0 to 1), PlaylistRules.movesAfter(listOf("a", "b", "a", "c"), listOf("b", "a", "a", "c")))
        assertEquals(emptyList(), PlaylistRules.movesAfter(listOf("a", "b"), listOf("a", "b")))
    }

    @Test
    fun extractsMembershipIdFromEngineToken() {
        val token = "yplrm1:PL123:membership"
        assertEquals("membership", PlaylistRules.setVideoId(token))
        assertEquals(token, PlaylistRules.removeToken("PL123", "membership"))
        assertEquals(token, PlaylistRules.removeToken("PL123", "PL123:membership"))
        assertNull(PlaylistRules.setVideoId("unknown:PL123:membership"))
    }
}
