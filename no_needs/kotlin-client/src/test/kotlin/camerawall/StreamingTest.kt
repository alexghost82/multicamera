package camerawall

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.awt.Canvas
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit
import javax.swing.JFrame
import javax.swing.SwingUtilities
import kotlin.random.Random
import kotlin.test.*

class StreamingTest {
    @Test fun `RTSP through go2rtc is hardware decoded and rendered by GStreamer`() {
        val binary = Go2Rtc.executable()
        assumeTrue(Files.isExecutable(binary) && Files.isExecutable(Path.of("/opt/homebrew/bin/ffmpeg")))
        val sourcePort = Random.nextInt(31000, 39000)
        val source = ProcessBuilder(binary.toString(), "-config", """{"app":{"modules":["rtsp"]},"rtsp":{"listen":"127.0.0.1:$sourcePort"},"streams":{"fixture":[]},"log":{"level":"disabled"}}""")
            .redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start()
        var publisher: Process? = null
        val relay = Go2Rtc(binary, Random.nextInt(50000, 59000), Random.nextInt(41000, 49000))
        val canvas = Canvas()
        var window: JFrame? = null
        var handle = 0L
        try {
            Thread.sleep(400)
            publisher = ProcessBuilder("/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
                "testsrc2=size=640x360:rate=15", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "15", "-bf", "0",
                "-pix_fmt", "yuv420p", "-f", "rtsp", "-rtsp_transport", "tcp", "rtsp://127.0.0.1:$sourcePort/fixture")
                .redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start()
            Thread.sleep(700)
            relay.start()
            val local = relay.register("rtsp://127.0.0.1:$sourcePort/fixture", "test")
            SwingUtilities.invokeAndWait {
                window = JFrame("CameraWall Kotlin RTSP test").apply { add(canvas); setSize(640, 400); isVisible = true }
            }
            handle = NativeVideo.create(canvas, local, false)
            val deadline = System.nanoTime() + 12_000_000_000
            var metrics = VideoMetrics.read(handle)
            while (System.nanoTime() < deadline && metrics.frames < 8 && metrics.error == 0) { Thread.sleep(50); metrics = VideoMetrics.read(handle) }
            assertEquals(0, metrics.error)
            assertTrue(metrics.frames >= 8, "Actual vtdec_hw must decode frames")
            assertTrue(metrics.rendered > 0)
            assertEquals(640, metrics.width)
            assertEquals(360, metrics.height)
            val soakSeconds = System.getenv("CAMERAWALL_SOAK_SECONDS")?.toLongOrNull() ?: 0
            if (soakSeconds > 0) {
                val soakDeadline = System.nanoTime() + soakSeconds * 1_000_000_000
                var previous = metrics.frames
                while (System.nanoTime() < soakDeadline) {
                    Thread.sleep(500)
                    metrics = VideoMetrics.read(handle)
                    assertEquals(0, metrics.error)
                    assertTrue(metrics.frames > previous, "RTSP decode must keep advancing during soak")
                    previous = metrics.frames
                }
                println("GStreamer RTSP soak: $soakSeconds seconds, ${metrics.frames} decoded, ${metrics.rendered} displayed")
            }
        } finally {
            if (handle != 0L) NativeVideo.close(handle)
            SwingUtilities.invokeAndWait { window?.dispose() }
            relay.close()
            publisher?.let { it.destroy(); if (!it.waitFor(3, TimeUnit.SECONDS)) it.destroyForcibly() }
            source.destroy(); if (!source.waitFor(3, TimeUnit.SECONDS)) source.destroyForcibly()
        }
    }
}