package com.remotescreen.remotescreen
import org.junit.Assert.*
import org.junit.Test

class VideoOverlayPlacementTest {
    @Test fun bothEdgesDockAndRestoreWithoutChangingTheVideoSize() {
        val p = VideoOverlayPlacement(120, 160, 28, 64)
        p.move(270, 100, 390, 844); p.finishDrag(390, 844, 24)
        assertEquals(1, p.edge); assertEquals(362, p.x); assertEquals(28, p.currentWidth)
        p.expand(390, 844, 16)
        assertEquals(0, p.edge); assertEquals(254, p.x); assertEquals(160, p.currentHeight)
        p.move(-400, 2000, 390, 844); p.finishDrag(390, 844, 24)
        assertEquals(-1, p.edge); assertEquals(0, p.x); assertTrue(p.y + p.currentHeight <= 844)
        p.expand(390, 390, 16)
        assertEquals(16, p.x); assertTrue(p.y + p.height <= 390)
    }
    @Test fun interiorDragKeepsVideoOpen() {
        val p = VideoOverlayPlacement(120, 160, 28, 64)
        p.move(130, 90, 390, 844); p.finishDrag(390, 844, 24)
        assertEquals(0, p.edge); assertEquals(120, p.currentWidth)
    }
}
