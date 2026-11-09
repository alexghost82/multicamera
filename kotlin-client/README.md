# CameraWall Kotlin for macOS Apple Silicon

An independent Kotlin/JVM + Compose Desktop + GStreamer + go2rtc client.
The Swift prototype and original Python files are not modified or replaced.
This is the first working migration slice, not full feature parity or a
production-certified 60-camera wall.

## Build and run

Install the native dependencies:

```sh
brew install cmake pkg-config gstreamer
make -C kotlin-client setup
make -C kotlin-client test
make -C kotlin-client app
open kotlin-client/build/compose/binaries/main/app/CameraWallKotlin.app
```

Setup downloads official go2rtc 1.9.15 ARM64, Gradle 8.12.1 and Amazon
Corretto 21 into `.tools/`. Corretto is used because Compose packaging
rejects Homebrew JDK distributions. Dependencies and JVM are bundled in
the generated application, but Homebrew GStreamer and its native library
dependencies are still required on the destination Mac. This is an ad-hoc
signed development app, not a notarized standalone installer.

The source targets macOS 14 APIs; installed Homebrew bottles on this
development machine require macOS 27. Older macOS versions have not been
certified. JDK/Gradle/GStreamer versions and native CPU architecture must
match the target environment.

```sh
make -C kotlin-client run
make -C kotlin-client demo
CAMERAWALL_VISUAL_TEST=1 make -C kotlin-client test
CAMERAWALL_SOAK_SECONDS=45 make -C kotlin-client test
```

The visual test opens a real JVM video canvas, resizes it and checks screen
pixels from synthetic video. macOS Screen Recording permission may be
required. The RTSP test publishes local H.264 through go2rtc and requires
actual hardware decoding with `vtdec_hw`; unsupported hardware cannot pass
by silently falling back to CPU decoding. FFmpeg is used only for the
synthetic test publisher, not for application playback.

## Current functionality

- Compose toolbar and IP/User/Password camera form.
- go2rtc ONVIF profile discovery on common service ports, with validated
  RTSP fallbacks for common camera families. Profiles are checked by actual
  decoding; the lowest/highest resolutions become sub/main stream.
- Native GStreamer hardware decoding and rendering inside JVM video canvases.
- Movable/resizable video windows using JInternalFrame inside a Compose
  SwingPanel. Drag the title bar; resize edges/corners. Maximize switches to
  the main stream if configured. Restore returns to the substream.
- A grid toolbar action and saved window bounds.
- Per-camera reconnect/backoff, stale-image clearing, and basic local metrics.
- Configurations in `~/Library/Application Support/CameraWallKotlin/`.
- Credentials in macOS Keychain under `CameraWall.Kotlin.RTSP`, not in URLs
  persisted to disk, process arguments or logs.

Closing a video window hides it from the wall, not the saved camera list;
Disconnect/Connect can reopen it. Editing/removing saved cameras, snapshots,
bulk import, a full connection-state panel and polished crash recovery are
not yet ported. Cancel stops discovery without saving a camera, but the
owned local relay may remain running until app exit.

ONVIF must be enabled on devices that require it; some use separate ONVIF
accounts. Arbitrary vendor-private paths cannot always be inferred from an
IP alone. This build supports hardware-compatible H.264/H.265 with NV12
output, not every codec/profile. It does not alter camera settings.

## Video path

```text
Camera -> local go2rtc -> rtspsrc -> RTP depay/parser -> vtdec_hw
       -> queue (one latest decoded buffer) -> native appsink
       -> retained/mapped GstVideoFrame -> CVPixelBuffer
       -> AVSampleBufferDisplayLayer -> JAWT Canvas -> SwingPanel
```

Pixel buffers never cross into Kotlin/Java; JNI carries controls and small
metric arrays only. The native mapping owns the GstSample until CoreVideo
releases it. No Java ByteArray, Compose Image or per-frame JPEG conversion
is used. This does not prove an end-to-end zero-copy GPU path.

The stock `avsamplebufferlayersink` initially passed short rendering tests
but crashed during a real-camera run inside its asynchronous request-data
callback. The current bridge uses an owned AVSampleBufferDisplayLayer with
appsink callbacks instead, and stops the GStreamer pipeline before detaching
the layer. This must still undergo longer production soak testing.

## Existing Swift relay smoke test

For an explicit temporary check of an already configured camera without
copying its password:

```sh
open native/dist/CameraWall.app --args --connect
make -C kotlin-client existing
```

Or launch the built Kotlin app with `--existing-relay`. This reads only the
Swift camera IDs/enabled state/local RTSP port and attaches to its loopback
relay through Kotlin's own go2rtc. It is a temporary additional relay hop,
not a migrated camera configuration, and requires the Swift relay to stay
running. These temporary attachments are not persisted. Normal IP-based
camera addition connects independently of the Swift client.

## Security and limits

go2rtc listens on loopback ports 21984 (API) and 28554 (RTSP), separate from
the Swift prototype. API requires a random password even on loopback, and
only streams/ONVIF endpoints and non-executable modules are enabled. RTSP
remains accessible to other local users: use a trusted workstation. Crash
or force-kill can leave an orphan helper; normal quit has a JVM shutdown hook.

Local `diagnostics.json` contains only timestamps, IDs, frame/render counts,
dimensions, frame age and error codes. Check its timestamp; a crashed app
can leave an old report. Frame age is NOT camera-to-screen delay.

The 60-stream/200 ms goals are NOT verified for this Kotlin implementation.
Next acceptance gates: longer real-camera soak, actual drag/resize while
playing many streams, 16/60-stream load tests, full dependency bundling and
external camera-to-display latency measurement. The Swift client's previous
60-decoder test is not evidence for this GStreamer/JVM implementation.
