// SPDX-License-Identifier: GPL-3.0-or-later
package dev.victorialauncher.ui.applist

/**
 * One source of truth for where the A-Z strip sits, so the letter your finger is on is the
 * letter that lights up. The strip occupies a band — by default the vertical span of the
 * favorites list — rather than the whole screen, so scrubbing never asks for a stretch.
 */
object ScrubberGeometry {

    /** Fallback band (as a fraction of the screen) when the favorites bounds aren't known. */
    const val FALLBACK_TOP_FRACTION = 0.35f
    const val FALLBACK_HEIGHT_FRACTION = 0.5f

    fun indexForY(y: Float, topPx: Float, heightPx: Float, count: Int): Int {
        if (count <= 0 || heightPx <= 0f) return 0
        val idx = ((y - topPx) / (heightPx / count)).toInt()
        return idx.coerceIn(0, count - 1)
    }

    /** True while [y] is within the band, rather than clamped to one of its ends. */
    fun isWithin(y: Float, topPx: Float, heightPx: Float): Boolean =
        heightPx > 0f && y >= topPx && y <= topPx + heightPx

    /**
     * The band the strip should take, given where the favorites are.
     *
     * Normally exactly their span — the strip sits beside what it belongs to. But the favorites
     * are as tall as there are favorites, and one of them is one row: the whole alphabet then
     * has a row's height to divide between its letters, which is a strip with nothing in it
     * anyone could hit or read. Below a minimum it grows around its own middle instead, so it
     * stays where the favorites are without being their size.
     */
    fun bandForFavorites(
        topPx: Float,
        bottomPx: Float,
        viewportPx: Float,
        minHeightPx: Float,
    ): ScrubBand {
        val height = (bottomPx - topPx).coerceAtLeast(0f)
        if (viewportPx <= 0f) return ScrubBand(topPx, height)
        // A measurement taken mid-move can run past the screen, and the letters past its
        // edge could then never be reached. Kept on screen the way a hand-set band is.
        if (height >= minHeightPx) {
            val fitted = height.coerceAtMost(viewportPx)
            return ScrubBand(topPx.coerceIn(0f, viewportPx - fitted), fitted)
        }
        val wanted = minHeightPx.coerceAtMost(viewportPx)
        val center = (topPx + bottomPx) / 2f
        val top = (center - wanted / 2f).coerceIn(0f, viewportPx - wanted)
        return ScrubBand(top, wanted)
    }

    /** Screen-space center of the letter at [index]. */
    fun letterCenterY(index: Int, topPx: Float, heightPx: Float, count: Int): Float {
        if (count <= 0) return topPx
        val spacing = heightPx / count
        return topPx + index * spacing + spacing / 2f
    }
}

/** How far in from the screen's edge the letters rest, and how wide one letter's cell is. */
const val EDGE_INSET_DP = 28f
const val LETTER_WIDTH_DP = 20f

/** Space between the far edge of the peak letter and the bubble that shows it. */
const val BUBBLE_GAP_DP = 8f

/** What the peak travels when the screen's width is not known yet. */
private const val FALLBACK_AMPLITUDE_DP = 112f

/**
 * How far the strip reaches across the screen, measured from the edge it sits on.
 *
 * @property amplitudePx how much further out the letter under a finger travels than one at
 *   rest, which is also the height of the wave the letters are pushed into
 * @property bubbleCenterPx where the bubble showing that letter is centered, or 0 when no
 *   bubble is drawn
 */
data class ScrubReach(val amplitudePx: Float, val bubbleCenterPx: Float)

/**
 * Works out the wave and the bubble from one reading of how wide the list is allowed to be.
 *
 * The setting is a share of the screen, so [widthPercent] of 50 puts the selected letter in the
 * middle of the screen whatever the screen is — a tablet's middle is not a phone's. Half the
 * width is also where the strip has always reached with nothing chosen, so a default install
 * looks the way it did.
 *
 * The bubble needs room beyond the peak, and takes it from the wave: the letters peak short of
 * the mark by half a letter, a gap and half the bubble, which is what puts the bubble's own
 * center exactly on the mark. Below roughly a third of the screen there is not enough room for
 * both, and then the wave keeps half its reach and the bubble slides out past the mark instead
 * of the letters stopping dead under it.
 *
 * [density] is passed rather than read here so this stays a plain calculation.
 */
fun scrubReach(
    widthPercent: Int,
    screenWidthPx: Float,
    /** Half the bubble's width, or 0 when the bubble is hidden. */
    bubbleHalfPx: Float,
    density: Float,
): ScrubReach {
    val restCenterPx = (EDGE_INSET_DP + LETTER_WIDTH_DP / 2f) * density
    val letterHalfPx = LETTER_WIDTH_DP / 2f * density
    val gapPx = BUBBLE_GAP_DP * density
    // Nothing measured yet: the reach the strip has always had, so the first frame is not a
    // frame of something else.
    if (screenWidthPx <= 0f) {
        val amplitudePx = FALLBACK_AMPLITUDE_DP * density
        val peakOuterPx = restCenterPx + amplitudePx + letterHalfPx
        return ScrubReach(
            amplitudePx = amplitudePx,
            bubbleCenterPx = if (bubbleHalfPx <= 0f) 0f else peakOuterPx + gapPx + bubbleHalfPx,
        )
    }
    // How much further out than resting the peak of the wave gets to travel.
    val reachPx = (screenWidthPx * widthPercent.coerceIn(0, 100) / 100f - restCenterPx)
        .coerceAtLeast(0f)
    val amplitudePx = if (bubbleHalfPx <= 0f) {
        reachPx
    } else {
        (reachPx - bubbleHalfPx - gapPx - letterHalfPx).coerceAtLeast(reachPx / 2f)
    }
    val peakOuterPx = restCenterPx + amplitudePx + letterHalfPx
    val bubbleCenterPx = if (bubbleHalfPx <= 0f) {
        0f
    } else {
        val wanted = maxOf(restCenterPx + reachPx, peakOuterPx + gapPx + bubbleHalfPx)
        // A wide setting can put the mark beyond the screen's far edge, and the bubble goes
        // with it rather than half off the screen.
        wanted.coerceAtMost(screenWidthPx - bubbleHalfPx)
    }
    return ScrubReach(amplitudePx, bubbleCenterPx)
}

/** The vertical band the strip is laid out in, in screen pixels. */
data class ScrubBand(val topPx: Float, val heightPx: Float) {
    val bottomPx: Float get() = topPx + heightPx

    companion object {
        fun fallbackFor(viewportHeightPx: Int) = ScrubBand(
            topPx = viewportHeightPx * ScrubberGeometry.FALLBACK_TOP_FRACTION,
            heightPx = viewportHeightPx * ScrubberGeometry.FALLBACK_HEIGHT_FRACTION,
        )
    }
}