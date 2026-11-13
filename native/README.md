# CameraWall for Apple Silicon

## Interface Localization

The interface language switch applies English or Russian to app-owned labels,
menus, editor dialogs, tooltips, accessibility text and known runtime messages.
Regional locales such as ru_RU resolve to Russian. Dynamic status/error
templates share a cached catalog and preserve inserted names, paths and IDs.
Stored object/class identifiers remain unchanged; their display names are
localized. User-entered text, model responses, OCR, file names and raw unknown
external diagnostics are data and are not machine-translated by the UI layer.
macOS-owned dialog controls follow macOS language settings; Russian app usage
descriptions are supplied in ru.lproj/InfoPlist.strings.

Run the structured source coverage check with the installed Xcode toolchain:

```sh
make -C native localization-audit
```

For exact compiler-derived SwiftUI keys and placeholder types, from the
workspace root:

```sh
mkdir -p native/.build/localization-audit/compiled
swift build --package-path native --disable-automatic-resolution --jobs 1 -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/native/.build/localization-audit/compiled"
swift -I "$(dirname "$(xcrun --find swift)")/../lib/swift/host" -L "$(dirname "$(xcrun --find swift)")/../lib/swift/host" -Xlinker -rpath -Xlinker "$(dirname "$(xcrun --find swift)")/../lib/swift/host" native/scripts/LocalizationAudit.swift --check-compiled
```

LanguageSettingsTests verify catalog placeholders, compiled-key coverage when
the compiler manifest is present, all 80 detection labels and app permission
descriptions. Source auditing excludes SF Symbols and technical queue names.
Coverage checks do not replace manual review of every UI state or establish
that the previously reported transient sidebar rendering defect is gone.

Native macOS RTSP video wall, independent of camera vendor. Camera streaming
and YOLO do not require a browser or Python runtime. The optional local VLM
runs natively in the app through MLX Swift and Metal. No proprietary camera SDK or video
transcoding is used. The existing Python/HTML project is unchanged.

## Build and launch

Requirements: Apple Silicon, Xcode with macOS 27 SDK, Swift 5.9+, macOS 27+,
Homebrew FFmpeg development libraries, and an internet connection for the
initial go2rtc download. Installed FFmpeg libraries must support your OS.
The FFmpeg bottle installed on the development machine requires macOS 27.

```sh
brew install ffmpeg
make -C native run
```

This builds `native/dist/CameraWall.app` and opens it. go2rtc 1.9.15 ARM64
is included as a helper. The development app still links to Homebrew's
FFmpeg dylibs: it is NOT a standalone redistributable/notarized installer.
Set `FFMPEG_PREFIX` when using a non-default FFmpeg installation.

Normal launch automatically connects all saved enabled cameras, requesting
the relevant macOS capture permissions when needed. `--connect` is no longer
required. Disconnect remains explicit and cancels camera recovery.

Launch also prepares YOLO26n, segmentation, person ReID, vehicle ReID and the
configured local Qwen model (Qwen 3.5 9B by default). Preparation runs in the
background, reuses the inference sessions, and does not download missing files
or enable disabled detection, recording, alerting or sharing features. go2rtc
starts only when an enabled network camera requires it. The model strip below
the header shows Waiting, Loading, Ready or Error for each model, and Busy
while Qwen is processing a request. Ready means the model session loaded,
not that every future response is guaranteed valid. Click a model for error
details; retry loads only models that are not ready. Disconnect keeps models
available for the next connection.

```sh
make -C native test
make -C native stress
```

The stress test opens 60 independent VideoToolbox decoder sessions against
one local synthetic 640x360 / 15 FPS H.264 source relayed through go2rtc.
It requires each session to decode at least five frames. This is a short
concurrency smoke test, not a sustained 60-camera or end-to-end latency test.
The integration test also stops/restarts the synthetic camera publisher,
checks stale-frame detection and resumed video, stops the wall's relay to
verify automatic recovery, and verifies Disconnect cancels pending recovery.

## Cameras

- Add a network camera with `+` → **Network camera**. The form contains only IP, User and Password.
  The name, stream addresses and main/substream selection are automatic.
  Saving starts discovery and connects the camera after successful detection.
- Discovery uses go2rtc's ONVIF client on device-service ports 80, 8080 and
  8899. The IP field also accepts a hostname or an explicit ONVIF port,
  for example `192.0.2.10:8080` or `[2001:db8::10]:8899`.
- Discovered video profiles are tested using the actual VideoToolbox decode
  path. The lowest pixel count is selected for the grid and the highest for
  expanded view. A single working profile is used for both views.
- Without working ONVIF profiles, discovery tests known Hikvision, Dahua,
  Reolink, common `/live/ch00_*`, Axis and `/live` RTSP paths on port 554.
  Guessed URLs are never saved unless they produce a video frame. Discovery
  is cancellable and leaves the configuration unchanged on failure.
- Some devices require ONVIF to be enabled and a separate ONVIF account.
  Arbitrary proprietary paths or disabled ONVIF cannot be inferred from an
  IP alone; use the RTSP list import for those devices. ONVIF fallback does
  not imply universal support for every camera firmware or codec.
- Use the import button for a UTF-8 text file with one RTSP URL per line.
  Empty lines and lines starting with `#` are ignored. Import is explicit;
  the existing workspace `rtsp` file is never read automatically.
- Embedded URL credentials are extracted during import and stored in
  Keychain. The original import file is not changed or deleted; protect it.
- The list button includes disabled cameras. Edit or enable cameras there.
- Choose `+` → **Mac / iPhone camera** to select a built-in Mac camera,
  USB webcam, or iPhone exposed by macOS Continuity Camera. Allow camera
  access when prompted; access can be changed in System Settings → Privacy
  & Security → Camera. No microphone access is requested.
- For iPhone, enable Continuity Camera under Settings → General → AirPlay
  & Continuity, use the same Apple Account, enable Wi-Fi and Bluetooth, and
  keep the iPhone nearby and locked. Use **Refresh cameras** if needed.
- Local cameras are saved by device ID and use AVFoundation directly.
  Missing devices retry automatically; Disconnect releases camera capture.
  Snapshots and YOLO detection use the same frame pipeline as network cameras.
- Connect gradually opens enabled cameras and starts go2rtc only when
  enabled network cameras require it.
- Double-click a tile or use its menu to expand it. If configured, this
  switches that camera to its main stream. Escape returns to the grid.
  Other camera sessions remain connected while one camera is expanded.
- Video windows can be freely arranged inside the application. Drag their
  title bars to move them; drag any edge or corner to resize. The bottom-right
  corner has a visible resize handle. Clicking/dragging a window brings it
  forward. Images retain their original aspect ratio inside the new frame.
- Position and size are saved on mouse release in `cameras.layout.json`
  beside the selected camera configuration. Layout edits never restart
  camera decoders or go2rtc. The grid toolbar button restores automatic tiling
  without reconnecting. A single camera initially fills the available area.
- A focused video window can be moved with arrow keys and resized with
  Shift+arrow keys. Escape during a drag cancels that edit. VoiceOver actions
  also support moving and resizing. Restore an expanded window before dragging.
- A tile's menu provides reconnect, JPEG snapshot, edit and remove.
- Adding/editing a detected camera restarts the wall automatically. Import
  disconnects streams; press Connect again afterwards.
- Settings control columns (1...16), stale-frame threshold (200...30000 ms),
  YOLO confidence (10...90%, in 5% slider steps) and detection FPS (1...5).
  Save persists these values in the selected camera configuration and applies
  them without disconnecting streams. Cancel discards the draft. Invalid input
  or a failed save leaves the running configuration unchanged.
- The go2rtc field shows the actual bundled helper path read-only in a packaged
  app. Without a bundled helper, it edits and validates the custom executable
  path; changing that path while connected restarts the wall. Existing custom
  paths remain stored even when a bundled helper takes precedence.
- Local API and RTSP ports are no longer editable in Settings. Existing saved
  port values remain supported and are not overwritten by saving this form.
  Older configurations without YOLO settings default to 35% and 2 FPS.
- Columns default to 10, initially producing a 10x6 wall for 60
  cameras. Saved manual positions take precedence until the layout is reset.
  At small window sizes, scrolling preserves usable tile sizes.
- The diagnostics button exports frame counts, reconnect counts and frame
  age, without source URLs or camera names. Frame age is NOT glass-to-glass
  latency. `Live` only means recently decoded frames are arriving.
- Local diagnostics are also refreshed once per second in
  `~/Library/Application Support/CameraWall/diagnostics.json` (mode 0600),
  alongside the selected configuration. They include measured decoded FPS,
  resolution, decoder backend and stale state, but no IPs, credentials,
  camera names or video frames. Check `generatedAt` before using a report:
  after an app crash, its last report can remain on disk.
- Hover over a video tile to see its resolution, measured FPS and backend.

Configuration is stored at
`~/Library/Application Support/CameraWall/cameras.json` (mode 0600).
Credentials are in macOS Keychain under `CameraWall.RTSP`, per camera UUID.
Homebrew FFmpeg development libraries, and an internet connection for the
initial go2rtc download. Installed FFmpeg libraries must support your OS.
The FFmpeg bottle installed on the development machine requires macOS 27.
embedded in configured URLs. Do not put secrets into URL query parameters.

An alternate configuration can be opened without changing the default:

```sh
native/dist/CameraWall.app/Contents/MacOS/CameraWall --config /path/cameras.json --connect
```

## Video path

```text
Camera RTSP/RTSPS -> local go2rtc (remux only)
                -> libavformat TCP RTSP -> libavcodec / VideoToolbox
                -> CVPixelBuffer -> AVSampleBufferDisplayLayer
```

Apple's display layer handles native GPU-backed presentation. This is not
one replaceable latest-frame slot. No per-frame JPEG/RGB conversion is used
for video. JPEG conversion happens only when a snapshot is requested.

ONVIF profile addresses are stored without credentials; go2rtc resolves
their RTSP addresses when opening streams. Existing manually imported
RTSP paths are preserved on edit if they still produce video.

The decoder requires a VideoToolbox-capable codec/profile (primarily H.264
and H.265); unsupported formats fail rather than silently using FFmpeg CPU
Audio, recording, LAN-wide discovery and PTZ are outside this MVP.

## YOLO26 object detection

The Swift client includes official Ultralytics YOLO26n object detection,
running locally through Core ML/Vision. The `YOLO26` toolbar switch enables
boxes, COCO class labels and confidence percentages on video. In Settings,
adjust the confidence threshold (default 35%) and requested analysis rate
(default 2 FPS per camera). Inference does not change camera settings or
restart/hold up the video decoder. JPEG snapshots remain unannotated.

```sh
make -C native model
make -C native seg-models
make -C native test app
```

The build downloads `yolo26n.mlpackage.zip` from the official
`ultralytics/yolo-ios-app` v8.3.0 release, compiles it with Apple's
`coremlcompiler`, and bundles the compiled model. The model uses 640x640
input, INT8 weights and NMS-free `[1, 300, 6]` output. The app does not use
Python, PyTorch or an inference server for YOLO inference. The optional VLM
uses the separately managed MLX runtime described below. Core ML requests
`.cpuAndNeuralEngine`; actual hardware placement remains Core ML's choice.

When YOLO26 detection is enabled, new tracks also get a best-effort instance
cutout from the locally bundled `yolo26n-seg.onnx` model through ONNX Runtime's
CoreML provider. The model input is static 640x640; the decoder combines the
300 detection rows and 32 prototype masks, then restores the selected mask to
the source crop. `make -C native seg-models` creates an ignored build-only
Python environment, exports the official Ultralytics checkpoint to ONNX, and
does not add Python to the app. If that model is absent or masking fails,
Apple Vision foreground masking is tried; if both fail, the raw JPEG is kept.
Run `make -C native test-seg` to exercise the exported mask on the sample bus
image. Export tooling and model weights are not embedded into the app; only the
ONNX file is bundled.

One shared utility queue permits only one inference request at a time.
Cameras are visited round-robin, with at most 10 requests/second globally;
the per-camera FPS setting is a ceiling, not a guarantee for 60 cameras.
Only a current decoded frame is retained for an accepted request. Old
results, reconnect results, disabled detection and stale video clear or
discard boxes. Coordinates follow aspect-fit letterboxing and tile resize.
Person and vehicle detections receive short-lived per-camera track IDs using
bounding-box overlap. These IDs do not link cameras, survive reconnects or
identify a person; uncertain or interrupted tracks start a new ID. They are
not safety-critical decisions.

## Local track history

The **Tracked objects** section records person and vehicle tracks while YOLO26
is enabled. Each track stores camera, class, first/last seen times, sample
count, best detector confidence, the latest bounding box, one raw JPEG crop and
an optional transparent PNG cutout. Both are resized to at most 320 pixels on
the long side. Full frames are not retained by this feature. YOLO26-seg is the
primary cutout source; Apple Vision foreground-instance masking is a fallback.
When neither provides a mask, the raw JPEG remains available.

History is stored locally in
`~/Library/Application Support/CameraWall/identity-history.sqlite3`; crops are
in the adjacent `identity-crops/` directory. A 512D ReID vector is stored in
SQLite on the first observation of each track and reused for later comparisons.
Directories use mode `0700` and files use `0600`. Records, vectors and both
crop files are removed after 30 days, or can be deleted individually from
**Tracked objects**. Tracks do not automatically receive identities across
cameras. **Find similar**
compares up to 40 recent saved crops from other cameras and shows the five
nearest raw distances. With the optional ONNX models installed, person and
vehicle embeddings use the GHOST preprocessing and 512D encoders through ONNX
Runtime/CoreML. If a legacy row has no vector, CameraWall uses the saved JPEG
once to compute it; without model files it falls back to generic Vision
feature prints. A lower distance means more visually similar; distances are
not probabilities or calibrated identity scores. Operators must select and
group tracks themselves, and can detach those groups later. These remain
human-confirmed review links.

## ReID validation and threshold tuning

**Validate ReID** reviews unlabeled cross-camera pairs with saved embeddings.
The operator marks each pair **Same** or **Different**; Same reuses the manual
operator grouping, while Different is stored as a separate pair label and can
be undone. Neither action runs automatically. Labels are local, and are removed
when either track is deleted or expires after 30 days. Tracks without valid
512D embeddings are not offered for review.

The threshold sweep uses the same cosine distance shown by Find similar
(`1 - cosine similarity`, clamped to 0...2). Positive pairs come only from
operator-confirmed groups on different cameras; negative pairs come only from
explicit Different decisions. Untagged pairs are never treated as negatives.
The default target precision is 99.5%; operators can adjust it from 90% to
100%. A recommendation is withheld until there are at least 20 positive and
100 negative pairs. Precision, recall and false-match rate are empirical on
the labeled pairs used to choose the threshold, not a held-out evaluation;
multiple pairs from the same operator group may be correlated. The suggested
distance is advisory and is not applied to identity assignment.

## Hikvision ISAPI camera events

Network cameras can opt in to read-only Hikvision event monitoring from the
camera editor. CameraWall opens
`GET /ISAPI/Event/notification/alertStream` directly and handles HTTP Digest
or Basic authentication using credentials from Keychain. This does not use a
Hikvision Device Network SDK or go2rtc's `isapi://` source; that go2rtc source
is for backchannel audio, not event notifications.

The monitor is active only while the wall is connected. Reconnect uses a
1-to-15-second backoff. HTTP is the default transport and does not encrypt
credentials or events; use HTTPS where the camera supports it and its
certificate is trusted by macOS. Keep camera traffic on a trusted network.
Event types and payload fields vary by camera model and firmware; the monitor
stores event type, state, channel, description and device timestamp when
provided. It does not save raw XML or images.

Event metadata is stored in
`~/Library/Application Support/CameraWall/isapi-events.json` with `0600`
permissions, capped at 1000 records and purged after 30 days. It can be cleared
from the Events view. This integration has parser/mock HTTP coverage but has
not been qualified against a physical Hikvision camera or every firmware's
Digest/alert-stream behavior. PTZ, settings, and other ISAPI endpoints are not
implemented.

Run `make -C native reid-models` to download the local person and vehicle
encoders. `make -C native test-reid` checks both real model outputs. `make -C
native app` bundles the models in the app. Review the applicable Ultralytics
and Open Model Zoo model licenses before redistribution or proprietary use.

Each saved crop can also be described through the configured loopback-only VLM.
The result stores a short summary and per-attribute confidence/evidence in the
same local database. Person descriptions are limited to visible clothing,
carried items, posture, direction and visible text; they do not identify a face
or infer demographic traits. VLM descriptions do not create or merge tracks.

The **History** tab in AI Analysis supports read-only questions about at most
30 recent tracks. It sends metadata and saved structured descriptions as text
to the loopback VLM; crop images and SQL access are not included. Replies are
shown with only citations that match track UUIDs in that request. Treat model
answers as advisory and verify the cited local records.

Diagnostics include enabled state, detection count, inference count and
inference milliseconds, but do not persist images or bounding-box histories.
Per-camera detection enablement and the inference rate/threshold are saved in
the camera configuration. Existing camera flags are preserved when Settings
is saved. Detection defaults off for a new camera unless explicitly enabled
or launched with `--detect`.
The 60-camera playback and 200 ms latency targets are not certified with
inference enabled.

Tests verify real YOLO26 inference on an official reference image, output
decoding, confidence filtering, overlay geometry, and continuing RTSP video
while inference runs. Reference-image timing is not sustained multi-camera
throughput. Ultralytics models use AGPL-3.0 / Enterprise licensing; review
the applicable terms before redistribution or proprietary deployment:
[Ultralytics licensing](https://www.ultralytics.com/license)

## Local Qwen VLM

CameraWall loads the optional Qwen model directly in its own process through
MLX Swift. There is no Python runtime, HTTP inference server, listening port or
external VLM process. Camera frames remain inside CameraWall. The release app
bundles the model under `Contents/Resources/qwen3.5-9b`. Scheduled analysis is off by default,
uses a 60-second per-camera interval when enabled, and starts with all enabled
cameras selected. Configure the model, camera scope and alert
conditions in the VLM panel. CameraWall sends at most one VLM request at a time.

Validated scheduled answers are saved immediately per camera to the text-only
`automatic_camera_scans` table in the private `identity-history.sqlite3` database.
They never enter the general conversation. Rows contain a scan UUID, camera
UUID/name, observation time and answer, not frames. The existing 30-day history
retention applies: queries exclude expired scans and startup cleanup removes
them. A failed database write fails the scheduled request rather than reporting
successful storage; already saved results from earlier cameras remain available.
The History tab searches the full retained track and scan history, selecting at
most 30 evidence records for a model request. It also works without tracked
objects or a live camera connection. Enter a question and use **Send question**
or Command-Return. Follow-up questions use the recent conversation and, when
available, previously cited records. The persistence switch saves the research
conversation locally; asking questions does not require that switch.

Single-day queries such as “today”, “yesterday”, “сегодня”, “вчера”,
“позавчера”, `YYYY-MM-DD` and `DD.MM.YYYY` use the computer's local calendar
and time zone. Multiple-day comparisons are not automatically filtered.
Common Russian/English object and color terms are matched locally; the optional
query-expansion switch uses Qwen for additional equivalent terms. Tracks require
YOLO detection, and scan summaries require scheduled analysis to have been
enabled. History does not search the separate alerts, camera-event, mission or
sampled-frame stores and is not a continuous video archive. Scan citations are
separate from track citations and cannot authorize track-description actions.
Search selection and model answers remain advisory, not an exhaustive temporal
report or proof of factual accuracy.

To smoke-test the History tab's model path with synthetic local data:

```sh
CAMERAWALL_TEST_VLM_MODEL=/path/to/qwen3.5-9b swift test --package-path native --disable-automatic-resolution --filter LocalVLMClientTests/testInstalledQwenAnswersSyntheticSavedHistory
```

The Ask tab has a visible Send question command and Command-Return shortcut.
Operator requests (Ask, History, mission consults, manual crop descriptions and
local showcase questions) do not wait for background work such as scheduled
scans, missions, memory samples or queued crop descriptions. The app loads
independent Qwen instances: one per roughly 7 GB of RAM above a 10 GB reserve,
at most three (two on a 24 GB Mac). Background work never occupies every
instance, so an operator request starts immediately on a free instance and runs
in parallel with it. Extra instances load on first use, which adds a few
seconds, and are released after three idle minutes. On Macs with room for only
one instance, requests share it and operator requests are served first.

While an Ask question is still being answered, one more Ask question can wait;
a second pending question cannot overwrite it. Rejected submissions keep the
draft. Disconnect explicitly cancels a queued question and retains its text in
the conversation with a cancellation message. History questions do not depend
on camera connections and are not cancelled by a disconnect.

The selected checkpoint is `mlx-community/Qwen3.5-9B-4bit`, a base vision model
in MLX format. Its weights occupy about 5.95 GB. The model is not
instruction-tuned; prompt adherence and structured alert output should be
validated on the target cameras. Runtime memory and throughput also depend on
image size, context, macOS and other workloads. `make app` requires the weights
at `native/.build/models/qwen3.5-9b` and copies them into the signed app bundle.
During development the same directory is loaded directly. The model container
is cached in memory and shared by all VLM features.
Preferences and up to 100 alert records are stored locally with private file
permissions. Alert records contain the camera name, condition and text
evidence, but no image. Alerts are advisory and require operator review; the
app performs no automatic external action.

CameraWall constrains prompts to visible scene analysis, ignores instructions
shown in frames, and only records alerts that exactly match configured
conditions and include evidence. VLM output can still be incorrect; alerts
are advisory and require operator review.

Question-driven VLM answers are checked against Russian, Hebrew or English
as detected from the question. If the language recognizer gives an unsupported
language for a short question, its letters select the supported Russian,
Hebrew or English alphabet instead. This fallback is only for questions;
generated answers still use the strict output checks. Before publication, the answer and any alert
condition/evidence must use the required alphabet and language in every
sentence. Unknown languages, mixed alphabets, emoji, invisible control
characters, replacement characters and embedded markup/service tokens are
rejected rather than silently removed. Normal punctuation, digits and Hebrew
diacritics are allowed. Non-target-script names and abbreviations can also
be rejected by this strict policy. A rejected camera/history answer produces
a refusal in the question language instead of exposing the invalid model
text. Prompts prohibit speculation and require an explicit uncertainty
statement when evidence is insufficient; these checks do not prove factual
correctness or eliminate model hallucinations. Human review remains required.
Camera analysis retries an invalid generated answer at most once with an
explicit language/JSON correction. Neither failed attempt is published.
Cancellation and missing-model failures are not retried.

Single-script questions select their alphabet before statistical language
recognition. Short generated phrases of up to six words that fail raw language
recognition get a second check in question-language context, because macOS can
misclassify valid Russian such as "Обстановка спокойна." as Bulgarian. Alphabet,
symbol, JSON and long-answer checks remain enforced. The context check is
heuristic, not a proof of language or factual correctness. Camera/history
failures report the specific category in the question language instead of
using the same generic message for every error.

To check language routing in the actual executable without starting the app,
models, relay or cameras, run this bounded self-check from the workspace root:

```sh
native/dist/CameraWall.app/Contents/MacOS/CameraWall --check-vlm-language
```

The JSON report identifies the executable and checks Russian, Hebrew and
English routing/refusals. This checks local validation logic, not inference
or the live camera connection.

Network operations have a five-second interrupt deadline. Decoding starts
at a keyframe. Reconnect uses exponential backoff up to 15 seconds with
jitter. Stale images are removed from the display (default: 1000 ms).
The stale threshold is not a playback buffer or latency measurement.

## Security and lifecycle

go2rtc API and RTSP listeners bind only to `127.0.0.1` on ports 11984 and
18554 by default. Only RTSP, ONVIF and the API are enabled. The API allowlist
contains `/api/streams` and `/api/onvif`; the ONVIF server endpoints,
executable sources and remote management endpoints are not exposed. The API requires
a random per-launch password even for loopback requests. Other local users
can still access the loopback RTSP listener: this MVP is for a trusted,
single-user workstation, not a hostile multi-user host.

The startup config contains no camera addresses or camera credentials. It
is created in a private temporary directory (0700), mode 0600, and removed
after startup. Camera sources are registered in memory with API PATCH,
not persisted into a go2rtc configuration. Logs are disabled. Camera URLs
and passwords are not passed as process arguments.

Automatic detection runs a separate temporary go2rtc instance on randomly
selected loopback ports, with its own API password. It stops on completion
or cancellation. The current wall can keep playing during detection.

Normal Disconnect/Quit terminates the owned helper. Force-killing the app
or a crash may leave an orphan go2rtc process; inspect the occupied ports
before restarting. The app never kills unrelated processes or takes over
an existing go2rtc instance. Direct RTSP is not encrypted; use a trusted
camera VLAN/network or configure RTSPS where supported.

If the owned relay stops while the wall is connected, the app removes old
frames and automatically restarts go2rtc and re-registers enabled cameras.
Recovery is limited to five attempts with 1, 2, 4, 8 and 15 second delays.
Thirty seconds of stable relay operation resets this attempt budget.
Disconnect cancels pending recovery; it never reconnects against the user's
explicit stop. Initial configuration/startup errors remain actionable
errors rather than triggering automatic retries indefinitely.

## Native Migration Status

These additions are incremental implementations, not full GHOST ONWAY parity.
LAN phone push is excluded and has not been changed.

- Cross-camera candidate review validates distances, track categories, distinct
  cameras and finite observation intervals before ranking. Pair ranking is
  deterministic and deduplicated. Review shows an observation gap or overlap;
  overlap is advisory because camera topology is unknown. Old pending proposals
  load their referenced tracks even outside the latest 1000 records. Calibration
  and every identity decision still require operator review; this is not the
  complete source resolver or a calibrated identity probability.
- Operations alerts support operator/configured-rule priority, a critical-first
  queue, open/acknowledged/resolved states, notes and a retained review audit.
  Resolution requires a nonempty note. Schema 6 adds review/audit tables and
  preserves existing acknowledgements, jobs and action proposals. Review and
  acknowledgement changes commit atomically. Review metadata follows feature
  retention, with cleanup on use; storage is capped at 1000 review states and
  10000 audit entries. Alert details show the last 100 audit entries. A separate
  sound opt-in allows one short system beep for newly pending critical alerts;
  there is no continuous alarm or external notification. Priority comes from
  the operator or the configured rule, never from model-generated severity.
  Manual HTML export includes up to 100 text alerts and operator notes, escapes
  untrusted content, disables external content with CSP and writes mode 0600.
  Confirmed scheduled-rule alerts can include an eight-second local lookback
  sequence only when operations alerts, scheduled analysis, an enabled matching
  rule, and full-frame retention are opted in. Sampling runs at up to 2 FPS,
  keeps at most 16 JPEGs per camera and is
  globally capped at 256 frames/128 MiB in RAM. Frames are written only after
  the model returns a matching enabled rule with nonempty evidence. Saved clips
  contain at most 16 JPEGs/8 MiB each, 100 clips/128 MiB total, use mode 0600 in
  a 0700 directory and expire after seven days. The Events detail shows frames
  one at a time; it does not encode MP4 or expose a network URL. Clearing alerts
  or an individual clip deletes its files. The HTML report intentionally omits
  image data and clips.
- The Events view has an opt-in in-app read-only monitor for fresh camera feeds,
  the local network-camera relay and track-history availability. It polls every
  five seconds while CameraWall is open, confirms a fault after three failures
  and recovery after two successes, and persists at most 120 transition events
  in a private local file. Intentional disconnect/connecting is inactive, not a
  fault. This does not survive the app process, run as an independent helper,
  inspect external services, send system notifications or restart anything;
  therefore it is not full `MON-01` parity. Tunnel and public watcher
  surfaces remain excluded. The separate opt-in worker LaunchAgent is
  documented below and does not monitor host events.
- Standing local watches are opt-in under operations alerts. Up to 24 rules
  match every normalized term in recent (five-minute) visible descriptions and
  evidence, optionally scoped to cameras. Rules expire after two hours by
  default; an explicit no-expiry choice is available. Each rule fires once per
  per-camera track, and the alert stores the rule/track UUIDs for deduplication.
  Rules and fired-track state use a private, bounded local JSON file. Matching
  does not infer a person identity, protected trait or intent and does not invoke
  model tools. This is not a conversation thread or source identity-level watch.
- Motion-aware tracking is an opt-in in Tracked objects. It predicts the center
  using the last measured velocity, prioritizes predicted overlap and falls
  back to the last observed box for abrupt stops. Weak detections can continue
  existing tracks but cannot create new IDs. This is not a full ByteTrack or
  camera-motion compensation implementation.
- Research offers opt-in local query expansion using the existing Qwen model.
  A bounded plan contains equivalent terms/translations, never camera evidence.
  The same ranking is used across all retained-history pages and the final
  evidence prompt. Invalid plans fall back to lexical search; cancellation is
  propagated. This is model-assisted retrieval, not a vector index, and its
  translation/retrieval quality still needs real-model evaluation.
- Vehicle OCR candidates can optionally be saved with their timestamp and source
  crop SHA-256 in the track row. They remain unverified text, not plate or
  jurisdiction assertions. Candidate storage is capped at 20 per vehicle track
  and follows track deletion and 30-day retention. Turning persistence off does
  not erase saved evidence; individual saved results can be removed explicitly.
  OCR commits require uninterrupted opt-in; late results after deletion or
  request cancellation are discarded. No extra image copy or registry is used.
- Identity review filters accepted sidecar history by camera, class, time,
  exact attribute value and a two-camera sequence. Dossiers include intervals,
  conflicting attribute evidence and source track UUIDs. Unknown attributes and
  confidence below 0.5 are excluded. Overlapping cross-camera intervals do not
  establish sequential travel. Full retained history is paged read-only; the
  UI retains accepted records in memory and needs large-history scale testing.
- The VLM Schedule panel exposes the latest 50 description jobs and explicit
  refresh. Manual retry requires a failed job, feature opt-in and queue capacity.
  Job UUID and total attempt count are preserved.
- Optional research actions support only `describe_tracks` for one to four
  distinct cited evidence UUIDs. Proposals are saved without execution. Confirm
  requires both operator-actions and description opt-ins and existing tracks;
  Reject only records the decision. Jobs and approval audit commit atomically.
  Existing pending description jobs are reused; repeat confirmation is refused.
  Schema 5 adds proposal and audit tables without replacing existing feature
  data. Expiry is enforced on confirmation; cleanup follows feature retention
  when the action list is accessed or proposals are created. No shell, SQL,
  network or deletion tools are exposed to the model.
- Missions save a normalized adjacent-frame grayscale pixel-change score from
  decoded 16x16 thumbnails. This is not a semantic event or threat score. Empty
  or invalid VLM answers are retried at most once; cancellation, missing-model
  and invalid-image errors are not retried. Existing opt-in, session, generation
  and freshness checks still control result commits. Raw frames are not retained.
- Each mission has an optional text consult thread. The local VLM receives only
  that mission's latest 20 saved run summaries and 20 prior messages; it has no
  live-frame input, tools or mutation actions. Replies are limited to four
  sentences/420 characters. Threads are stored in the bounded private mission
  document, survive new runs, and are removed with the mission or explicitly
  cleared. Disabling scheduled missions cancels an active consult; replies are
  discarded if the feature is disabled, the mission is deleted, the thread is
  cleared or the task is cancelled.

Local deterministic verification, run from the workspace root:

```sh
swift test --package-path native --skip-update --filter 'CameraCoreTests|TrackResearchTests|CameraMissionTests|YOLO26Tests|OperationsPreferencesTests|VLMPreferencesTests'
```

These checks use temporary stores, generated images, mock VLM responses and
the installed YOLO reference model. They do not use real cameras. Vision OCR
is exercised on generated text. GUI accessibility, permissions, VLM quality
and sustained resource use remain unverified. Full tracking/resolver parity,
semantic multilingual retrieval, all action kinds, complete alert/mission
workflows, plate-region detection and watcher/backup/share workflows remain
unfinished. App-local roles, public access, LaunchAgent, tunnels and external
plate registries remain excluded by the agreed local single-user constraints.

## 200 ms acceptance gate

200 ms is a target, NOT a verified guarantee. Use a wired network, camera
low-latency settings, substreams, no B-frames where available, and suitable
GOP/FPS. Start with H.264 640x360 at 10-15 FPS, then tune to actual cameras.
Connection establishment and waiting for the first IDR can take longer
than 200 ms; steady-state playback is measured separately.

## YOLO26 Pose worker model

Provision the official `yolo26s-pose.pt` release checkpoint and export it to
the FP16 Core ML package consumed by the worker:

```sh
make -C native pose-model
make -C native test-pose
```

The checkpoint's SHA-256 is verified before use. Export dependencies are
isolated in `.build/pose-exporter-py313-torch27/` (Python 3.13 is required).
The checkpoint and generated `native/.build/models/yolo26s-pose.mlpackage` are
build artifacts and are not bundled into the app. Set the worker's absolute
`poseModelPath` to that package when creating `worker.json`. The model uses
Ultralytics AGPL-3.0 licensing; review the applicable terms before
redistribution or proprietary deployment:
[Ultralytics licensing](https://www.ultralytics.com/license).

## Multi-worker Pose mode (Phase 2)

The same executable has a headless `--worker` mode. A node config selects
`coordinator` or `worker`; the coordinator accepts only configured TLS peer
certificate fingerprints and maps each fingerprint to one worker UUID. TLS
uses the local Keychain identity label plus normal certificate-chain
validation and exact leaf-certificate SHA-256 pinning. Import each node's
identity into that user's login Keychain, trust the issuing CA in macOS, and
put the matching fingerprints in the peer allowlists. The worker config must
contain exactly one coordinator pin. Addresses are literal IPv4/IPv6 values;
wildcard binds and DNS names are rejected.

Example coordinator fields:

```json
{
  "role": "coordinator",
  "nodeID": "<coordinator-uuid>",
  "displayName": "coordinator",
  "tlsIdentityLabel": "CameraWall coordinator",
  "trustedPeerIDsByFingerprint": {
    "<worker-certificate-sha256-hex>": "<worker-uuid>"
  },
  "bindAddress": "192.168.10.20",
  "listenPort": 19443,
  "coordinatorAddress": null,
  "coordinatorPort": null,
  "cameraConfigurationPath": null,
  "poseModelPath": null,
  "maximumCameraCount": 8,
  "cameraAssignments": [
    { "cameraID": "<camera-uuid>", "workerID": "<worker-uuid>" }
  ]
}
```

Example worker fields:

```json
{
  "role": "worker",
  "nodeID": "<worker-uuid>",
  "displayName": "worker-1",
  "tlsIdentityLabel": "CameraWall worker 1",
  "trustedPeerIDsByFingerprint": {
    "<coordinator-certificate-sha256-hex>": "<coordinator-uuid>"
  },
  "bindAddress": null,
  "listenPort": null,
  "coordinatorAddress": "192.168.10.20",
  "coordinatorPort": 19443,
  "cameraConfigurationPath": "/Users/operator/Library/Application Support/CameraWall/cameras.json",
  "poseModelPath": "/Users/operator/multicamera/native/.build/models/yolo26s-pose.mlpackage",
  "maximumCameraCount": 2,
  "cameraAssignments": []
}
```

Replace every placeholder with real UUIDs, addresses and certificate pins.
`cameraAssignments` is static and must reference camera UUIDs provisioned in
the assigned worker's local `cameras.json`. RTSP credentials stay in that
worker's Keychain; no camera URL or credential is sent to the coordinator.
The configured worker capacity cannot exceed its enabled local network-camera
count. Coordinator assignments are all-or-nothing per heartbeat and do not
automatically fail over. Leases expire after 30 seconds; a worker rejects
stale results and stops assigned streams after 10 seconds without coordinator
acknowledgement.

The Pose package is compiled on first use and cached under the user's
Application Support directory. Each worker loads one shared FP16 model and
uses a bounded single-inference queue over its assigned camera sessions. Only
control metadata (node UUID/display name/session, model identifier, camera
UUIDs/leases and aggregate inference rate) crosses the channel; frames, crops
and keypoints do not. The durable worker event spool is local, capped at
10,000 records / 16 MiB
with a 64 KiB payload ceiling, mode 0600, and refuses new events at capacity
instead of evicting older records.

Fall detection runs on every worker Pose result (`CameraCore/FallDetector.swift`,
rules from `human-fall-detection-guide.md`). Per camera it keeps lightweight
person tracks (IoU matching plus proximity re-linking across gaps of up to
3 s and 2 box diagonals), and a debounced STANDING/WALKING/SITTING/FALLING/FALLEN
state machine driven by torso angle (>= 55 degrees), box aspect ratio in frame
pixels (>= 1.15) and height collapse (<= 0.55) against an EMA standing-height
baseline (alpha 0.05, learned only while upright). FALLEN needs at least two
samples and 0.8 s of fall posture, extended to 2 s when the Pose cadence is at
or below 1.5 FPS; walking/velocity cues are ignored below 5 FPS. Pose runs with a
0.15 floor, but detections under 0.4 can only keep FALLING/FALLEN tracks alive.
Each confirmed fall is appended to the worker event spool as `fall.detected`
(with the current camera lease) and, when Operational Alerts is enabled,
raised as a critical local alert subject to the operations cooldown.
Forwarding spooled events to the coordinator is not enabled in Phase 2.

Save the node file as
`~/Library/Application Support/CameraWall/worker.json` with mode 0600. The
parent directory should be mode 0700. Install the per-user LaunchAgent without
starting it, then explicitly bootstrap it after the config, Keychain identity,
camera credentials and model path are ready:

```sh
native/dist/CameraWall.app/Contents/MacOS/CameraWall --install-worker-agent --config "$HOME/Library/Application Support/CameraWall/worker.json"
native/dist/CameraWall.app/Contents/MacOS/CameraWall --bootstrap-worker-agent
native/dist/CameraWall.app/Contents/MacOS/CameraWall --bootout-worker-agent
native/dist/CameraWall.app/Contents/MacOS/CameraWall --uninstall-worker-agent
```

The LaunchAgent runs as the logged-in user so it can access that user's
Keychain. Installation writes only the per-user plist; bootstrap/bootout are
separate commands. No firewall, DNS, interface or system-daemon settings are
changed automatically.

Before install, run the worker in the foreground once to validate Keychain,
camera and model access:

```sh
native/dist/CameraWall.app/Contents/MacOS/CameraWall --worker --config "$HOME/Library/Application Support/CameraWall/worker.json"
```

For a DER certificate, the configured pin is the lowercase digest printed by:

```sh
openssl x509 -in node-certificate.pem -outform DER | shasum -a 256
```

Unit and local Core ML tests pass, including the fixed `bus.jpg` four-person
Pose smoke. Same-host loopback mTLS registration, heartbeat and static lease
round-trip pass using ephemeral in-memory test identities. This does not use
the user's login Keychain or install/start launchd. Production Keychain
identity, RTSP reconnect under network loss, LaunchAgent after logout/reboot,
and sustained multi-worker capacity remain unverified. This is not a
64-camera or production acceptance claim.

Measure camera-to-screen delay using an external visible timer/event and
a high-speed recording of both the event and display. Repeat for 1, 16 and
60 real cameras, then run a sustained thermal/network soak test and cable
disconnect/reconnect tests. Client frame age cannot establish this delay.

Before redistribution, bundle and audit native library dependencies,
review the selected FFmpeg build's GPL/LGPL obligations, replace ad-hoc
signing with Developer ID signing/notarization, and harden crash cleanup.
