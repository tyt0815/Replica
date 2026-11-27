package io.replicamedia.replica.backend

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PlaylistRulesTest {
    @Test
    fun extractsMembershipIdFromEngineToken() {
        val token = "yplrm1:PL123:membership"
        assertEquals("membership", PlaylistRules.setVideoId(token))
        assertEquals(token, PlaylistRules.removeToken("PL123", "membership"))
        assertEquals(token, PlaylistRules.removeToken("PL123", "PL123:membership"))
        assertNull(PlaylistRules.setVideoId("unknown:PL123:membership"))
    }
}