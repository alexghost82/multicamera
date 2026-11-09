package camerawall

import org.junit.jupiter.api.Test
import java.awt.BorderLayout
import java.awt.Canvas
import javax.swing.JFrame
import javax.swing.SwingUtilities
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NativeVideoTest {
    @Test fun `GStreamer renders directly into JVM canvas and survives resize`() {
        var window: JFrame? = null
        val canvas = Canvas()
        SwingUtilities.invokeAndWait {
            window = JFrame("CameraWall Kotlin rendering test").apply {
                layout = BorderLayout()
                add(canvas, BorderLayout.CENTER)
                setSize(640, 400)
                isVisible = true
            }
        }
        var handle = 0L
        try {
            handle = NativeVideo.create(canvas, "", true)
            var metrics = awaitFrames(handle, 5)
            assertEquals(640, metrics.width)
            assertEquals(360, metrics.height)
            assertEquals(0, metrics.error)
            assertTrue(metrics.rendered > 0, "GStreamer sink must render, not just receive buffers")
            SwingUtilities.invokeAndWait { window!!.setSize(900, 600); window!!.setLocation(80, 80) }
            metrics = awaitFrames(handle, metrics.frames + 5)
            assertTrue(metrics.live)
            if (System.getenv("CAMERAWALL_VISUAL_TEST") == "1") {
                val capture = java.awt.Robot().createScreenCapture(java.awt.Rectangle(canvas.locationOnScreen, canvas.size))
                val colors = mutableSetOf<Int>()
                for (row in 1..6) for (column in 1..12) {
                    colors.add(capture.getRGB(capture.width * column / 13, capture.height * row / 7))
                }
                assertTrue(colors.size >= 5, "Actual JVM canvas screenshot must show video, not a blank surface; colors=${colors.size}")
                println("Actual JVM video canvas screenshot: ${colors.size} sampled colors")
            }
        } finally {
            if (handle != 0L) NativeVideo.close(handle)
            SwingUtilities.invokeAndWait { window?.dispose() }
        }
    }

    private fun awaitFrames(handle: Long, target: Long): VideoMetrics {
        val deadline = System.nanoTime() + 10_000_000_000
        var metrics = VideoMetrics.read(handle)
        while (System.nanoTime() < deadline && metrics.frames < target && metrics.error == 0) {
            Thread.sleep(40)
            metrics = VideoMetrics.read(handle)
        }
        assertTrue(metrics.frames >= target, "Expected $target frames; received ${metrics.frames}, error ${metrics.error}")
        return metrics
    }
}