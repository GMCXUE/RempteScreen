package com.remotescreen.remotescreen

/** Pixel coordinates; the native view and drag policy use the same screen bounds. */
class VideoOverlayPlacement(val width: Int, val height: Int, val handleWidth: Int, val handleHeight: Int) {
    var x = 0
    var y = 0
    var edge = 0
        private set
    val currentWidth get() = if (edge == 0) width else handleWidth
    val currentHeight get() = if (edge == 0) height else handleHeight
    fun move(left: Int, top: Int, screenWidth: Int, screenHeight: Int) {
        x = left.coerceIn(0, (screenWidth - currentWidth).coerceAtLeast(0))
        y = top.coerceIn(0, (screenHeight - currentHeight).coerceAtLeast(0))
    }
    fun finishDrag(screenWidth: Int, screenHeight: Int, threshold: Int) {
        if (edge == 0) edge = when {
            x <= threshold -> -1
            x + width >= screenWidth - threshold -> 1
            else -> 0
        }
        if (edge != 0) x = if (edge < 0) 0 else (screenWidth - handleWidth).coerceAtLeast(0)
        move(x, y, screenWidth, screenHeight)
    }
    fun expand(screenWidth: Int, screenHeight: Int, margin: Int) {
        x = if (edge < 0) margin else screenWidth - width - margin
        edge = 0
        move(x, y, screenWidth, screenHeight)
    }
}
