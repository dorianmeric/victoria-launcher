// SPDX-License-Identifier: GPL-3.0-or-later
package dev.victorialauncher.ui.applist

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ScrubberGeometryTest {

    @Test
    fun `favorites tall enough keep their own span`() {
        val band = ScrubberGeometry.bandForFavorites(
            topPx = 400f, bottomPx = 1000f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertEquals(400f, band.topPx, 0.01f)
        assertEquals(600f, band.heightPx, 0.01f)
    }

    @Test
    fun `a single favorite still gets a strip worth aiming at`() {
        // One row tall: the whole alphabet had a row's height to share between its letters.
        val band = ScrubberGeometry.bandForFavorites(
            topPx = 900f, bottomPx = 1000f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertEquals(400f, band.heightPx, 0.01f)
        // Grown around its own middle, so it stays where the favorites are.
        assertEquals(950f, band.topPx + band.heightPx / 2f, 0.01f)
    }

    @Test
    fun `growing never pushes the band off either end`() {
        val atTop = ScrubberGeometry.bandForFavorites(
            topPx = 0f, bottomPx = 50f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertEquals(0f, atTop.topPx, 0.01f)

        val atBottom = ScrubberGeometry.bandForFavorites(
            topPx = 1950f, bottomPx = 2000f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertEquals(2000f, atBottom.topPx + atBottom.heightPx, 0.01f)
    }

    @Test
    fun `a minimum taller than the screen is capped by the screen`() {
        val band = ScrubberGeometry.bandForFavorites(
            topPx = 100f, bottomPx = 200f, viewportPx = 600f, minHeightPx = 900f,
        )
        assertEquals(600f, band.heightPx, 0.01f)
        assertEquals(0f, band.topPx, 0.01f)
    }

    @Test
    fun `no favorites measured yet is not grown into nonsense`() {
        val band = ScrubberGeometry.bandForFavorites(
            topPx = 500f, bottomPx = 400f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertTrue(band.heightPx >= 0f)
    }

    @Test
    fun `favorites measured past the screen keep every letter on it`() {
        val band = ScrubberGeometry.bandForFavorites(
            topPx = 800f, bottomPx = 3000f, viewportPx = 2000f, minHeightPx = 400f,
        )
        assertTrue(band.topPx >= 0f)
        assertTrue(band.bottomPx <= 2000f)
    }

    // A phone screen, in px at 2.75 density: 411dp wide.
    private val screenPx = 1130f
    private val density = 2.75f
    private val bubbleHalfPx = 36f * density

    private fun reach(percent: Int) = scrubReach(
        widthPercent = percent,
        screenWidthPx = screenPx,
        bubbleHalfPx = bubbleHalfPx,
        density = density,
    )

    @Test
    fun `half the screen puts the selected letter in the middle`() {
        val half = reach(50)
        assertEquals(screenPx / 2f, half.bubbleCenterPx, 0.5f)
        // The wave peaks short of it, by half a letter, a gap and half the bubble.
        val gapPx = BUBBLE_GAP_DP * density
        val peakOuterPx = (EDGE_INSET_DP + LETTER_WIDTH_DP / 2f) * density + half.amplitudePx +
            LETTER_WIDTH_DP / 2f * density
        assertEquals(half.bubbleCenterPx - bubbleHalfPx - gapPx, peakOuterPx, 0.5f)
    }

    @Test
    fun `the middle of the screen is the middle on any screen`() {
        // A tablet, upright: the setting is a share, not a distance.
        val tablet = scrubReach(50, 1600f * density, bubbleHalfPx, density)
        assertEquals(800f * density, tablet.bubbleCenterPx, 0.5f)
    }

    @Test
    fun `a narrower list reaches less far and bulges less`() {
        val wide = reach(50)
        val narrow = reach(20)
        assertTrue(narrow.bubbleCenterPx < wide.bubbleCenterPx)
        assertTrue(narrow.amplitudePx < wide.amplitudePx)
        // Still closer to the edge than the middle it was at before.
        assertTrue(narrow.bubbleCenterPx < screenPx / 2f)
    }

    @Test
    fun `nothing chosen yet leaves the wave where it always went`() {
        val unknown = scrubReach(50, 0f, bubbleHalfPx, density)
        assertEquals(112f * density, unknown.amplitudePx, 0.5f)
    }

    @Test
    fun `a zero-width list leaves the letters at rest`() {
        val none = scrubReach(0, screenPx, bubbleHalfPx, density)
        assertEquals(0f, none.amplitudePx, 0.01f)
    }

    @Test
    fun `a hidden bubble leaves the whole width to the wave`() {
        val noBubble = scrubReach(50, screenPx, 0f, density)
        val withBubble = scrubReach(50, screenPx, bubbleHalfPx, density)
        assertTrue(noBubble.amplitudePx > withBubble.amplitudePx)
    }

    @Test
    fun `a bubble never sits off the screen`() {
        val full = scrubReach(100, screenPx, bubbleHalfPx, density)
        assertTrue(full.bubbleCenterPx + bubbleHalfPx <= screenPx + 0.01f)
    }
}
