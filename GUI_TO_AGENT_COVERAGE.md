# ACTA: GUI to Agent Functional Coverage Matrix

Date: 2026-11-17  
Target: Native Swift/macOS ACTA Application (`alexghost82/multicamera`)  
Version: 1.0.0-baseline  

---

## 1. Executive Summary

**Phase 1 Final Closure (Waves 1A–1F complete, 2026-11-20):**
- **Production model-facing broker (`WallModel.buildProductionBrokerActions()` ↔ `ACTAAnalyticsCoordinator.allBrokerActionIDs`):** **123 typed action mappings** (all mutating operations strictly gated behind `ACTALocalActionBroker` + `ACTABrokerReviewView` operator review, durable SQLite audit, idempotency keys, and per-action execution deadlines), plus **15 scoped legacy read-only inspection tools** (with `run_readonly_sql` disabled) and `present_answer` = **138 verified agent capabilities** covering Categories A–I and every GUI inventory candidate.
- **Registry & Broker Parity Test:** `ACTAPhase1FullParityTests.testProductionBrokerBijectionAndCompletePhase1Catalogue` enforces 1:1 bijection between `WallModel.buildProductionBrokerActions()` and `ACTAAnalyticsCoordinator.allBrokerActionIDs`, unique action/parameter schemas, `AUTHORIZATION_DENIED` / `UNSUPPORTED` for unknown actions, and full broker session catalogue discovery.
- **Direct GUI Audit (`initiator: "ui_direct"`):** `WallModel.recordDirectGUIAction(...)` logs key direct GUI mutations into `ghost_chat_tool_calls` with `thread_id = "ui_direct"`, `initiator = "ui_direct"`, and secret/URL redaction (`ACTAWave1FFullClosureTests.testDirectGUIAuditAndExcludedUnsafeActions`).
- **Approved Security & Scope Decisions Implemented:**
  - `settings.set_api_key` / `settings.clear_api_key`: secret values never pass through LLM arguments, review text, tool outputs, or audit logs; `set_api_key` opens a native secure prompt (`NSSecureTextField`) only after operator confirmation and preserves `CameraWall.GhostCredentials` (`GhostKey`/`AlertKey`).
  - `camera.add_network` / `camera.edit`: structured credential-free parameters (`scheme`, `host`, `port`, `path`) pass strict broker displayability checks without exposing credentials; `camera.import_sources` reads from an operator-reviewed local file and writes any embedded credentials directly to Keychain without logging or returning them.
  - `camera.set_favorite`: wired via process-local revisioned `ACTALocalFavoriteReviewDomain` + `ACTAPreparedCameraFavoriteAction` with explicit documentation that `UserDefaults` does not guarantee cross-process atomicity.
  - `settings.toggle_showcase`: loopback `127.0.0.1` only, bearer token withheld from model output.
  - `alert.clear_all`, `monitor.clear_isapi_events`, `memory.clear_all_frames`, `memory.resume_frame_deletion`: snapshot-bound destructive actions with strict two-phase confirmation and post-clear verification.
  - `app.select_section`, `settings.select_section`, `voice.set_dictation_language`: bidirectionally synced via `@MainActor ACTANavigationBridge` between SwiftUI views (`ACTASecurityCenterView`, `SettingsHubView`, `VLMPanel`) and reviewed broker actions.
  - `camera.discover_local`, `camera.discover_screens`, `alert.list_review_history`, `alert.list_clips`, `incident.get_evidence_metadata`, `identity.describe_track`, `identity.find_similar_tracks`: wired as scoped read-only or reviewed broker actions with sensitive notes/paths/bytes strictly redacted.
  - **Approved Exclusions (`EXCLUDED — APPROVED (UNSUPPORTED)`):** `window.toggle_fullscreen`, `showcase.copy_link`, `ai.toggle_spoken_briefing`, `worker.edit_config`, `agent.request_confirmation`, `agent.resolve_confirmation` are intentionally NOT model-callable and return `AUTHORIZATION_DENIED` (verified by `ACTAWave1FFullClosureTests.testDirectGUIAuditAndExcludedUnsafeActions`).
- **Localization Gate:** `make -C native localization-audit` exits `0` with `Untranslated source occurrences: 0` across all 2,078 UI string occurrences (1,741 unique keys) and `plutil -lint` `OK` on EN and RU `Localizable.strings`.
- **Honest Scope Boundary:** Phase 1 proves typed action schemas, broker authorization/confirmation, domain-service parity, direct GUI audit, idempotency, timeouts, localization, and read-after-write verification on isolated temporary stores (`0 failures`). Live GUI rendering, real microphone/TTS audibility, real RTSP/USB cameras, real Keychain UI interaction, real Qwen/vLLM Metal serving, and release gates remain in **Phases 2–4**.

### Historical Checkpoint Notes (Pre-Wave 1A–1E)

Current implementation checkpoint: the model-facing broker advertises `camera.list`, `camera.get`, `incident.list`, `incident.get`, `alert.vlm_list`, `monitor.get_isapi_events`, `mission.list`, `reid.calibrate`, `settings.get_section`, `analytics.get_settings`, `settings.update_reid_calibration`, `watch.list`, `canvas.get_state`, `canvas.set_filter`, `canvas.select_cameras`, `canvas.set_presentation`, `canvas.set_arrange_mode`, and `analysis.set_section`; scoped legacy inspections are separate. The five window-local mutations require operator review and reject stale state. A late root `onDisappear` after reappearance could detach the active state or stop newer voice input; this lifecycle ordering has not been verified or excluded. The model-facing camera list omits stream addresses, paths and device identifiers; camera details expose only UUID and configuration flags. Incident, alert and mission inspections expose only minimal metadata. ISAPI inspection returns event IDs and received times only. Canvas state excludes search and location contents and selected camera IDs. Calibration returns aggregate metrics without applying settings; its reviewed view-state update may trigger asynchronous metric recalculation. Settings inspection exposes current grid columns, stale timeout, detection threshold and detection FPS, not complete sections. Analytics inspection exposes global switches, mode, sensitivity, overlays and advanced values after comparing runtime settings with storage; it does not report overrides or health. Watch inspection exposes only active rule scope and expiry type. Other registry actions are not enabled for model execution. Earlier checkpoints below describe historic registry availability, not current model access. The original baseline inventory is not proof of exhaustive UI coverage.

Additionally, `settings.update_system` is advertised when the live language settings
instance is available; it accepts only a reviewed interface-language change.
`mission.history` is also advertised as a scoped read of run IDs, status and
timestamps only; summaries and consultation messages remain unavailable.
`mission.run_now` is advertised but unavailable in both the broker and legacy
registry until execution is safely coordinated. Manual GUI execution is unchanged.
Six global analytics mutations (`analytics.set_global_toggle`,
`analytics.set_threshold`, `analytics.set_sampling_fps`, `analytics.set_overlay`
`analytics.set_sensitivity_profile` and `analytics.set_execution_mode`) are
also available with local review. Execution mode changes only the saved setting,
not routing or worker readiness.
They may stop and restart analytics; camera overrides and zones remain outside
these actions. Cooperating new instances use a lock and revision file, but old
instances must be closed and crash durability and live detector health remain
unverified.

`memory.toggle_pin` is available when the shared narrative presentation state
is healthy. It requires review, rejects stale revisions and does not pin an
unmarked chapter. `settings.export_diagnostics` is available, and mission HTML
(`monitor.export_report_html`) and PDF (`mission.export_pdf`) are offered when
mission storage is available. The operator chooses the destination, reviews
the frozen content and confirms; publication does not replace existing files.
The selected directory must not be modified by untrusted writers.
`camera.snapshot` is registered with a camera ID as its only argument; the
operator selects the destination, reviews the captured JPEG and confirms.
Source validity is checked before publication, but not atomically with a
concurrent camera stop. Synthetic model-route and broker tests passed for the
other three exports and memory pin. Frame action and the coordinator's extracted
route passed isolated tests with stubbed dependencies; the full production
coordinator, WallModel registration and real GUI have not been tested.

GUI YOLO and AI chat preference writes, system/detection settings and
`WallModel.apply` use the coordinated camera store and reject an active
cooperating worker or discovery lease. Replacement writes reject stale storage
and unknown fields; an uncertain publication quarantines coordinated writes and
does not automatically roll back credentials. Thirteen isolated writer tests
passed, but WallModel was only syntax checked. Configuration and Keychain are
not transactional. Coordinated store
writes require a writer lease; a restricted runtime-owner path is tested but
not yet connected to GUI runtime. GUI runtimes and other
configuration writers are not yet coordinated across processes. Until this is
implemented, use one application instance with no parallel workers or older
versions; concurrent writers may lose changes or conflict over credentials.
Camera configuration mutation actions are not connected to the agent.
The GUI favorite toggle rejects unsupported or malformed stored values rather
than rewriting them, and displays an error. Twelve isolated favorite tests
passed; `UserDefaults` durability and cross-process coordination remain
unverified, so `camera.set_favorite` is not registered.
The current GUI performs a separate UserDefaults read and write, without a
shared transaction with camera identity changes or other processes; readback
cannot certify persistent storage. The production broker's action list and
model-facing mapping do not include this action. Connecting it would require
changes to that production wiring and a compatible, durably verified shared
storage and identity protocol, none of which is established here.
Two additional synthetic tests cover broker approval of the disabled legacy
action and concurrent approvals against the existing fake review domain. They
were typechecked only; the attempted isolated test build was denied by content
policy. The fake-domain concurrency test is not evidence that the GUI or
UserDefaults is serialized.
The coordinated camera store accepts tested legacy and reformatted JSON when
semantic round-trip preserves the existing fields; unknown fields, duplicate
keys and numeric precision loss are rejected. Nine isolated store tests passed,
including stale-write and competing-process checks. This does not coordinate
the remaining application writers or prove compatibility with every legacy file.

`identity.set_follow_up` is available when its shared identity state is healthy.
It changes only an operator reminder, not identity verification. The identity
screen can inspect a flag and requires an operator to review the saved state
before clearing an uncertain outcome. Isolated tests exercised the Coordinator,
broker, SQLite and operator recovery with stubbed surrounding services;
production WallModel wiring and the complete screen have not been tested.
Older application versions must be closed; crash durability is not proven.

When `allowVoiceInput` is disabled in this application instance, active and
pending dictation attempts are cancelled across its windows; delayed permission
and capture callbacks cannot restart those attempts. Isolated lifecycle tests
passed. The real microphone and GUI were not tested, the system permission
dialog cannot be dismissed programmatically, and changes made by another
process are not automatically observed.

Participating operator audit-log instances now coordinate JSON updates and
refresh reads. Lock contention fails promptly and retains pending entries in
memory for retry on refresh or a subsequent write. Audit-only writes and the
standalone journal use a common audit lock; an interrupted journal blocks
audit access until startup recovery by the incident manager for matching paths.
Conflicting or incompatible journals fail closed. If pending entries exceed
the retention limit, an error is reported and they remain in memory; automatic
recovery from this overflow is not implemented. This does not establish crash
durability or atomicity between incident changes and audit entries. Older versions and
non-participating writers remain uncoordinated.

Mission coordination: `WallModel` acquires an exclusive nonblocking sidecar
lease before loading missions and retains it through shutdown and outstanding
tasks. A second cooperating instance displays an error and refuses mission
reads, writes and scheduling; shared feature-preference writes are also refused.
Mission writes and scheduler entry use a main-actor reentrancy gate. Failed
loads and uncertain writes disable the service, and legacy or unknown mission
fields are not rewritten. All newer instances must use the same store path;
older versions and nonparticipating writers must be closed. Never unlink the
lock. Isolated subprocess lock tests passed, but the complete model lifecycle,
async callbacks and real GUI have not been verified end to end. Consequently
`mission.run_now` remains fail-closed and `mission.edit` is not registered.
The lease is not a crash-durability guarantee.

The broker constructs reviewed create-only diagnostics exports and, when the
mission snapshot is available, mission HTML and PDF exports. Their dialogs and
live model routing were not exercised in this check.

The prepared incident acknowledgement remains unregistered. For compatible
incident and audit files in one directory, the manager now journals audited
creation, escalation, note, status, secondary-verification changes, and evidence
reference clearing with its audit entry together. Deletion of the actual bundle
still happens separately before that transaction.
Evidence and other writers and GUI reads are not all coordinated, and safe UI
refresh remains necessary before registration; the mission lease does not protect incidents. The
GUI reports evidence deletion failures and warns when files may already have
been removed. A failed incident-reference save restores the in-memory reference
and does not record a successful evidence-deletion audit event. This does not
make deletion, incident storage and audit atomic or recover deleted evidence.
Six isolated engine tests and fourteen evidence-store tests passed with synthetic
data; the real GUI was not tested. File access errors are not treated as
evidence absence, and non-directory bundle paths are rejected.
The standalone journal rejects JSON it cannot round-trip without loss, including
before recovery; this conservative check may reject some valid legacy formats.
Production startup uses its recovery path, but all incident mutations and GUI reads
are not fully coordinated through it.

This working inventory maps currently identified UI/domain operations to agent action contracts. Exhaustive control-by-control parity has not been established.

- **Action rows:** baseline inventory plus subsequently discovered contracts; exhaustive UI coverage remains unverified.
- **Baseline legacy tools:** 16 read-only query tools + 1 terminal tool (`present_answer`)
- **Baseline legacy mutations:** 3 (`rename_identity`, `merge_identities`, `split_identity`)
- **Baseline gap estimate:** the old 89 / 82.4% figure depended on the unsupported 108-operation total and is not accepted as a coverage measurement.

### Additional GUI inventory candidates (Closed in Waves 1A–1F)

Every candidate below is either registered and verified in the production model-facing broker (`WallModel.buildProductionBrokerActions()` ↔ `ACTAAnalyticsCoordinator.allBrokerActionIDs`) or explicitly marked `EXCLUDED — APPROVED (UNSUPPORTED)` with negative broker tests in `ACTAWave1FFullClosureTests.testDirectGUIAuditAndExcludedUnsafeActions`.

| Candidate | GUI operation | Resolution (Wave 1A–1F) |
| :--- | :--- | :--- |
| `camera.set_all_running` | Start or stop the camera wall | `IMPLEMENTED — BROKER REVIEWED` (`ACTACameraSetAllRunningAction`; `ACTAWave1BCameraAnalyticsBrokerTests`) |
| `camera.import_sources` | Import RTSP sources from a file | `IMPLEMENTED — BROKER REVIEWED` (`ACTACameraImportSourcesAction`, credentials written directly to Keychain; `ACTAWave1BCameraAnalyticsBrokerTests`) |
| `camera.set_favorite` | Mark or unmark a camera as favorite | `IMPLEMENTED — BROKER REVIEWED` (`ACTALocalFavoriteReviewDomain` + `ACTAPreparedCameraFavoriteAction`; process-local revision, `UserDefaults` not cross-process atomic; `ACTAWave1BCameraAnalyticsBrokerTests`) |
| `canvas.set_filter` | Filter by status, favorite, events, search or location | `IMPLEMENTED — BROKER REVIEWED` (`ACTACanvasFilterActionTests`, `ACTABrokerReviewViewTests`) |
| `canvas.select_cameras` | Select individual cameras, all or none | `IMPLEMENTED — BROKER REVIEWED` (`ACTACanvasSelectCamerasActionTests`, `ACTABrokerReviewViewTests`) |
| `canvas.set_tile_frame`, `canvas.set_arrange_mode` | Arrange and move camera tiles | `IMPLEMENTED — BROKER REVIEWED` (`ACTACanvasTileFrameActionTests`, `ACTACanvasArrangeActionTests`) |
| `chat.select_thread`, `chat.new_thread`, `chat.cancel_request` | Switch/create chat thread or cancel request | `IMPLEMENTED — BROKER REVIEWED` (`ACTAChatThreadAction`; `ACTAWave1DMemoryIdentityChatBrokerTests`) |
| `identity.group_tracks`, `identity.detach_tracks` | Group selected tracks or remove from operator groups | `IMPLEMENTED — BROKER REVIEWED` (`ACTAIdentityTrackGroupAction`; `ACTAWave1FFullClosureTests`) |
| `identity.review_proposal`, `identity.undo_merge` | Review cross-camera proposal or undo accepted merge | `IMPLEMENTED — BROKER REVIEWED` (`ACTAIdentityReviewProposalAction`, `ACTAIdentityUndoMergeAction`; `ACTAWave1FFullClosureTests`, `CrossCameraIdentityReviewServiceTests`) |
| `incident.get_evidence_metadata` | Inspect incident evidence availability without leaking paths/bytes | `IMPLEMENTED — SCOPED READ` (`ACTAIncidentGetEvidenceMetadataAction`; `ACTAWave1FFullClosureTests`) |
| `alert.list_clips` | Inspect saved critical alert lookback clip metadata | `IMPLEMENTED — SCOPED READ` (`ACTAAlertListClipsAction`; `ACTAWave1FFullClosureTests`) |
| `alert.list_review_history` | Inspect sanitized operator alert review statuses without raw notes | `IMPLEMENTED — SCOPED READ` (`ACTAAlertListReviewHistoryAction`; `ACTAWave1FFullClosureTests`) |
| `identity.describe_track`, `identity.find_similar_tracks` | Queue local crop description or evaluate cross-camera visual similarity | `IMPLEMENTED — BROKER REVIEWED / SCOPED READ` (`ACTAIdentityDescribeTrackAction`, `ACTAIdentityFindSimilarTracksAction`; `ACTAWave1FFullClosureTests`) |
| `ai.toggle_spoken_briefing` | Enable or disable spoken briefing in AI settings | `EXCLUDED — APPROVED (UNSUPPORTED)` (external-backend risk; verified `AUTHORIZATION_DENIED` in `ACTAWave1FFullClosureTests`) |
| `canvas.set_presentation` / `window.toggle_fullscreen` | Change camera display mode or key-window fullscreen | `canvas.set_presentation`: `IMPLEMENTED — BROKER REVIEWED`; `window.toggle_fullscreen`: `EXCLUDED — APPROVED (UNSUPPORTED)` (pure OS window chrome; verified `AUTHORIZATION_DENIED`) |
| `camera.discover_local` | Inspect connected local video capture devices | `IMPLEMENTED — SCOPED READ` (`ACTACameraDiscoverLocalAction`, never starts capture; `ACTAWave1FFullClosureTests`) |
| `camera.discover_screens` | Inspect available ScreenCaptureKit displays | `IMPLEMENTED — SCOPED READ` (`ACTACameraDiscoverScreensAction`, never starts capture; `ACTAWave1FFullClosureTests`) |
| `app.select_section`, `settings.select_section` | Select main sidebar section or SettingsHub section | `IMPLEMENTED — BROKER REVIEWED` (`ACTANavigationBridge`, `ACTAAppSelectSectionAction`, `ACTASettingsSelectSectionAction`; `ACTAWave1FFullClosureTests`) |
| `analysis.set_section` | Select Chat, Schedule, or Alerts tab | `IMPLEMENTED — BROKER REVIEWED` (`ACTAAnalysisSectionActionTests`, `ACTABrokerReviewViewTests`) |
| `memory.resume_frame_deletion` | Resume a journaled frame deletion | `IMPLEMENTED — BROKER REVIEWED` (`ACTACameraMemoryRecoveryAction`; `ACTACameraMemoryRecoveryActionTests`, `ACTAWave1DMemoryIdentityChatBrokerTests`) |
| `description_jobs.inspect`, `description_jobs.retry` | List recent description jobs or retry a failed job | `IMPLEMENTED — SCOPED READ / BROKER REVIEWED` (`ACTADescriptionJobActionsTests`, `ACTAWave1DMemoryIdentityChatBrokerTests`) |
| `camera.edit` (local/screen/network) | Edit camera metadata, structured network URL, or disabled local/screen source IDs | `IMPLEMENTED — BROKER REVIEWED` (`ACTABrokerCameraEditAction`; `ACTACameraConfigurationActionTests`, `ACTAWave1BCameraAnalyticsBrokerTests`) |
| `worker.edit_config` | Select, edit, or save external worker node config file | `EXCLUDED — APPROVED (UNSUPPORTED)` (next-launch host config; verified `AUTHORIZATION_DENIED` in `ACTAWave1FFullClosureTests`) |
| `mission.export_pdf`, `monitor.export_report_html`, `settings.export_diagnostics`, `camera.snapshot` | Create-only reviewed local exports and frame snapshots | `IMPLEMENTED — BROKER REVIEWED` (`ACTAMissionHTMLExportTests`, `ACTACreateOnlyExportTests`, `ACTASnapshotActionTests`, `ACTAPhase1FullParityTests`) |
| `showcase.copy_link` | Copy temporary bearer-token link to clipboard | `EXCLUDED — APPROVED (UNSUPPORTED)` (bearer token must never be disclosed to model; verified `AUTHORIZATION_DENIED` in `ACTAWave1FFullClosureTests`) |

---

## 2. Policy & Safety Classifications

- **`Inspect`**: Read-only query, does not mutate application state or disk. **Auto-authorized.**
- **`Reversible`**: Mutates runtime state or preferences with straightforward rollback (e.g., column count, threshold, feature toggle, acknowledging an alert). **Auto-authorized or single-turn notice.**
- **`ServiceAffecting`**: Disrupts active video streams, network connections, or reloads models (e.g., camera reconnect, model engine switch, go2rtc restart). **Requires explicit status notice.**
- **`Destructive`**: Permanently removes data, deletes cameras, deletes evidence, or merges identity profiles. **Requires explicit two-phase operator confirmation.**

---

## 3. Comprehensive Coverage Matrix

### Category A: Camera Management & Video Canvas

All Category A actions below are registered in the production model-facing broker (`WallModel.buildProductionBrokerActions()` ↔ `ACTAAnalyticsCoordinator.allBrokerActionIDs`) and verified in isolated tests. Live RTSP/USB/Screen hardware and SwiftUI rendering remain Phase 2–4 acceptance scope.

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `camera.list` | `WallView` / `CameraManager` | `WallModel` | `include_disabled: Bool?` | `Inspect` | Scoped broker | `ACTACameraListBrokerTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — SCOPED READ` |
| `camera.get` | `CameraEditor` | `WallModel` | `camera_id: UUID` | `Inspect` | Scoped broker | `ACTAScopedCameraGetActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — SCOPED READ` |
| `camera.discover_local` | `LocalCameraEditor` | `CameraSession` | `none` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ` |
| `camera.discover_screens` | `ScreenCaptureCameraEditor` | `SCShareableContent` | `none` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ` |
| `camera.add_network` | `CameraEditor` sheet | `WallModel` | `name, scheme, host, port?, path?, mainstream_*?; always disabled` | `ServiceAffecting` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTACameraConfigurationActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.add_local` | `LocalCameraEditor` sheet | `WallModel` | `device_id, name; always disabled` | `ServiceAffecting` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.add_screen` | `ScreenCaptureCameraEditor` | `WallModel` | `display_id (>0), name; always disabled` | `ServiceAffecting` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.add_file` | `VideoFileCameraEditor` | `WallModel` | `file_path, name?; always disabled` | `ServiceAffecting` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.edit` | `CameraEditor` sheet | `WallModel` | `camera_id, name?, location?, clear_location?, scheme?, host?, port?, path?, device_id?, display_id?` | `ServiceAffecting` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAWave1BCameraAnalyticsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.set_processing` | Camera context settings | `WallModel` | `camera_id, feature: yolo/ai_chat, enabled: Bool` | `Reversible` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.set_enabled` | `CameraManager` toggle | `WallModel` | `camera_id: UUID, enabled: Bool` | `ServiceAffecting` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.remove` | `WallView` remove alert | `WallModel` | `camera_id: UUID` | `Destructive` | **Broker review** | `ACTACameraConfigurationActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.reconnect` | Camera context menu | `WallModel` | `camera_id: UUID` | `ServiceAffecting` | **Broker review** | `CameraReconnectAttemptTests`, `CameraReconnectIntegrationTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.set_favorite` | Camera context menu | `ACTALocalFavoriteReviewDomain` (`UserDefaults`) | `camera_id: UUID or unique name, favorite: Bool` | `Reversible` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTACameraFavoriteActionTests`, `ACTAPreparedCameraFavoriteActionTests` | `IMPLEMENTED — BROKER REVIEWED (PROCESS-LOCAL REVISION; USERDEFAULTS NOT CROSS-PROCESS ATOMIC)` |
| `camera.set_all_running` | Toolbar start/stop wall | `WallModel` | `running: Bool` | `ServiceAffecting` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.import_sources` | `CameraManager` import | `WallModel` | `file_path: String` | `ServiceAffecting` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED (CREDENTIALS DIRECT TO KEYCHAIN)` |
| `camera.snapshot` | Camera action bar | `WallModel` | `camera_id: UUID` | `ServiceAffecting` | **Broker review + destination** | `ACTASnapshotExportFoundationTests`, `ACTASnapshotActionTests`, `ACTASnapshotFrameProviderTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `camera.toggle_expand` | Video canvas double-click | `WallModel` | `camera_id: UUID` | `Reversible` | **Broker review** | `ACTAAnalyticsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.set_columns` | SystemSettings / Canvas | `WallModel` | `columns: Int (1...16)` | `Reversible` | **Broker review** | `ACTAAnalyticsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.get_state` | Camera view | `ACTACanvasFilterState` | `none` | `Inspect` | Scoped broker | `ACTAScopedCanvasStateActionTests` | `IMPLEMENTED — SCOPED READ` |
| `canvas.reset_layout` | Window menu / Toolbar | `WallModel` | `none` | `Reversible` | **Broker review** | `ACTAAnalyticsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.set_tile_frame` | Video canvas drag/resize | `ACTACanvasLayoutStore` | `camera_id, x, y, width, height` | `Reversible` | **Broker review** | `ACTACanvasTileFrameActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.set_filter` | Camera view | `ACTACanvasFilterState` | `search?, location?, status?, favorites_only?, events_only?` | `Reversible` | **Broker review** | `ACTACanvasFilterActionTests`, `ACTABrokerReviewViewTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.select_cameras` | Camera picker | `ACTACanvasFilterState` | `mode: all/none/subset, camera_ids?` | `Reversible` | **Broker review** | `ACTACanvasSelectCamerasActionTests`, `ACTABrokerReviewViewTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.set_arrange_mode` | Camera view menu | `ACTACanvasFilterState` | `enabled: Bool` | `Reversible` | **Broker review** | `ACTACanvasArrangeActionTests`, `ACTABrokerReviewViewTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `canvas.set_presentation` | Camera view grid/list picker | `ACTACanvasFilterState` | `mode: grid/list` | `Reversible` | **Broker review** | `ACTACanvasPresentationActionTests`, `ACTABrokerReviewViewTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `app.select_section` | Main sidebar navigation | `ACTANavigationBridge` | `section: enum (11 sections)` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category B: Video Analytics & Detection Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `analytics.get_settings` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id: UUID?` | `Inspect` | Scoped broker | `ACTAScopedAnalyticsSettingsActionTests`, `ACTAEngineAnalyticsSettingsReadProviderTests`, `ACTAWave1BCameraAnalyticsBrokerTests` | `IMPLEMENTED — SCOPED READ` |
| `analytics.set_global_toggle` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `feature: String, enabled: Bool` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_threshold` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `parameter: String, value: Double` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_sampling_fps` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `fps: Double, idle_fps: Double?, boost_fps: Double?` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_overlay` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `layer: String, enabled: Bool` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_camera_override` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id, field, value` | `Reversible` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTAPreparedCameraAnalyticsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id, name, x/y/width/height OR points_json` | `Reversible` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTAAnalyticsActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.remove_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id: UUID, name: String` | `Reversible` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTAAnalyticsActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_sensitivity_profile` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `profile: enum, apply_values: Bool?` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.remove_camera_override` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTAPreparedCameraAnalyticsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.update_restricted_zone` | `RestrictedZoneSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id, zone_id, new_name?, enabled?, hold_seconds?, severity?, point_*?` | `Reversible` | **Broker review** | `ACTAWave1BCameraAnalyticsBrokerTests`, `ACTAAnalyticsActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `analytics.set_execution_mode` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `mode: LOCAL / DISTRIBUTED` | `Reversible` | **Broker review** | `ACTAPreparedAnalyticsSettingsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category C: Safety Incidents & Alert Management

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `incident.list` | `SafetyIncidentCenterView` | `LocalVideoAnalyticsEngine` | `open_only: Bool?, limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAScopedIncidentListActionTests` | `IMPLEMENTED — SCOPED READ` |
| `incident.get` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID` | `Inspect` | Scoped broker | `ACTAScopedIncidentGetActionTests` | `IMPLEMENTED — SCOPED READ` |
| `incident.get_evidence_metadata` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ (PATHS/BYTES REDACTED)` |
| `incident.transition_status` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID, status: enum, note: String?` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `ACTAOperationalAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `incident.update_note` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID, note: String` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `ACTAIncidentNoteActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `incident.delete_evidence` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1FFullClosureTests`, `ACTAOperationalAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `alert.vlm_list` | Events / Timeline | `WallModel` | `unacknowledged_only: Bool?, limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAAlertReadActionsTests`, `ACTAOperationalAdapterTests` | `IMPLEMENTED — SCOPED READ` |
| `alert.list_review_history` | Events / Alert Detail | `WallModel` | `limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ (NOTES REDACTED)` |
| `alert.list_clips` | Events / Alert Clips | `WallModel` | `limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ (PATHS REDACTED)` |
| `alert.vlm_acknowledge` | Events / Alerts Queue | `WallModel` | `alert_id: UUID, acknowledged: Bool` | `Reversible` | **Broker review** | `ACTAAlertMutationActionsTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `alert.vlm_review` | Events / Alerts Queue | `WallModel` | `alert_id: UUID, status: String, priority: String?, note: String?` | `Reversible` | **Broker review** | `ACTAAlertMutationActionsTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `alert.clear_all` | Events / Alerts Queue | `WallModel` | `none` | `Destructive` | **Broker review (snapshot-bound)** | `ACTAWave1COperationsBrokerTests`, `ClearVLMAlertsTests`, `VLMAlertClearConfirmationTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category D: Identity Intelligence & ReID Tracking

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `identity.search_by_attributes` | Unified Chat / Identities | `ACTAAnalyticsCoordinator` | `upper_color?, vehicle_color?, sex?, kind?, query?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests`, `UnifiedAgentHistoryTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.get_dossier` | Unified Chat / Dossier | `ACTAAnalyticsCoordinator` | `identity_id: String` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.get_route` | Unified Chat / Topology | `ACTAAnalyticsCoordinator` | `identity_id: String` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.who_was_present` | Unified Chat / Timeline | `ACTAAnalyticsCoordinator` | `camera_id?, window_seconds?, kind?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.list_visits` | Unified Chat / Visits | `ACTAAnalyticsCoordinator` | `identity_id?, camera_id?, limit?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.find_companions` | Unified Chat / Network | `ACTAAnalyticsCoordinator` | `identity_id: String` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `identity.rename` | Identity Detail / Chat | `ACTAAnalyticsCoordinator` | `identity_id: String, new_name: String` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.merge` | Cross-Camera Identity | `ACTAAnalyticsCoordinator` | `source_id: String, target_id: String` | `Destructive` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.split` | Cross-Camera Identity | `ACTAAnalyticsCoordinator` | `identity_id: String, track_id: String` | `Destructive` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.set_follow_up` | Identity Detail | `ACTAIdentityFollowUpDomain` | `identity_id: String, follow_up: Bool` | `Reversible` | **Broker review** | `ACTAPreparedIdentityFollowUpActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.review_proposal` | Cross-Camera Identity | `CrossCameraIdentityReviewService` | `proposal_id: UUID, accept: Bool` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `CrossCameraIdentityReviewServiceTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.undo_merge` | Cross-Camera Identity | `CrossCameraIdentityReviewService` | `proposal_id: UUID` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `CrossCameraIdentityReviewServiceTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.delete_tracked_object`| `IdentityHistoryView` | `WallModel` / `LocalTrackingStore` | `track_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1FFullClosureTests`, `ACTATrackDeletionJournalTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.read_vehicle_plate` | `IdentityHistoryView` | `WallModel` / `VehicleTextReader` | `track_id: UUID` | `ServiceAffecting` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.clear_vehicle_plate` | `IdentityHistoryView` | `WallModel` / `LocalTrackingStore` | `track_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1FFullClosureTests`, `VehicleTextRemovalSafetyTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.group_tracks` | `IdentityHistoryView` | `WallModel` | `track_ids: CSV UUIDs (>=2)` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.detach_tracks` | `IdentityHistoryView` | `WallModel` | `track_ids: CSV UUIDs (>=1)` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.describe_track` | `IdentityHistoryView` | `WallModel` | `track_id: UUID` | `ServiceAffecting` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `identity.find_similar_tracks` | `IdentityHistoryView` | `WallModel` | `track_id: UUID` | `Inspect` | Scoped broker | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — SCOPED READ` |
| `reid.calibrate` | `ReIDCalibrationView` | `LocalTrackingStore` / `ReIDThresholdCalibrator` | `target_precision: number (0.90...1.0)` | `Inspect` | Scoped broker | `ACTAReIDCalibrationActionTests` | `IMPLEMENTED — SCOPED READ` |

---

### Category E: Scheduled Missions & Local Patrols

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `mission.list` | `CameraMissionsPanel` | `WallModel` | `none` | `Inspect` | Scoped broker | `ACTAScopedMissionListActionTests` | `IMPLEMENTED — SCOPED READ` |
| `mission.create` | `CameraMissionsPanel` | `WallModel` | `camera_id, name, brief, interval_seconds?, schedule_kind?, clock_times?, weekdays?, time_zone?, enabled?` | `Reversible` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAMissionActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `mission.edit` | `CameraMissionsPanel` | `WallModel` | `mission_id, camera_id?, name?, brief?, interval_seconds?, schedule_kind?, clock_times?, weekdays?, time_zone?, enabled?` | `Reversible` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAMissionActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `mission.delete` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAMissionActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `mission.run_now` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `ServiceAffecting` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAScopedMissionListActionTests` | `IMPLEMENTED — BROKER REVIEWED (COORDINATED LOCAL LEASE)` |
| `mission.history` | `CameraMissionsPanel` | `WallModel` / `CameraMissionStore` | `mission_id: UUID, limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAScopedMissionListActionTests` | `IMPLEMENTED — SCOPED READ` |
| `mission.ask_consult` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID, question: String (<=2000)` | `ServiceAffecting` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAMissionActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `mission.clear_consult` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `Destructive` | **Broker review** | `ACTAWave1COperationsBrokerTests`, `ACTAMissionActionAdapterTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `mission.export_pdf` | `CameraMissionsPanel` / Reports | `WallModel` | Operator destination + preview | `ServiceAffecting` | **Broker review + destination** | `ACTACreateOnlyExportTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category F: Chronological Memory & Narrative Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `memory.list_frames` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `camera_id?, since?, until?, limit?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `memory.view_frame` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `frame_id: String` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `memory.delete_frame` | `CameraMemoryView` | `WallModel` | `frame_id: UUID` | `Destructive` | **Broker review** | `ACTAOperationalAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.clear_all_frames` | `CameraMemoryView` | `WallModel` / `ACTAWallCameraMemoryClearBackend` | `none` | `Destructive` | **Broker review (snapshot-bound)** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `ACTACameraMemoryClearActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.resume_frame_deletion` | `CameraMemoryView` | `WallModel` / `ACTAWallCameraMemoryRecoveryBackend` | `none` | `Destructive` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `ACTACameraMemoryRecoveryActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.list_chapters` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `camera_id?, pinned_only?, limit?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `memory.get_chapter` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `chapter_id: String` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `memory.set_chapter_text` | `CameraMemoryView` | `WallModel` | `chapter_id: String, text: String? (<=16000), clear: Bool?` | `Reversible` | **Broker review** | `ACTAAnalyticsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.toggle_pin` | `CameraMemoryView` | shared narrative presentation state | `chapter_id: UUID, pinned: Bool` | `Reversible` | **Broker review** | `ACTAPreparedNarrativePinActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.close_chapter_now` | `CameraMemoryView` | `WallModel` | `camera_id: UUID` | `ServiceAffecting` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `ACTANarrativeCloseJournalTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `memory.rebuild_knowledge` | `CameraMemoryView` | `WallModel` | `none` | `ServiceAffecting` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `description_jobs.inspect` | `VLMPanel` / Description jobs | `ACTAWallDescriptionJobBackend` | `limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAWave1DMemoryIdentityChatBrokerTests`, `ACTADescriptionJobActionsTests` | `IMPLEMENTED — SCOPED READ` |
| `description_jobs.retry` | `VLMPanel` / Description jobs | `ACTAWallDescriptionJobBackend` | `job_id: UUID` | `ServiceAffecting` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `ACTADescriptionJobActionsTests` | `IMPLEMENTED — BROKER REVIEWED` |

`ACTAPreparedNarrativePinAction(domain:)` is an unregistered foundation, not a
`WallModel` adapter. It permits pinning only already operator-marked chapters;
the existing GUI pin operation can additionally set `operator_marked`. Its
domain must atomically compare a never-reused revision and the complete reviewed
state against **all** GUI, legacy and cross-process writers, and change only the
pin. The fake-domain tests do not establish that the real store meets this
contract, nor do readbacks prove crash durability. Identity mutations and
irreversible memory operations remain unavailable through this foundation.

#### `memory.toggle_pin`: minimal integration boundary (not applied)

`ACTANarrativePinCoordinatedDomain(store:refresh:)` now supplies the
MainActor-side reentrancy gate, post-commit refresh/readback and fail-closed
reconciliation. It does **not** make an unrevisioned store safe. No instance
is created by `WallModel`, no schema is migrated, and this action is not in the
production broker.

The smallest safe integration requires **all** of the following, not merely
registering the action:

1. Add an explicitly approved, transactional schema upgrade to
   `LocalTrackingStore`, never a silent migration. It must install a durable
   database generation and a non-wrapping global chapter revision. SQLite
   triggers must advance it on every `ghost_narrative_chapters` INSERT, UPDATE
   and DELETE, including UPSERT, replacement, no-op updates and delete/recreate.
   Overflow, missing/modified triggers, unexpected schemas or incomplete upgrade
   must disable the action. All schema-changing writers must be controlled;
   checking the triggers only at review/commit cannot detect their temporary
   removal and restoration. SQLite locks alone do not protect database/WAL path
   replacement, rollback to an older copy or noncooperating filesystem writers.
   Do not enable until an independently verified ownership/coordination boundary
   excludes those cases for all processes and recovery paths.
2. With the existing private `database` and `lock` in `LocalTrackingStore`,
   expose these exact operations through a CameraCore-owned public observation
   type with the fields of `ACTANarrativePinObservation`:

   ```swift
   func captureReviewedNarrativePin(chapterID: UUID) throws -> NarrativePinObservation?
   func commitReviewedNarrativePin(chapterID: UUID, expected: NarrativePinObservation,
                                   pinned: Bool) throws -> NarrativePinObservation?
   ```

   Capture obtains the generation/revision and *all* stored chapter fields in
   one consistent SQLite snapshot. Commit holds the store lock and `BEGIN
   IMMEDIATE`, validates the schema and authorization, compares the full
   observation and global revision, updates **only** `pinned`, reads back the
   complete row and new revision, then commits. A mismatch returns `nil` without
   a write; a commit error has unknown outcome. Recheck the authorized camera
   scope inside that same transaction. The pin operation must refuse pinning an
   unmarked chapter, since the current GUI operation also sets
   `operator_marked`. Preserve SQLite types and exact bytes, including NULL and
   embedded NUL; decoded/re-encoded JSON or a hash is not an exact comparison.
3. Implement `ACTANarrativePinAtomicStore` as a small adapter around those two
   methods, mapping the generation and counter losslessly to
   `ACTANarrativePinRevision`. Do not retain or
   expose the private SQLite handle. Ensure every GUI, analytics, journal and
   legacy SQL writer is covered by the triggers, and that direct schema/file
   replacement is excluded as above. The existing direct SQL paths include
   `IdentityTracking.swift` and `ACTANarrativeCloseJournal.swift`.
4. Replace `WallModel`'s `@Published actaNarrativeChapters` with one
   reentrancy-safe snapshot publisher. Route its initialization and all four
   later assignments (periodic refresh, pin, text, force-close refresh) through
   that publisher; `@Published`'s will-set callback permits an inner write to be
   overwritten by the outer assignment. The `refresh` closure passed to the
   coordinator must load and publish the complete list, without writes to the
   store, and throw if it cannot prove the publication corresponds to a stable
   global revision. Merely assigning the existing `@Published` property is not
   an implementation of this requirement.
5. Only after these prerequisites and scoped chapter authorization exist, keep
   one coordinator and one `ACTAPreparedNarrativePinAction(domain:)` per broker
   lifetime and register exactly `memory.toggle_pin`. On commit/presentation
   failure, leave it unavailable until `reconcile(chapterID:)` succeeds; do not
   automatically retry a possibly committed operation. A broker review must
   identify the chapter sufficiently for the operator through trusted UI without
   putting narrative text or other sensitive values in the review summary.

The coordinator has only fake-store tests. It cannot prove the required SQLite,
filesystem, schema, GUI, authorization or crash-durability guarantees.

---

### Category G: Watch Rules & Operational Monitoring

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `watch.list` | EventsSettings / WatchRules | `WallModel` | `none` | `Inspect` | Scoped broker | `ACTAOperationsWatchReadProviderTests`, `ACTAScopedWatchListActionTests` | `IMPLEMENTED — SCOPED READ` |
| `watch.create` | EventsSettings / WatchRules | `WallModel` | `text: String, camera_ids?, ttl_minutes?, forever?` | `Reversible` | **Broker review** | `ACTAOperationalAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `watch.cancel` | EventsSettings / WatchRules | `WallModel` | `watch_id: UUID` | `Reversible` | **Broker review** | `ACTAOperationalAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `monitor.get_isapi_events` | `ISAPIEventMonitor` | `WallModel` | `limit: Int? (1...50)` | `Inspect` | Scoped broker | `ACTAISAPIReadActionsTests`, `ACTAOperationalAdapterTests` | `IMPLEMENTED — SCOPED READ` |
| `monitor.clear_isapi_events`| `ISAPIEventMonitor` | `WallModel` | `none` | `Destructive` | **Broker review (snapshot-bound)** | `ACTAWave1COperationsBrokerTests`, `ACTAClearISAPIEventsActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `monitor.get_operational_events`| Unified Timeline | `ACTAAnalyticsCoordinator` | `camera_id?, kind?, limit?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `monitor.live_look` | Unified Chat | `ACTAAnalyticsCoordinator` | `camera: String?` | `Inspect` | Scoped legacy tool | `ACTAScopedInspectionTests` | `IMPLEMENTED — SCOPED READ` |
| `monitor.export_report_html`| Reports | Mission panel / prepared action | Operator destination + preview | `ServiceAffecting` | **Broker review + destination** | `ACTAMissionHTMLExportTests`, `ACTACreateOnlyExportTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category H: SettingsHub (All 14 Sections)

| Action ID | UI Section / Key | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `settings.select_section` | `SettingsHubView` navigation | `ACTANavigationBridge` | `section: enum (all 14 sections)` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.get_section` | SettingsHub sections | `WallSettingsAction` / `WallModel` | `section: enum` | `Inspect` | Scoped broker | `ACTAWallModelSettingsReadProviderTests`, `ACTAScopedSettingsReadActionTests`, `ACTAWave1ASettingsBrokerTests` | `IMPLEMENTED — SCOPED READ` |
| `settings.update_system` | Sec 1: General & Streams | `WallModel` / `LanguageSettings` | `language: en/ru` OR `columns?, stale_after_ms?, detection_threshold?, detection_fps?` | `Reversible` | **Broker review** | `ACTAWave1ASettingsBrokerTests`, `ACTAReviewedLanguageActionTests`, `ACTASystemPortActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_models` | Sec 3: AI Models | `WallModel` | `service: enum, enabled?, custom_path?, clear_custom_path?` | `ServiceAffecting` | **Broker review** | `ACTAWave1ASettingsBrokerTests`, `SelectedModelFileIdentityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_runtime_fall` | Sec 4: Advanced Runtime | `WallModel.saveRuntimePreferences` | 22 advanced fall GUI fields | `ServiceAffecting` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_runtime_storage` | Sec 4: Storage Cleanup | `WallModel.saveRuntimePreferences` | `maxMediaDiskMB?, minFreeDiskGB?, maxCropsPerIdentity?, dataSaverEnabled?, trackImageRetentionDays?, logRetentionDays?` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_runtime_crop` | Sec 4: Crop Selection | `WallModel.saveRuntimePreferences` | 6 capture scheduler + 3 crop fields | `ServiceAffecting` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_ai_config` | Sec 6: AI Backends | `WallModel.saveVLMPreferences` | `language: ru/en/he` | `SecuritySensitive` | **Broker review** | `ACTAAIConfigActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_ai_budget` | Sec 6: Cloud Privacy & Budget | `WallModel.saveVLMPreferences` | `blurFaces?, blurPlates?, dailyBudgetUSD?, monthlyBudgetUSD?` | `SecuritySensitive` | **Broker review** | `ACTAAIBudgetActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.set_api_key` | Sec 6: Keychain Credentials | `ACTAAPIKeyStore` (`CameraWall.GhostCredentials`) | `account: primary/alert` (secret via native `NSSecureTextField` post-approval) | `SecuritySensitive` | **Broker review (zero-secret args)** | `ACTAWave1ASettingsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED (SECRET NEVER IN LLM/AUDIT)` |
| `settings.clear_api_key` | Sec 6: Keychain Credentials | `ACTAAPIKeyStore` (`CameraWall.GhostCredentials`) | `account: primary/alert` | `Destructive` | **Broker review** | `ACTAWave1ASettingsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_schedules` | Sec 7: Scheduled Analysis | `WallModel.saveVLMPreferences` | `scheduleEnabled?, intervalSeconds?, analyzeAllEnabledCameras?, camera_ids?` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_events_alerts` | Sec 9: Events & Alerts | `WallModel.saveOperationsPreferences` | `personCountAlertsEnabled?, personThreshold?, holdSeconds?, cooldownSeconds?, criticalSoundEnabled?` | `Reversible` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_memory_policy` | Sec 10: Memory & Storage | `WallModel.saveFeaturePolicy` | `retainFullFrames?, retentionDays?` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.save_alert_rule` | Sec 7: Alert Rules | `WallModel.saveVLMPreferences` | `rule_id?, condition?, enabled?, cooldownSeconds?, priority?` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.remove_alert_rule` | Sec 7: Alert Rules | `WallModel.saveVLMPreferences` | `rule_id: UUID` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_feature_toggles`| Sec 11: Features & Access | `WallModel` | `feature: String, enabled: Bool` | `Reversible` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_permissions` | Sec 11: Features & Access | `WallModel` | `allowExternalAI?, allowVoiceInput?, allowPlateRegistryLookup?` | `SecuritySensitive` | **Broker review** | `ACTASettingsActionAdapterTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.toggle_showcase` | Sec 12: Local Showcase | `WallModel` | `running: Bool` (loopback `127.0.0.1` only; token withheld) | `ServiceAffecting` | **Broker review** | `ACTAWave1ASettingsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.update_reid_calibration` | Sec 13: ReID Calibration | `ReIDCalibrationView` | `target_precision: number (0.90...1.0, step 0.005)` | `Reversible` | **Broker review** | `ACTAReIDCalibrationActionTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.export_diagnostics` | Sec 14: System Diagnostics | `WallModel` | Operator destination + preview | `ServiceAffecting` | **Broker review + destination** | `ACTACreateOnlyExportTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.run_health_check` | Sec 14: System Diagnostics | `WallModel` | `none` | `ServiceAffecting` | **Broker review** | `ACTARunHealthCheckActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.reload_models` | Sec 14: System Diagnostics | `WallModel` | `none` | `ServiceAffecting` | **Broker review** | `ACTAWave1ASettingsBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `settings.retry_model_loading` | Model status strip / Retry | `LocalModelRuntime` | `none` | `ServiceAffecting` | **Broker review** | `ACTARetryModelLoadingActionTests`, `ACTAPhase1FullParityTests` | `IMPLEMENTED — BROKER REVIEWED` |

---

### Category I: Local Voice, Speech, Chat & Orchestration

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `analysis.set_section` | Analysis panel tabs | `ACTACanvasFilterState` | `section: chat/schedule/alerts` | `Reversible` | **Broker review** | `ACTAAnalysisSectionActionTests`, `ACTABrokerReviewViewTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `chat.select_thread` | Unified Chat threads | `WallModel` | `thread_id: String` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `chat.new_thread` | Unified Chat threads | `WallModel` | `title: String?` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `chat.cancel_request` | Unified Chat cancel | `WallModel` | `none` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.start_listening` | Mic Button / Push-to-Talk | `ACTAVoiceControlAction` / `LocalVoiceInput` | `locale: String?` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `LocalVoiceInputLifecycleTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.stop_listening` | Mic Button Release | `ACTAVoiceControlAction` / `LocalVoiceInput` | `none` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `LocalVoiceInputLifecycleTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.cancel_listening` | Chat cancel / Escape | `ACTAVoiceControlAction` / `LocalVoiceInput` | `none` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `LocalVoiceInputLifecycleTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.set_dictation_language` | Chat dictation language menu | `ACTANavigationBridge` / `VLMPanel` | `language: interface/en-US/ru-RU/he-IL` | `Reversible` | **Broker review** | `ACTAWave1FFullClosureTests`, `LocalVoiceLanguageTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.speak_text` | Agent Spoken Response | `ACTAVoiceControlAction` / `LocalVoiceOutput` | `text: String, language: String?` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `LocalVoiceOutputTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `voice.stop_speaking` | Interruption / Barge-in | `ACTAVoiceControlAction` / `LocalVoiceOutput` | `none` | `Reversible` | **Broker review** | `ACTAWave1DMemoryIdentityChatBrokerTests`, `LocalVoiceOutputTests` | `IMPLEMENTED — BROKER REVIEWED` |
| `agent.request_confirmation`| Trusted review host | `ACTALocalActionBroker` | Internal host flow only | `Inspect` | Trusted host only | `ACTAWave1FFullClosureTests`, `ACTABrokerReviewAuthorizationTests` | `EXCLUDED — APPROVED (UNSUPPORTED FOR MODEL; TRUSTED HOST ONLY)` |
| `agent.resolve_confirmation` | Trusted review / operator voice or click | `ACTABrokerReviewController` | Operator UI / exact phrase + one-time code | `Reversible` | Operator review only | `ACTAWave1FFullClosureTests`, `ACTABrokerReviewAuthorizationTests` | `EXCLUDED — APPROVED (UNSUPPORTED FOR MODEL; PREVENTS SELF-APPROVAL)` |

---

## 4. Prior Audit Gaps — Design Targets, Not Completion Evidence

1. **Action discovery:** A registry execution branch exists, but the local model still receives the old tool catalogue. End-to-end discovery and execution are pending.
2. **Voice:** On-device ASR and reviewed push-to-talk confirmation exist. Cancelling a completed transcript before broker submission invalidates it, and recognition errors take precedence over a simultaneous final result. Revocation after broker processing begins does not guarantee cancellation. A separate test process reported on-device support for en-US and ru-RU, but not he-IL; its permissions do not establish the app's permissions. Completed chat answers and voice-confirmed action status with operation UUID can be spoken through separately installed eSpeak NG, with local network-denied execution, a stop control and per-window ownership. Voice questions can trigger automatic speech; partial streaming drafts are never spoken. A shared lease excludes voice capture and playback in cooperating app instances; the speech child inherits a read-only lock descriptor so it can retain the lease after the parent releases its copy. This was tested with real eSpeak without playback and with synthetic parent termination, not by crashing the app. Older versions and other apps do not cooperate. Synthetic lifecycle, cross-process exclusion, network-denial and silent synthesis tests pass; the chat was type-checked and rendered with stubs. A synthetic playback command exited successfully, but audibility, microphone and full GUI remain unverified.
3. **vLLM Metal:** Existing HTTP requests are not proof of a Metal plugin integration. Plugin version, exact checkpoint, streaming, concurrency and hardware benchmarks remain pending.
4. **Verification:** Partial verification exists. It does not establish full GUI parity or persistent audit coverage.

## 5. Phase 1 safety correction — 2026-11-17

This is a partial implementation update, not completion of Phase 1.

- Disconnected incident, memory and watch adapters return `UNSUPPORTED`, never fabricated successful mutations or fabricated empty query results.
- Analytics adapters without a provider return `UNSUPPORTED`; camera-specific overrides are not represented as global settings.
- `settings.get_section` returns `UNSUPPORTED` for sections it does not implement.
- `settings.update_permissions` is security-sensitive and requires operator confirmation at the registry gate.
- Registry rejects unknown/missing required arguments, invalid primitive types, non-finite numbers and values outside declared enums before execution.
- Verification covers all implemented analytics switches and all permission fields.
- Diagnostic JSON is encoded safely; confirmation summaries redact potentially secret argument values.

Selected table states are updated conservatively below the full-parity threshold. Test names in the original baseline column remain planned acceptance tests unless an actual test is named in IMPLEMENTATION_REPORT.md. All other rows remain baseline planning states.

### Live service and agent integration

- Runtime registration now supplies MainActor providers backed by the same `WallModel`/analytics service methods as GUI settings. Integration tests verify live state and files in temporary stores.
- Eleven implemented actions are advertised to the agent with `acta__...` transport aliases. Local inference has at most four round trips. Disconnected actions are not advertised.
- Confirmation tokens are persisted as operator proposals; UI approval resolves the token and claims the durable proposal before awaiting execution.
- A scripted local HTTP test proves catalogue → tool call → real temporary service mutation → verified output. Actual Qwen model behaviour and GUI interactions remain unverified.
- Concurrent registry writes return `ACTION_BUSY`; mutation verification defaults to failure unless explicitly implemented. Token expiry and replay are tested.

Protected feature switches (`publicShowcase`, `accessControl`, `independentWatcher`, `chronologicalMemory`, `crossCameraIdentity`, `plateRecognition`, `operatorActions`) require explicit confirmation. General feature switches retain their reversible policy.

## Phase 1 operational services checkpoint

Runtime registration wraps the existing incident/watch/memory action specifications in
`WallOperationalAction`, calling the same domain methods as GUI controls. The default
unconnected core specifications still fail with UNSUPPORTED when used alone.

Seven additional runtime actions are advertised (18 total): incident.list,
incident.transition_status, incident.delete_evidence, watch.list, watch.create,
watch.cancel, memory.delete_frame. Incident query text and custom suppression duration
are not implemented and are not accepted in the runtime schema. Destructive deletion
requires a token; marking an incident false-positive also requires confirmation.

Tests use temporary configuration, SQLite, watch files and physical memory/evidence
files. Corrupt watch storage is preserved on error, invalid camera UUID/TTL is rejected,
and disabled operationalAlerts blocks watch operations. memory.clear_all_frames remains
UNSUPPORTED and is not advertised. Read IMPLEMENTATION_REPORT.md for commands/results.

## Phase 1 analytics/canvas checkpoint

The advertised catalogue now contains 26 actions. Six previously planned analytics
mutations and two canvas actions were added to the model catalogue. Global analytics
flags cover all 15 UI switches, overlays cover all eight UI layers, and set_threshold
covers all 12 advanced numeric settings. Evidence recording and evidence buffer/quota
changes require operator confirmation. Invalid arguments are rejected before writing;
service clamping is not represented as exact execution of a different requested value.

Camera-specific reads include the stored override and complete effective configuration.
set_camera_override currently changes enabled/FPS/inherit only. Restricted-zone edits
currently support rectangles by unique name and preserve existing ID, enabled state,
hold time and severity; polygon/policy editing is still absent. Profile selection,
execution-mode changes, removal of an entire override, and remaining per-camera detector
fields still require inventory rows/implementation. This checkpoint does not establish
complete GUI control coverage.

Canvas expand verifies selection only; it does not certify live stream switching.
Layout reset verifies both runtime state and the persisted layout file, including a
negative test for a failed save. Read IMPLEMENTATION_REPORT.md for validation evidence.

## Phase 1 profiles, complete camera overrides and narrative annotations

The catalogue now contains 31 actions. All global sensitivity profile selections and
preset applications, all nine additional per-camera detector flags, per-camera profile,
custom FPS/cooldown and clearing those custom values are implemented and tested.
Complete override removal requires confirmation. Zone UUID editing supports rename,
enabled, hold time, severity and individual polygon point move/append/remove operations
with 3...64 point limits. Rectangle creation remains a separate existing action.

Narrative pin/text actions share checked GUI methods, read back SQLite, preserve the
original AI summary and require review before creating operator attribution. Pin is a
desired state, so repeated approved pin=true never toggles it back off. Missing/conflicting
text arguments are rejected; clear=true explicitly clears a note. execution_mode remains
a documented gap; no distributed resources were modified. Full GUI coverage is not claimed.

## Phase 1 mission actions checkpoint

The catalogue now contains 39 actions. Mission CRUD uses the same GUI services and an
injectable store URL with the unchanged default. Read/write consistency checks reject
corrupt JSON and runtime/disk mismatches before mutation; this is not a cross-process
file lock. Interval and clock schedules are validated, clock creation requires an
explicit IANA time zone, and mission edits preserve run/consult history.

Delete and clear_consult require confirmation and preserve saved run summaries.
mission.history supports retained runs after mission deletion and emits stable source
IDs for the shared evidence ledger, distinguishing mission runs from consult questions
and responses. run_now verifies only queued/running admission, never completion; its
one-slot queue is in memory and cleared by disconnect/restart. ask_consult persists the
question and returns admission only; the local response is read later from history.

Tests use temporary mission stores and a scripted consult responder. No real camera
mission, Qwen inference or hardware throughput is claimed. Active mission execution
inputs are compared before committing a result; changes invalidate the old request.
Existing JSON version/migration paths and production defaults remain unchanged.

## Phase 1 camera configuration checkpoint

The catalogue now contains 45 actions. Source registration always starts DISABLED and
returns configured=true/connection_verified=false. Local/display IDs and file bookmarks
are persisted without claiming hardware availability, permissions or decoder readiness.
New network registrations accept anonymous URLs without query/fragment/credentials;
secure credential entry, credential-bearing URLs and discovery stay in the existing
native GUI workflow. Moving existing stored credentials to a different scheme/host/port
is blocked in the agent edit path, even after approval; use the secure editor instead.

Metadata edits and YOLO/AI flags share GUI services; enabling a source and AI flag/URL
changes require review. Config/disk checks reject corrupt/stale snapshots before writes.
Camera removal verifies both configuration and credential deletion through the injected
store and attempts credential compensation when config commit fails. Tests use a fake
credential store, not the user's live Keychain. The System store retains CameraWall.RTSP
and UUID account identifiers; live Keychain failure/recovery still needs runtime QA.

The registry now calls action-specific validation before generating confirmation tokens.
Malformed/secret-bearing URLs and oversized/conflicting narrative annotations cannot
become durable approval proposals. Camera get/not-found errors do not echo supplied URLs.
ISAPI editing, capture snapshot, stream-recovery verification and secure voice/text
credential provisioning remain gaps. No complete camera GUI parity is claimed.

### Settings checkpoint — 2026-11-17

Catalogue: 53 actions. Eight mutations added through existing GUI domain services;
settings inspection expanded with URL redaction and explicit unsupported identity section.
Runtime, feature, operations and AI stores reject stale/corrupt on-disk state before writes.
Temporary-store tests cover all 22 advanced fall GUI fields, nine crop fields, six storage
fields, five event fields, memory policy, schedule selection and alert-rule lifecycle.
This does not establish exhaustive GUI parity, real inference, janitor execution or model readiness.

### Incident inspection checkpoint

The catalogue now advertises 54 actions. `incident.get` reads minimal metadata from
the same incident manager used by the GUI; it excludes free-form text and evidence paths.
Invalid IDs, absent incidents, unavailable providers and storage errors are distinguished.
Synthetic and temporary-storage tests cover discovery, real domain-service integration,
redaction and corrupt incident storage. GUI detail parity and real Qwen remain unverified.

### Alert and ISAPI inspection checkpoint

`alert.vlm_list` and `monitor.get_isapi_events` expose minimal metadata through
read-only snapshots. The actions require successful initial loading and agreement
between GUI state and persisted sources; missing files and inconsistencies fail closed.
Alerts additionally require an enabled, already-open review store. Failed initialization
or tracked save errors remain unavailable until restart; a successful enable can establish
review state only if there was no prior error. A missing history file is not treated as an
empty first launch. ISAPI applies the same retention to the persisted and GUI snapshots
before comparing them. Source reads do not purge or save; agent tool audit still writes
as before. Alert comparison includes retained GUI entries until the normal GUI cleanup
runs; changing retention alone does not silently alter the GUI snapshot. No cross-process
atomicity, live cameras, real Qwen, complete
GUI detail parity or automatic recovery is claimed.
