package camerawall

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.TooltipArea
import androidx.compose.material.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.awt.SwingPanel
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.*
import kotlinx.coroutines.*
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import javax.swing.SwingUtilities

fun main(args: Array<String>) = application {
    val scope = rememberCoroutineScope()
    val relay = remember {
        Go2Rtc(Go2Rtc.executable()).also { helper ->
            Runtime.getRuntime().addShutdownHook(Thread({ helper.close() }, "CameraWallKotlin-relay-cleanup"))
        }
    }
    val wall = remember { VideoWall(relay) }
    val cameras = remember { mutableStateListOf<Camera>() }
    var dialog by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var connected by remember { mutableStateOf(false) }
    var closing by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        try {
            cameras.addAll(withContext(Dispatchers.IO) { CameraStore.load() })
            if (args.contains("--existing-relay")) {
                val path = Path.of(System.getProperty("user.home"), "Library", "Application Support", "CameraWall", "cameras.json")
                val config = withContext(Dispatchers.IO) { org.json.JSONObject(Files.readString(path)) }
                val existing = config.getJSONArray("cameras")
                repeat(existing.length()) { index ->
                    val item = existing.getJSONObject(index)
                    if (item.optBoolean("enabled", true)) {
                        val name = "cam_${item.getString("id").replace("-", "").lowercase()}_sub"
                        cameras.add(Camera(name = "Existing relay ${index + 1}", substream = "rtsp://127.0.0.1:${config.optInt("rtspPort", 18554)}/$name?video", transient = true))
                    }
                }
            }
            if (args.contains("--demo")) cameras.add(Camera(name = "GStreamer test", substream = "", test = true))
            if (cameras.isNotEmpty()) { wall.connect(cameras.toList()); connected = true }
        } catch (_: Exception) { failure = "Cannot load cameras. Check the configuration file or existing relay." }
    }

    fun quit() {
        if (closing) return
        closing = true
        scope.launch { withContext(Dispatchers.IO) { wall.close() }; exitApplication() }
    }

    Window(onCloseRequest = { quit() }, title = "CameraWall Kotlin", state = rememberWindowState(width = 1280.dp, height = 860.dp)) {
        MaterialTheme(colors = lightColors(primary = Color(0xFF176B5B), secondary = Color(0xFF8A6418))) {
            Column(Modifier.fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(10.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("CameraWall Kotlin", style = MaterialTheme.typography.h6)
                    Spacer(Modifier.weight(1f))
                    ToolButton("Add camera", Icons.Default.Add, enabled = !closing) { dialog = true }
                    ToolButton(if (connected) "Disconnect" else "Connect", if (connected) Icons.Default.Stop else Icons.Default.PlayArrow, enabled = !closing) {
                        if (connected) wall.disconnect() else wall.connect(cameras.toList())
                        connected = !connected
                    }
                    ToolButton("Arrange video windows", Icons.Default.Refresh) { wall.tileAll() }
                }
                Divider()
                SwingPanel(factory = { wall.desktop }, modifier = Modifier.weight(1f).fillMaxWidth())
                Text(if (closing) "Closing" else "${cameras.size} cameras · ${if (connected) "Connected" else "Stopped"}", modifier = Modifier.padding(8.dp), style = MaterialTheme.typography.caption)
            }
            if (dialog) AddCameraDialog(relay, onClose = { dialog = false }, onAdded = { camera ->
                cameras.add(camera)
                wall.connect(cameras.toList())
                connected = true
                dialog = false
            }, existing = cameras.filterNot { it.test || it.transient }.toList())
            if (failure != null) AlertDialog(onDismissRequest = { failure = null }, title = { Text("CameraWall") },
                text = { Text(failure!!) }, confirmButton = { TextButton(onClick = { failure = null }) { Text("OK") } })
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolButton(label: String, icon: ImageVector, enabled: Boolean = true, action: () -> Unit) {
    TooltipArea(tooltip = { Surface(elevation = 4.dp) { Text(label, Modifier.padding(8.dp)) } }) {
        IconButton(onClick = action, enabled = enabled) { Icon(icon, label) }
    }
}

@Composable
private fun AddCameraDialog(relay: Go2Rtc, existing: List<Camera>, onClose: () -> Unit, onAdded: (Camera) -> Unit) {
    var ip by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }
    DialogWindow(onCloseRequest = { job?.cancel(); onClose() }, title = "Add camera", state = rememberDialogState(width = 500.dp, height = 420.dp)) {
        MaterialTheme {
            Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(ip, { ip = it }, label = { Text("IP") }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(user, { user = it }, label = { Text("User") }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true, enabled = !busy,
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(status, style = MaterialTheme.typography.caption) }
                error?.let { Text(it, color = MaterialTheme.colors.error, style = MaterialTheme.typography.caption) }
                Spacer(Modifier.weight(1f))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = { job?.cancel(); onClose() }) { Text("Cancel") }
                    Button(enabled = !busy, onClick = {
                        try { parseHost(ip) } catch (_: Exception) { error = "Enter a valid camera IP address."; return@Button }
                        busy = true
                        error = null
                        job = scope.launch {
                            try {
                                val credentials = Credentials(user, password)
                                val camera = runInterruptible(Dispatchers.IO) {
                                    val detected = Discovery(relay).detect(ip, credentials) { progress -> scope.launch { status = progress } }
                                    ensureActive()
                                    check(NativeVideo.writeSecret(detected.id, credentials.encode()) == 0) { "Cannot save credentials to Keychain." }
                                    CameraStore.save(existing + detected)
                                    detected
                                }
                                onAdded(camera)
                            } catch (_: CancellationException) {
                            } catch (failure: Exception) {
                                error = if (failure is IllegalStateException || failure is IllegalArgumentException) failure.message else "Camera discovery failed. Check IP, credentials and network access."
                            } finally { busy = false }
                        }
                    }) { Text("Add") }
                }
            }
        }
    }
}