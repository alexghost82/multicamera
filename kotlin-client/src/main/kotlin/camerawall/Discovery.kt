package camerawall

import java.net.URI
import java.util.UUID

data class DetectedProfile(val source: String, val width: Int, val height: Int) {
    val pixels get() = width.toLong() * height
}

class Discovery(private val relay: Go2Rtc) {
    fun detect(ip: String, credentials: Credentials, progress: (String) -> Unit): Camera {
        val host = parseHost(ip)
        relay.start()
        progress("Discovering ONVIF profiles")
        val profiles = relay.profiles(host, credentials).distinct().mapNotNull { source ->
            progress("Checking camera video profiles")
            probe(source, credentials)
        }
        if (profiles.isNotEmpty()) return select(host.host, profiles)
        val paths = listOf(
            "/Streaming/Channels/102" to "/Streaming/Channels/101",
            "/cam/realmonitor?channel=1&subtype=1" to "/cam/realmonitor?channel=1&subtype=0",
            "/h264Preview_01_sub" to "/h264Preview_01_main",
            "/live/ch00_1" to "/live/ch00_0",
            "/axis-media/media.amp" to "/axis-media/media.amp",
            "/live" to "/live"
        )
        for ((sub, main) in paths) {
            checkInterrupted()
            progress("Checking standard RTSP streams")
            val base = URI("rtsp", null, host.host, 554, null, null, null).toString()
            val small = probe(base + sub, credentials) ?: continue
            val large = if (sub == main) null else probe(base + main, credentials)
            return select(host.host, listOfNotNull(small, large))
        }
        error("No supported video found. Check IP, credentials and ONVIF/RTSP access. Some cameras require a separate ONVIF account.")
    }

    private fun probe(source: String, credentials: Credentials): DetectedProfile? {
        checkInterrupted()
        val local = relay.register(source, "probe_${UUID.randomUUID().toString().replace("-", "")}", credentials)
        val handle = NativeVideo.create(null, local, false)
        try {
            val deadline = System.nanoTime() + 5_000_000_000
            while (System.nanoTime() < deadline) {
                checkInterrupted()
                val metrics = VideoMetrics.read(handle)
                if (metrics.frames > 0) return DetectedProfile(source, metrics.width, metrics.height)
                if (metrics.error != 0) return null
                Thread.sleep(50)
            }
            return null
        } finally { NativeVideo.close(handle) }
    }

    companion object {
        fun select(host: String, profiles: List<DetectedProfile>): Camera {
            val sorted = profiles.filter { it.width > 0 && it.height > 0 }.sortedBy { it.pixels }
            require(sorted.isNotEmpty()) { "No supported video profiles." }
            return Camera(name = "Camera $host", substream = sorted.first().source,
                mainstream = sorted.last().source.takeIf { it != sorted.first().source })
        }
        private fun checkInterrupted() { if (Thread.currentThread().isInterrupted) throw InterruptedException() }
    }
}