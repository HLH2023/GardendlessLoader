package io.github.dey410.gardendlessloader.game

import org.junit.Assert.assertEquals
import org.junit.Test

class GameViewportSizeTest {
    @Test
    fun `balanced follows the window exactly on 4 by 3 and 16 by 9`() {
        assertEquals(1600 to 1200, GameViewportSize.fit(1600, 1200, GameScreenFit.BALANCED))
        assertEquals(1400 to 1000, GameViewportSize.fit(1400, 1000, GameScreenFit.BALANCED))
        assertEquals(1600 to 1000, GameViewportSize.fit(1600, 1000, GameScreenFit.BALANCED))
        assertEquals(1920 to 1080, GameViewportSize.fit(1920, 1080, GameScreenFit.BALANCED))
    }

    @Test
    fun `balanced does not crop or letterbox 21 by 9 phones`() {
        assertEquals(2400 to 1080, GameViewportSize.fit(2400, 1080, GameScreenFit.BALANCED))
        assertEquals(2100 to 900, GameViewportSize.fit(2100, 900, GameScreenFit.BALANCED))
        assertEquals(2340 to 1080, GameViewportSize.fit(2340, 1080, GameScreenFit.BALANCED))
    }

    @Test
    fun `show all keeps the whole 17 by 9 picture`() {
        assertEquals(1700 to 900, GameViewportSize.fit(1700, 900, GameScreenFit.SHOW_ALL))
        assertEquals(1920 to 1016, GameViewportSize.fit(1920, 1080, GameScreenFit.SHOW_ALL))
        assertEquals(1600 to 847, GameViewportSize.fit(1600, 1200, GameScreenFit.SHOW_ALL))
        assertEquals(2040 to 1080, GameViewportSize.fit(2400, 1080, GameScreenFit.SHOW_ALL))
    }

    @Test
    fun `invalid dimensions produce an empty viewport`() {
        assertEquals(0 to 0, GameViewportSize.fit(0, 1080, GameScreenFit.BALANCED))
        assertEquals(0 to 0, GameViewportSize.fit(1920, 0, GameScreenFit.BALANCED))
    }
}
