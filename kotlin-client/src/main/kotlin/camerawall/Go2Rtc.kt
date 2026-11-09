package camerawall

import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

class Go2Rtc(private val executable: Path, val apiPort: Int = 21984, val rtspPort: Int = 28554) : AutoCloseable {
    private var child: Process? = null
    private val token = UUID.randomUUID().toString() + UUID.randomUUID()
    private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build()
    val running get() = child?.isAlive == true

    @Synchronized fun start() {
        if (running) return
        require(Files.isExecutable(executable)) { "go2rtc executable not found. Run make setup." }
        val settings = JSONObject().put("app", JSONObject().put("modules", listOf("api", "rtsp", "onvif")))
            .put("api", JSONObject().put("listen", "127.0.0.1:$apiPort").put("username", "camerawall")
                .put("password", token).put("local_auth", true).put("allow_paths", listOf("/api/streams", "/api/onvif")))
            .put("rtsp", JSONObject().put("listen", "127.0.0.1:$rtspPort").put("default_query", "video"))
            .put("log", JSONObject().put("level", "disabled")).put("streams", JSONObject())
        val directory = Files.createTempDirectory("camerawall-kotlin-")
        val file = directory.resolve("relay.json")
        try {
            CameraStore.writePrivate(file, settings.toString().replace("\\/", "/"))
            child = ProcessBuilder(executable.toString(), "-config", file.toString())
                .redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start()
            repeat(40) {
                check(running) { "go2rtc stopped during startup. Check the local ports." }
                try { request("GET", "/api/streams"); return } catch (_: Exception) { Thread.sleep(100) }
            }
            close()
            error("go2rtc did not start. Check local ports $apiPort and $rtspPort.")
        } finally { Files.deleteIfExists(file); Files.deleteIfExists(directory) }
    }

    fun register(source: String, name: String, credentials: Credentials? = null): String {
        val uri = URI(source)
        val address = if (credentials == null || credentials.user.isEmpty()) source else
            URI(uri.scheme, "${credentials.user}:${credentials.password}", uri.host, uri.port, uri.path, uri.query, null).toASCIIString()
        request("PATCH", "/api/streams", mapOf("name" to name, "src" to address))
        return "rtsp://127.0.0.1:$rtspPort/$name?video"
    }

    fun profiles(host: URI, credentials: Credentials): List<String> {
        val ports = if (host.port != -1) listOf(host.port) else listOf(80, 8080, 8899)
        for (port in ports) {
            val source = URI("onvif", "${credentials.user}:${credentials.password}", host.host, port, null, null, null).toASCIIString()
            try {
                val result = JSONObject(request("GET", "/api/onvif", mapOf("src" to source), 6)).getJSONArray("sources")
                val profiles = (0 until result.length()).mapNotNull { index ->
                    val uri = URI(result.getJSONObject(index).getString("url"))
                    if (uri.scheme != "onvif" || uri.query.orEmpty().contains("snapshot")) null
                    else URI(uri.scheme, null, uri.host, uri.port, uri.path, uri.query, null).toASCIIString()
                }
                if (profiles.isNotEmpty()) return profiles
            } catch (_: Exception) { if (Thread.currentThread().isInterrupted) throw InterruptedException() }
        }
        return emptyList()
    }

    private fun request(method: String, path: String, query: Map<String, String> = emptyMap(), timeout: Long = 2): String {
        val suffix = if (query.isEmpty()) "" else query.entries.joinToString("&", "?") { (key, value) ->
            URLEncoder.encode(key, Charsets.UTF_8) + "=" + URLEncoder.encode(value, Charsets.UTF_8)
        }
        val auth = Base64.getEncoder().encodeToString("camerawall:$token".toByteArray())
        val request = HttpRequest.newBuilder(URI("http://127.0.0.1:$apiPort$path$suffix"))
            .timeout(Duration.ofSeconds(timeout)).header("Authorization", "Basic $auth")
            .method(method, HttpRequest.BodyPublishers.noBody()).build()
        val response = http.send(request, HttpResponse.BodyHandlers.ofString())
        check(response.statusCode() in 200..299) { "go2rtc HTTP ${response.statusCode()}" }
        return response.body()
    }

    @Synchronized override fun close() {
        child?.let { if (it.isAlive) { it.destroy(); if (!it.waitFor(3, TimeUnit.SECONDS)) { it.destroyForcibly(); it.waitFor() } } }
        child = null
    }

    companion object {
        fun executable(): Path {
            val resources = System.getProperty("compose.application.resources.dir")
            return listOfNotNull(System.getenv("GO2RTC_PATH")?.let(Path::of), resources?.let { Path.of(it, "go2rtc") },
                Path.of(".tools", "go2rtc"), Path.of("kotlin-client", ".tools", "go2rtc"),
                Path.of("..", "native", ".build", "tools", "go2rtc"), Path.of("native", ".build", "tools", "go2rtc"))
                .firstOrNull { Files.isExecutable(it) }?.toAbsolutePath() ?: Path.of("/opt/homebrew/bin/go2rtc")
        }
    }
}