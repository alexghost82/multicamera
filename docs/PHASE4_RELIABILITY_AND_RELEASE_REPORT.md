# ACTA — Phase 4 Reliability & Release Gates Report

- **Date:** 2026-11-20
- **Repository:** `/Users/alexandr.bogdanov/Documents/multicamera` (`main`, HEAD `d76a08b1`)
- **Hardware / OS / Toolchain:** Apple M5 · 24 GB Unified Memory · macOS `27.2.1` (`26B131`) · Xcode `27.2` · Swift `6.4.2`
- **Contract:** `ACTA_AGENT_ARCHITECTURE.md` (§4 Phase 4 & §5 Definition of Done)

---

## 1. Executive Release Decision (GO / NO-GO)

| Release Target | Decision | Evidence Summary |
| :--- | :---: | :--- |
| **Local On-Device Mac Usage (Developer / Single-Mac Deployment)** | **GO** | Full native suite **1,432 passed / 0 failures** (`1,386` XCTest + `113` Swift Testing); live **64/64** VideoToolbox loopback streams + CoreML YOLO26/Pose + ONNX ReID/Seg passed; `vllm-metal 0.30.0` + `qwen3.5-9b` verified at `0.65` util (`nominal` thermal, zero Metal leaks); release `.app` built and `codesign --verify --deep --strict` valid on disk. |
| **External / Third-Party macOS Distribution (Gatekeeper / Notarization)** | **NO-GO (External Prerequisite)** | `security find-identity -v -p codesigning` reports **`0 valid identities found`** (no Apple Developer ID Application certificate or `notarytool` profile installed on this Mac), and `CameraWall` dynamically links 3 Homebrew FFmpeg dylibs (`/opt/homebrew/opt/ffmpeg/lib/libavformat.63.dylib`, `libavcodec.63.dylib`, `libavutil.61.dylib`) that must be bundled into `Contents/Frameworks` and re-signed before removing `com.apple.security.cs.disable-library-validation`. |
| **64 Physical 4K WAN IP Cameras + Simultaneous 64-Way Pose/VLM Soak** | **NOT CLAIMED (Scoped Benchmark Only)** | Verified **64/64** concurrent local loopback `go2rtc` RTSP H.264 (`640×360@15fps`) VideoToolbox decode sessions + wall recovery + YOLO26 (`16.409s`, Exit `0`), and concurrent 4-way mixed `vllm-metal` + 4-stream frame analytics (`1847.9 FPS`, `0` frames > 100 ms, peak `21.591 / 24 GiB` est. used). No claim is made for 64 simultaneous physical WAN 4K cameras running concurrent multi-hour Pose + VLM soak. |

---

## 2. Wave 4A — Full Regression Sweep & Root-Cause Fixes

### Baseline Audit Findings (Before Wave 4A Fixes)
Running all 1,495 tests revealed **35 failures** across 4 root causes:
1. **`UnifiedHistoryEvidence.swift` camera scope parser regressions (6 failures across 4 suites):**
   - `requestsAllCameras` omitted Russian prepositional/instrumental declensions `"всех камерах"` / `"всеми камерами"` and `"list cameras"` / `"список камер"`.
   - `resolveCamera` treated non-camera management nouns after `"camera"` (e.g. `"camera settings"`) and ordinals on empty camera directories (`"на второй камере"`) as unknown camera names, breaking `UnifiedAgentHistoryTests` (3), `ACTACameraListBrokerTests` (1), `ACTAScopedCameraGetActionTests` (1), and `ACTAAnalyticsTests` (1).
   - **Fix:** Updated `UnifiedHistoryEvidence.swift` while keeping every strict unknown/ambiguous camera rejection in `ACTAScopedInspectionTests` passing.
2. **Pre-broker legacy test in `ACTAServiceAdapterTests.swift` (1 failure):**
   - `testLocalAgentDiscoversAndExecutesRegisteredActionWithScriptedTransport` invoked `askACTAChatAgent` without a broker session (which now rightly fails closed).
   - **Fix:** Updated to open a real `ACTALocalActionBroker` session and assert operator review enforcement before mutating `canvas.set_columns` and `settings.update_permissions`.
3. **Cross-test `ModelSelectionRegistry` state leak (2 failures):**
   - `LocalVLMClientTests.testMissingNativeModelReportsItsPath` and `VisionFeatureMatcherTests.testRanksPersistedReIDVectorsWithoutDecodingImages` were affected by prior tests mutating the process-global `ModelSelectionRegistry`.
   - **Fix:** Added clean `ModelSelectionRegistry` save/restore in `LocalVLMClientTests`, `ACTAPhase3VLLMServingTests`, and `ACTAPhase4ReliabilityGateTests`.
4. **Async TCC `SIGABRT` in `ACTAWave1FFullClosureTests.testVoiceListeningLifecycleThroughBroker` on host `xctest`:**
   - Calling real `LocalVoiceInput()` inside headless `/usr/bin/xctest` (which lacks microphone/speech Info.plist usage descriptions) triggered an async macOS TCC abort.
   - **Fix:** Injected synthetic `LocalVoiceInput` into `ACTACanvasFilterState(analysisVoiceInput:)` for deterministic broker voice-lifecycle testing.
5. **Seatbelt sandbox restrictions (27 tests):**
   - `ACTASnapshotExportFoundationTests` (7) and `ACTASnapshotActionTests` (11) walk parent directories with `openat(..., O_NOFOLLOW)` (blocked on `/Users/<user>` inside Seatbelt), and 9 Metal/CoreImage/VideoToolbox/AppKit/nested-`sandbox-exec` tests require the native macOS host. On host, **all 27 passed 100%**.

### New Phase 4 Reliability Gate Suite (`ACTAPhase4ReliabilityGateTests.swift` — 4/4 Passed)
- `testLegacyGhostJSONAndSQLiteMigrationCompatibilityAcrossReopen`: verifies legacy `ghost*` JSON decoding & round-trip preservation, unchanged Keychain account names, and SQLite persistence across reopen.
- `testLocalOnlyRestartRecoveryAndZeroSecretLeak`: verifies `local_only` (`allowExternalAI == false`), clean restart from disk, zero ephemeral API keys on disk, and fail-closed post-restart state.
- `testStaleInferenceAndCancellationDropLateResultsAndDrainLimiter`: verifies mid-flight cancellation drops stale/late previews and drains `ACTALocalVLLMLaneLimiter` to `(0, 0, 0)`.
- `testPoseFSMFallHeuristicsAndAnalyticsSettingsPersistenceAcrossReload`: verifies `FallDetector` standing→fallen FSM transition and `VideoAnalyticsSettingsStore` round-trip persistence.

### Full Native Host Regression Gate Result
```sh
swift test --package-path native --build-system native --disable-automatic-resolution --jobs 2
```
- **Exit code:** `0`
- **XCTest (`CameraCoreTests` + `CameraWallTests`):** **1,386 executed, 67 opt-in skipped, 0 failures** (`47.52s`)
- **Swift Testing (`13` suites):** **113 executed, 113 passed, 0 failures** (`0.198s`)
- **Total:** **1,432 passed, 67 opt-in skipped, 0 failures**.

---

## 3. Wave 4B — Live Opt-In Hardware, Model & 64-Stream E2E Benchmarks

All live opt-in hardware tests executed on the target Apple M5 (`24 GB`, macOS `27.2.1`):

| Verification Suite / Benchmark | Command Flags | Result | Key Measured Evidence |
| :--- | :--- | :---: | :--- |
| **Loopback Showcase & Worker mTLS** | `CAMERAWALL_RUN_SHOWCASE_NETWORK_INTEGRATION=1 CAMERAWALL_RUN_WORKER_CONTROL_INTEGRATION=1` | **PASS** (Exit `0`) | `LocalShowcaseServerTests` 4/4 (`0.052s`), `WorkerControlTests` 6/6 (`0.003s`) |
| **ONNX ReID (Person + Vehicle)** | `CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1` | **PASS** (Exit `0`) | `ONNXReIDEncoderTests` 2/2 (`0.331s` for normalized 512D embeddings) |
| **ONNX Segmentation (`yolo26n-seg.onnx`)** | `CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1` | **PASS** (Exit `0`) | `ONNXSegmentationTests` 1/1 (`0.768s` transparent cutout) |
| **CoreML Pose (`yolo26s-pose.mlpackage`)** | `CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1` | **PASS** (Exit `0`) | `YOLO26PoseDetectorTests` 2/2 (`1.154s`, matched person count on `bus.jpg`) |
| **CoreML YOLO26 (`yolo26n.mlmodelc`)** | `CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1` | **PASS** (Exit `0`) | `YOLO26Tests` 4/4 (`YOLO26n reference: 5 objects, 5 ms`) |
| **64-Stream Loopback `go2rtc` + VideoToolbox + YOLO26 Wall Recovery** | `CAMERAWALL_GO2RTC=... CAMERAWALL_RUN_STREAMING_INTEGRATION=1 CAMERAWALL_RUN_STREAMING_KEYCHAIN_INTEGRATION=1 CAMERAWALL_RUN_STREAMING_YOLO=1 CAMERAWALL_TEST_STREAMS=64` | **PASS** (Exit `0`) | **`Concurrent VideoToolbox sessions with >=5 frames: 64/64`** (`16.409s`) |
| **Local `vllm-metal 0.30.0` (`0.65` util) + 4-Stream Frame Analytics** | See `docs/VLLM_METAL_BENCHMARK.md` §5 | **PASS** (Exit `0`) | Startup `32.1s`, KV cache `5.16 GiB`, peak `wired 15.553 GiB` / `used_est 21.591 GiB`, `nominal` thermal, `1847.9 FPS` (`0` frames > 100 ms), `SIGTERM` clean release (`wired 3.212 GiB`) |

---

## 4. Wave 4C — Security, Privacy, Localization, Release Build & Packaging

1. **Release Build (`-c release`):**
   ```sh
   CLANG_MODULE_CACHE_PATH=/tmp/acta-clang-cache swift build --package-path native --build-system native -c release --disable-sandbox --disable-automatic-resolution --cache-path /tmp/acta-swiftpm-cache --jobs 2
   ```
   - **Exit code:** `0` (`Build complete! 121.03s`, binary `native/.build/release/CameraWall`, `101 MB`).
2. **Entitlements & Metadata Validation:**
   - Added `native/CameraWall.entitlements` (Hardened Runtime template for camera, audio-input, local network client/server, plus documented `disable-library-validation` note for Homebrew FFmpeg).
   - `plutil -lint native/Info.plist native/CameraWall.entitlements native/Resources/en.lproj/Localizable.strings native/Resources/ru.lproj/Localizable.strings` → **Exit `0` (all `OK`)**.
3. **Localization Audit:**
   - `make -C native localization-audit` → **Exit `0`** (`UI string occurrences: 2110; unique keys: 1771; Untranslated source occurrences: 0`; `plutil -lint: OK`).
4. **App Bundle Packaging & Local Signature Verification:**
   - Updated `native/dist/CameraWall.app` with release `CameraWall` (`101 MB`), `go2rtc 1.9.15`, `en.lproj`/`ru.lproj`, `Info.plist`, and signed with `native/CameraWall.entitlements`.
   - `codesign --verify --deep --strict --verbose=2 native/dist/CameraWall.app` → **Exit `0`** (`valid on disk`, `satisfies its Designated Requirement`, `Contents/Helpers/go2rtc` validated).
5. **External Distribution Signing & Notarization Checklist (Required Before Public Release):**
   - [ ] Install an Apple **Developer ID Application** certificate in Keychain (`security find-identity -v -p codesigning`).
   - [ ] Copy `/opt/homebrew/opt/ffmpeg/lib/libav{format,codec,util}.*.dylib` (and transitive deps) into `CameraWall.app/Contents/Frameworks`, rewrite load paths with `install_name_tool` to `@executable_path/../Frameworks/...`, sign each dylib, and remove `com.apple.security.cs.disable-library-validation` from `native/CameraWall.entitlements`.
   - [ ] Sign nested helpers and app bundle with `--options runtime --timestamp --entitlements native/CameraWall.entitlements --sign "Developer ID Application: ..."`.
   - [ ] Submit zipped bundle via `xcrun notarytool submit CameraWall.zip --keychain-profile "<profile>" --wait`, staple with `xcrun stapler staple CameraWall.app`, and verify with `spctl --assess --type execute --verbose=4 CameraWall.app`.

---

## 5. Rollback Plan

- **Code rollback:** Revert only Phase 4 files (`UnifiedHistoryEvidence.swift`, `ACTAServiceAdapterTests.swift`, `LocalVLMClientTests.swift`, `ACTAWave1FFullClosureTests.swift`, `ACTAPhase3VLLMServingTests.swift`, `ACTAPhase4ReliabilityGateTests.swift`, `native/CameraWall.entitlements`, `docs/PHASE4_RELIABILITY_AND_RELEASE_REPORT.md`, `IMPLEMENTATION_REPORT.md`) while preserving pre-existing working-tree changes.
- **Data / Migration safety:** Zero SQLite schema migrations, zero Keychain identifier changes, and zero legacy `ghost*` JSON renames were introduced across Phases 1–4. Rolling back code requires no database downgrade or credential migration.
