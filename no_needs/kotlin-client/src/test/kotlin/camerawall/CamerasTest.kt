package camerawall

import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.*

class CamerasTest {
    @Test fun `camera form accepts host only not credential URLs`() {
        assertEquals("192.0.2.1", parseHost("192.0.2.1").host)
        assertEquals(8080, parseHost("192.0.2.1:8080").port)
        assertEquals("[2001:db8::1]", parseHost("2001:db8::1").host)
        for (input in listOf("", "rtsp://camera/live", "user:secret@camera", "camera/live", "camera?exec=bad", "camera:0")) {
            assertFails { parseHost(input) }
        }
    }

    @Test fun `profiles are ranked by resolution and single profile is supported`() {
        val sub = DetectedProfile("onvif://camera?subtype=small", 640, 360)
        val main = DetectedProfile("onvif://camera?subtype=large", 3840, 2160)
        val selected = Discovery.select("camera", listOf(main, sub))
        assertEquals(sub.source, selected.substream)
        assertEquals(main.source, selected.mainstream)
        assertNull(Discovery.select("camera", listOf(sub)).mainstream)
    }

    @Test fun `configuration round trips 60 cameras without credentials`() {
        val directory = Files.createTempDirectory("camerawall-test-")
        val file = directory.resolve("cameras.json")
        try {
            val cameras = (1..60).map { Camera(name = "Camera $it", substream = "rtsp://camera$it.local/live") }
            CameraStore.save(cameras, file)
            assertEquals(cameras, CameraStore.load(file))
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(file)))
            assertFails { Camera(name = "Unsafe", substream = "rtsp://admin:secret@camera/live").validate() }
            assertFalse(Credentials("admin", "secret").toString().contains("secret"))
        } finally { Files.deleteIfExists(file); Files.deleteIfExists(directory) }
    }
}