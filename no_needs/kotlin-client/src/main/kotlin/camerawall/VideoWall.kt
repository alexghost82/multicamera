package camerawall

import org.json.JSONArray
import org.json.JSONObject
import java.awt.BorderLayout
import java.awt.Canvas
import java.awt.Color
import java.awt.Dimension
import java.awt.Rectangle
import java.awt.event.ComponentAdapter
import java.awt.event.ComponentEvent
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import javax.swing.JDesktopPane
import javax.swing.JInternalFrame
import javax.swing.JLabel
import javax.swing.SwingUtilities
import javax.swing.Timer
import javax.swing.event.InternalFrameAdapter
import javax.swing.event.InternalFrameEvent
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

class VideoWall(val relay: Go2Rtc) : AutoCloseable {
    val desktop = JDesktopPane().apply { background = Color(38, 40, 43); preferredSize = Dimension(1200, 760) }
    private val executor = Executors.newScheduledThreadPool(4) { task -> Thread(task, "CameraWall-GStreamer").apply { isDaemon = true } }
    private val windows = java.util.Collections.synchronizedMap(linkedMapOf<String, VideoWindow>())
    private val layoutFile = CameraStore.directory.resolve("layout.json")
    private var savedLayout = if (java.nio.file.Files.exists(layoutFile)) runCatching { JSONObject(java.nio.file.Files.readString(layoutFile)) }.getOrDefault(JSONObject()) else JSONObject()
    private val layoutTimer = Timer(350) { saveLayout() }.apply { isRepeats = false }
    @Volatile var running = false
        private set
    private var diagnosticsTimer: ScheduledFuture<*>? = null

    fun show(camera: Camera) {
        check(SwingUtilities.isEventDispatchThread())
        if (windows.containsKey(camera.id)) return
        val video = VideoWindow(camera)
        windows[camera.id] = video
        desktop.add(video.frame)
        val saved = savedLayout.optJSONObject(camera.id)
        if (saved != null) {
            video.frame.bounds = Rectangle(max(0, saved.optInt("x")), max(0, saved.optInt("y")),
                saved.optInt("width", 480).coerceIn(120, 8192), saved.optInt("height", 300).coerceIn(90, 8192))
        } else tileUnplaced()
        video.frame.isVisible = true
        video.start()
    }

    fun connect(cameras: List<Camera>) {
        check(SwingUtilities.isEventDispatchThread())
        running = true
        cameras.forEach(::show)
        if (diagnosticsTimer == null) diagnosticsTimer = executor.scheduleWithFixedDelay({ writeDiagnostics() }, 1, 1, TimeUnit.SECONDS)
    }

    fun disconnect() {
        running = false
        windows.values.toList().forEach { it.disconnect() }
        executor.execute { relay.close() }
    }

    fun tileAll() {
        check(SwingUtilities.isEventDispatchThread())
        savedLayout = JSONObject()
        tileUnplaced()
        saveLayout()
    }

    private fun tileUnplaced() {
        val count = windows.size
        if (count == 0) return
        val columns = min(10, count)
        val rows = ceil(count.toDouble() / columns).toInt()
        val width = max(120, (desktop.width.takeIf { it > 0 } ?: 1200) / columns)
        val height = max(90, (desktop.height.takeIf { it > 0 } ?: 760) / rows)
        windows.values.forEachIndexed { index, window ->
            if (!savedLayout.has(window.camera.id)) window.frame.setBounds(index % columns * width, index / columns * height, width, height)
        }
    }

    private fun saveLayout() {
        windows.values.filterNot { it.frame.isMaximum }.forEach { video ->
            val bounds = video.frame.bounds
            savedLayout.put(video.camera.id, JSONObject().put("x", max(0, bounds.x)).put("y", max(0, bounds.y))
                .put("width", bounds.width).put("height", bounds.height))
        }
        runCatching { CameraStore.writePrivate(layoutFile, savedLayout.toString(2)) }
    }

    private fun writeDiagnostics() {
        val entries = JSONArray()
        val copy = synchronized(windows) { windows.values.toList() }
        copy.forEach { video ->
            val metrics = video.lastMetrics
            entries.put(JSONObject().put("id", video.camera.id).put("frames", metrics.frames).put("rendered", metrics.rendered)
                .put("width", metrics.width).put("height", metrics.height).put("frameAgeMs", metrics.ageMs)
                .put("live", metrics.live).put("errorCode", metrics.error).put("reconnects", video.reconnects)
                .put("decoder", if (video.camera.test) "videotestsrc" else "vtdec_hw"))
        }
        runCatching { CameraStore.writePrivate(CameraStore.directory.resolve("diagnostics.json"), JSONObject()
            .put("generatedAt", java.time.Instant.now().toString()).put("running", running)
            .put("cameras", entries).put("note", "Frame age is not camera-to-screen latency.").toString(2)) }
    }

    override fun close() {
        running = false
        layoutTimer.stop()
        diagnosticsTimer?.cancel(false)
        synchronized(windows) { windows.values.toList() }.forEach { it.close() }
        executor.shutdown()
        executor.awaitTermination(10, TimeUnit.SECONDS)
        relay.close()
    }

    private inner class VideoWindow(val camera: Camera) {
        val frame = JInternalFrame(camera.name, true, true, true, true)
        private val canvas = Canvas().apply { background = Color.BLACK }
        private val status = JLabel("Connecting").apply { foreground = Color.DARK_GRAY }
        private val lock = Any()
        private var handle = 0L
        private var future: ScheduledFuture<*>? = null
        private var expanded = false
        private var startedAt = 0L
        private var retryAt = 0L
        private var failures = 0
        @Volatile var reconnects = 0
        @Volatile var lastMetrics = VideoMetrics(0, 0, 0, -1, 0, 0)
        private var previousFrames = 0L
        private var previousTime = System.nanoTime()

        init {
            frame.layout = BorderLayout()
            frame.minimumSize = Dimension(120, 90)
            frame.add(canvas, BorderLayout.CENTER)
            frame.add(status, BorderLayout.SOUTH)
            frame.addComponentListener(object : ComponentAdapter() {
                override fun componentMoved(event: ComponentEvent) { layoutTimer.restart() }
                override fun componentResized(event: ComponentEvent) { layoutTimer.restart() }
            })
            frame.addPropertyChangeListener(JInternalFrame.IS_MAXIMUM_PROPERTY) {
                expanded = frame.isMaximum
                if (camera.mainstream != null) executor.execute { synchronized(lock) { closeHandle(); retryAt = 0 } }
            }
            frame.addInternalFrameListener(object : InternalFrameAdapter() {
                override fun internalFrameClosed(event: InternalFrameEvent) {
                    synchronized(windows) { windows.remove(camera.id) }
                    executor.execute { close() }
                }
            })
        }

        fun start() { future = executor.scheduleWithFixedDelay({ tick() }, 100, 500, TimeUnit.MILLISECONDS) }

        private fun tick() = synchronized(lock) {
            if (!running) { closeHandle(); return@synchronized }
            if (!canvas.isDisplayable || System.nanoTime() < retryAt) return@synchronized
            try {
                if (handle == 0L) {
                    val local = if (camera.test) "" else {
                        relay.start()
                        val credentials = NativeVideo.readSecret(camera.id)?.let(Credentials::decode)
                        relay.register(camera.source(expanded), camera.streamName(expanded), credentials)
                    }
                    handle = NativeVideo.create(canvas, local, camera.test)
                    startedAt = System.nanoTime()
                    previousFrames = 0
                    previousTime = startedAt
                }
                val metrics = VideoMetrics.read(handle)
                lastMetrics = metrics
                val now = System.nanoTime()
                val fps = (metrics.frames - previousFrames).coerceAtLeast(0) * 1_000_000_000.0 / (now - previousTime).coerceAtLeast(1)
                previousFrames = metrics.frames
                previousTime = now
                if (metrics.error != 0 || metrics.ageMs > 5000 || (metrics.frames == 0L && now - startedAt > 8_000_000_000)) {
                    reconnects++
                    failures++
                    closeHandle()
                    retryAt = now + min(15, 1 shl min(failures - 1, 4)) * 1_000_000_000L
                    SwingUtilities.invokeLater { status.text = "Reconnecting" }
                } else {
                    if (!metrics.live && metrics.frames > 0) NativeVideo.blank(handle)
                    if (metrics.live) failures = 0
                    SwingUtilities.invokeLater {
                        status.text = if (metrics.live) "${metrics.width}x${metrics.height} · ${"%.1f".format(fps)} FPS · ${if (camera.test) "Test" else "VideoToolbox"}" else "Waiting for video"
                        status.toolTipText = status.text
                    }
                }
            } catch (_: Exception) {
                reconnects++
                closeHandle()
                retryAt = System.nanoTime() + 3_000_000_000
                SwingUtilities.invokeLater { status.text = "Connection failed; retrying" }
            }
        }

        fun disconnect() { executor.execute { synchronized(lock) { closeHandle(); SwingUtilities.invokeLater { status.text = "Stopped" } } } }
        fun close() { future?.cancel(false); synchronized(lock) { closeHandle() } }
        private fun closeHandle() {
            if (handle != 0L) { NativeVideo.close(handle); handle = 0 }
            lastMetrics = VideoMetrics(0, 0, 0, -1, 0, 0)
        }
    }
}