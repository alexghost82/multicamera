package camerawall

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

data class Camera(val id: String = UUID.randomUUID().toString(), val name: String, val substream: String,
                  val mainstream: String? = null, val test: Boolean = false, val transient: Boolean = false) {
    fun source(expanded: Boolean) = if (expanded) mainstream ?: substream else substream
    fun streamName(expanded: Boolean) = "cam_${id.replace("-", "")}_${if (expanded && mainstream != null) "main" else "sub"}"
    fun validate() {
        UUID.fromString(id)
        require(name.isNotBlank()) { "Camera name is required." }
        if (test) return
        listOfNotNull(substream, mainstream).forEach {
            val uri = URI(it)
            require(uri.scheme in setOf("rtsp", "rtsps", "onvif") && !uri.host.isNullOrBlank() && uri.userInfo == null && uri.fragment == null) {
                "Camera source must not contain credentials or executable commands."
            }
        }
    }
}

class Credentials(val user: String, val password: String) {
    fun encode() = JSONObject().put("user", user).put("password", password).toString()
    override fun toString() = "Credentials(redacted)"
    companion object {
        fun decode(text: String): Credentials = JSONObject(text).let { Credentials(it.getString("user"), it.getString("password")) }
    }
}

object CameraStore {
    val directory: Path = Path.of(System.getProperty("user.home"), "Library", "Application Support", "CameraWallKotlin")
    val file: Path = directory.resolve("cameras.json")
    fun load(path: Path = file): List<Camera> {
        if (!Files.exists(path)) return emptyList()
        val array = JSONObject(Files.readString(path)).getJSONArray("cameras")
        val cameras = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            Camera(item.getString("id"), item.getString("name"), item.getString("substream"),
                item.optString("mainstream").takeIf { it.isNotEmpty() })
        }
        require(cameras.map { it.id }.toSet().size == cameras.size) { "Duplicate camera IDs." }
        cameras.forEach(Camera::validate)
        return cameras
    }
    fun save(cameras: List<Camera>, path: Path = file) {
        cameras.forEach(Camera::validate)
        val array = JSONArray()
        cameras.filterNot { it.test || it.transient }.forEach {
            array.put(JSONObject().put("id", it.id).put("name", it.name).put("substream", it.substream).put("mainstream", it.mainstream ?: ""))
        }
        writePrivate(path, JSONObject().put("cameras", array).toString(2))
    }
    fun writePrivate(path: Path, text: String) {
        Files.createDirectories(path.parent, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")))
        val temporary = Files.createTempFile(path.parent, ".camerawall-", ".tmp", PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        try {
            Files.writeString(temporary, text)
            Files.move(temporary, path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } finally { Files.deleteIfExists(temporary) }
    }
}

fun parseHost(input: String): URI {
    val text = input.trim()
    require(text.isNotEmpty() && !text.contains("/") && !text.contains("@") && !text.contains("?") && !text.contains("#")) { "Enter the camera IP, optionally with :port." }
    val host = if (text.count { it == ':' } > 1 && !text.startsWith("[")) "[$text]" else text
    val uri = URI("http://$host")
    require(!uri.host.isNullOrBlank() && (uri.port == -1 || uri.port in 1..65535)) { "Invalid IP address or port." }
    return uri
}