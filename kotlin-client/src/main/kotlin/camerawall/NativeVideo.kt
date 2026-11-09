package camerawall

import java.awt.Canvas

object NativeVideo {
    init {
        val bundled = System.getProperty("compose.application.resources.dir")?.let { java.nio.file.Path.of(it, "libcamerawallgst.dylib") }
        if (bundled != null && java.nio.file.Files.exists(bundled)) System.load(bundled.toAbsolutePath().toString())
        else System.loadLibrary("camerawallgst")
    }
    external fun create(canvas: Canvas?, address: String, test: Boolean): Long
    external fun metrics(handle: Long): LongArray
    external fun close(handle: Long)
    external fun blank(handle: Long)
    external fun writeSecret(account: String, value: String): Int
    external fun readSecret(account: String): String?
}

data class VideoMetrics(val frames: Long, val width: Int, val height: Int, val ageMs: Long, val error: Int, val rendered: Long) {
    val live get() = frames > 0 && ageMs in 0..1000 && error == 0
    companion object {
        fun read(handle: Long): VideoMetrics {
            val values = NativeVideo.metrics(handle)
            return VideoMetrics(values[0], values[1].toInt(), values[2].toInt(), values[3], values[4].toInt(), values[5])
        }
    }
}