# ACTA: GUI to Agent Functional Coverage Matrix

Date: 2026-11-17  
Target: Native Swift/macOS ACTA Application (`alexghost82/multicamera`)  
Version: 1.0.0-baseline  

---

## 1. Executive Summary

This inventory maps **every existing user-accessible SwiftUI control, persistent setting, and domain service operation** in ACTA to a typed agent action specification.

- **Action rows in this baseline:** 97 (the previous claim of 108 was not supported by the table; exhaustive UI coverage remains unverified)
- **Existing Agent Tools in Code:** 16 read-only query tools + 1 terminal tool (`present_answer`)
- **Existing Agent Mutations in Code:** 3 (`rename_identity`, `merge_identities`, `split_identity`)
- **Uncovered Operations Prior to Audit:** 89 (82.4% gap across Camera lifecycle, Layout, Analytics toggles/thresholds, Incident management, Missions, Watch rules, SettingsHub, and Local Voice TTS)

---

## 2. Policy & Safety Classifications

- **`Inspect`**: Read-only query, does not mutate application state or disk. **Auto-authorized.**
- **`Reversible`**: Mutates runtime state or preferences with straightforward rollback (e.g., column count, threshold, feature toggle, acknowledging an alert). **Auto-authorized or single-turn notice.**
- **`ServiceAffecting`**: Disrupts active video streams, network connections, or reloads models (e.g., camera reconnect, model engine switch, go2rtc restart). **Requires explicit status notice.**
- **`Destructive`**: Permanently removes data, deletes cameras, deletes evidence, or merges identity profiles. **Requires explicit two-phase operator confirmation.**

---

## 3. Comprehensive Coverage Matrix

### Category A: Camera Management & Video Canvas

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `camera.list` | `WallView` / `CameraManager` | `WallModel` | `includeDisabled: Bool?` | `Inspect` | Auto | `testCameraList` | `PARTIAL — NO PARITY TEST` |
| `camera.get` | `CameraEditor` | `WallModel` | `cameraID: String` | `Inspect` | Auto | `testCameraGet` | `PARTIAL — NO PARITY TEST` |
| `camera.add_network` | `CameraEditor` sheet | `WallModel` | `name: String, url: String, substream: String?, username: String?, password: String?` | `Reversible` | Auto | `testCameraAddNetwork` | `PLANNED` |
| `camera.add_local` | `LocalCameraEditor` sheet | `WallModel` | `deviceID: String, name: String` | `Reversible` | Auto | `testCameraAddLocal` | `PLANNED` |
| `camera.add_screen` | `ScreenCaptureCameraEditor` | `WallModel` | `displayID: UInt32, name: String` | `Reversible` | Auto | `testCameraAddScreen` | `PLANNED` |
| `camera.add_file` | `VideoFileCameraEditor` | `WallModel` | `filePath: String, name: String?` | `Reversible` | Auto | `testCameraAddFile` | `PLANNED` |
| `camera.edit` | `CameraEditor` sheet | `WallModel` | `cameraID: String, name: String?, url: String?, substream: String?, enabled: Bool?` | `Reversible` | Auto | `testCameraEdit` | `PLANNED` |
| `camera.set_enabled` | `CameraManager` toggle | `WallModel` | `cameraID: String, enabled: Bool` | `Reversible` | Auto | `testCameraSetEnabled` | `PARTIAL — NO PARITY TEST` |
| `camera.remove` | `WallView` remove alert | `WallModel` | `cameraID: String` | `Destructive` | **Confirm** | `testCameraRemove` | `PARTIAL — NO PARITY TEST` |
| `camera.reconnect` | Camera context menu | `WallModel` | `cameraID: String` | `ServiceAffecting` | Auto | `testCameraReconnect` | `PLANNED` |
| `camera.snapshot` | Camera action bar | `WallModel` | `cameraID: String` | `Inspect` | Auto | `testCameraSnapshot` | `PLANNED` |
| `camera.toggle_expand` | Video canvas double-click | `WallModel` | `cameraID: String` | `Reversible` | Auto | `testCameraToggleExpand` | `PLANNED` |
| `canvas.set_columns` | SystemSettings / Canvas | `WallModel` | `columns: Int (1...16)` | `Reversible` | Auto | `testCanvasSetColumns` | `IMPLEMENTED — SERVICE TEST` |
| `canvas.reset_layout` | Window menu / Toolbar | `WallModel` | `none` | `Reversible` | Auto | `testCanvasResetLayout` | `PLANNED` |

---

### Category B: Video Analytics & Detection Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `analytics.get_settings` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String?` | `Inspect` | Auto | `testAnalyticsGetSettings` | `PARTIAL — GLOBAL SETTINGS ONLY` |
| `analytics.set_global_toggle` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `feature: String, enabled: Bool` | `Reversible` | Auto | `testAnalyticsSetGlobalToggle` | `PARTIAL — LIVE PROVIDER / FALL TEST` |
| `analytics.set_threshold` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `parameter: String, value: Double` | `Reversible` | Auto | `testAnalyticsSetThreshold` | `PLANNED` |
| `analytics.set_sampling_fps` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `fps: Double, idleFPS: Double?, boostFPS: Double?` | `Reversible` | Auto | `testAnalyticsSetSamplingFPS` | `PLANNED` |
| `analytics.set_overlay` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `layer: String, enabled: Bool` | `Reversible` | Auto | `testAnalyticsSetOverlay` | `PLANNED` |
| `analytics.set_camera_override` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String, enabled: Bool?, fps: Double?, inherit: Bool?` | `Reversible` | Auto | `testAnalyticsSetCameraOverride` | `PLANNED` |
| `analytics.set_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String, name: String, x: Double, y: Double, width: Double, height: Double` | `Reversible` | Auto | `testAnalyticsSetRestrictedZone` | `PLANNED` |
| `analytics.remove_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String, name: String` | `Reversible` | Auto | `testAnalyticsRemoveZone` | `PLANNED` |

---

### Category C: Safety Incidents & Alert Management

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `incident.list` | `SafetyIncidentCenterView` | `LocalVideoAnalyticsEngine` | `openOnly: Bool?, cameraID: String?, query: String?, limit: Int?` | `Inspect` | Auto | `testIncidentList` | `PLANNED` |
| `incident.get` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incidentID: String` | `Inspect` | Auto | `testIncidentGet` | `PLANNED` |
| `incident.transition_status` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incidentID: String, status: String ("acknowledged", "confirmed", "resolved", "false_positive", "suppressed", "active"), note: String?, suppressDurationSec: Int?` | `Reversible` | Auto (Confirm for `false_positive`) | `testIncidentTransition` | `PLANNED` |
| `incident.update_note` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incidentID: String, note: String` | `Reversible` | Auto | `testIncidentUpdateNote` | `PLANNED` |
| `incident.delete_evidence` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incidentID: String` | `Destructive` | **Confirm** | `testIncidentDeleteEvidence` | `PLANNED` |
| `alert.vlm_list` | Events / Timeline | `WallModel` | `cameraID: String?, unacknowledgedOnly: Bool?` | `Inspect` | Auto | `testAlertVLMList` | `PLANNED` |
| `alert.vlm_acknowledge` | Events / Alerts Queue | `WallModel` | `alertID: String, acknowledged: Bool` | `Reversible` | Auto | `testAlertVLMAcknowledge` | `PLANNED` |
| `alert.vlm_review` | Events / Alerts Queue | `WallModel` | `alertID: String, status: String, priority: String?, note: String?` | `Reversible` | Auto | `testAlertVLMReview` | `PLANNED` |
| `alert.clear_all` | Events / Alerts Queue | `WallModel` | `none` | `Destructive` | **Confirm** | `testAlertClearAll` | `PLANNED` |

---

### Category D: Identity Intelligence & ReID Tracking

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `identity.search_by_attributes` | Unified Chat / Identities | `ACTAAnalyticsCoordinator` | `upper_color: String?, vehicle_color: String?, sex: String?, kind: String?, query: String?` | `Inspect` | Auto | `testIdentitySearch` | `EXISTING` |
| `identity.get_dossier` | Unified Chat / Dossier | `ACTAAnalyticsCoordinator` | `identityID: String` | `Inspect` | Auto | `testIdentityGetDossier` | `EXISTING` |
| `identity.get_route` | Unified Chat / Topology | `ACTAAnalyticsCoordinator` | `identityID: String` | `Inspect` | Auto | `testIdentityGetRoute` | `EXISTING` |
| `identity.who_was_present` | Unified Chat / Timeline | `ACTAAnalyticsCoordinator` | `cameraID: String?, windowSeconds: Double?, kind: String?` | `Inspect` | Auto | `testIdentityWhoWasPresent` | `EXISTING` |
| `identity.list_visits` | Unified Chat / Visits | `ACTAAnalyticsCoordinator` | `identityID: String?, cameraID: String?, limit: Int?` | `Inspect` | Auto | `testIdentityListVisits` | `EXISTING` |
| `identity.find_companions` | Unified Chat / Network | `ACTAAnalyticsCoordinator` | `identityID: String` | `Inspect` | Auto | `testIdentityFindCompanions` | `EXISTING` |
| `identity.rename` | Identity Detail / Chat | `ACTAAnalyticsCoordinator` | `identityID: String, newName: String` | `Reversible` | Auto | `testIdentityRename` | `EXISTING` |
| `identity.merge` | Cross-Camera Identity | `ACTAAnalyticsCoordinator` | `sourceID: String, targetID: String` | `Destructive` | **Confirm** | `testIdentityMerge` | `EXISTING` |
| `identity.split` | Cross-Camera Identity | `ACTAAnalyticsCoordinator` | `identityID: String, trackID: String` | `Destructive` | **Confirm** | `testIdentitySplit` | `EXISTING` |
| `identity.review_proposal` | Cross-Camera Identity | `WallModel` | `proposalID: String, accept: Bool` | `Reversible` | Auto | `testIdentityReviewProposal` | `PLANNED` |
| `identity.undo_merge` | Cross-Camera Identity | `WallModel` | `proposalID: String` | `Reversible` | Auto | `testIdentityUndoMerge` | `PLANNED` |
| `identity.delete_tracked_object`| `IdentityHistoryView` | `WallModel` | `trackID: String` | `Destructive` | **Confirm** | `testIdentityDeleteTrack` | `PLANNED` |
| `identity.read_vehicle_plate` | `IdentityHistoryView` | `WallModel` | `trackID: String` | `Inspect` | Auto | `testIdentityReadPlate` | `PLANNED` |
| `identity.clear_vehicle_plate` | `IdentityHistoryView` | `WallModel` | `trackID: String` | `Destructive` | Auto | `testIdentityClearPlate` | `PLANNED` |

---

### Category E: Scheduled Missions & Local Patrols

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `mission.list` | `CameraMissionsPanel` | `WallModel` | `none` | `Inspect` | Auto | `testMissionList` | `PLANNED` |
| `mission.create` | `CameraMissionsPanel` | `WallModel` | `cameraID: String, name: String, brief: String, intervalSeconds: Int?, clockTime: String?, weekdays: [Int]?` | `Reversible` | Auto | `testMissionCreate` | `PLANNED` |
| `mission.edit` | `CameraMissionsPanel` | `WallModel` | `missionID: String, name: String?, brief: String?, intervalSeconds: Int?, enabled: Bool?` | `Reversible` | Auto | `testMissionEdit` | `PLANNED` |
| `mission.delete` | `CameraMissionsPanel` | `WallModel` | `missionID: String` | `Destructive` | **Confirm** | `testMissionDelete` | `PLANNED` |
| `mission.run_now` | `CameraMissionsPanel` | `WallModel` | `missionID: String` | `ServiceAffecting` | Auto | `testMissionRunNow` | `PLANNED` |
| `mission.ask_consult` | `CameraMissionsPanel` | `WallModel` | `missionID: String, question: String` | `Inspect` | Auto | `testMissionAskConsult` | `PLANNED` |
| `mission.clear_consult` | `CameraMissionsPanel` | `WallModel` | `missionID: String` | `Reversible` | Auto | `testMissionClearConsult` | `PLANNED` |

---

### Category F: Chronological Memory & Narrative Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `memory.list_frames` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `cameraID: String?, since: String?, until: String?, limit: Int?` | `Inspect` | Auto | `testMemoryListFrames` | `EXISTING` |
| `memory.view_frame` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `frameID: String` | `Inspect` | Auto | `testMemoryViewFrame` | `EXISTING` |
| `memory.delete_frame` | `CameraMemoryView` | `WallModel` | `frameID: String` | `Destructive` | **Confirm** | `testMemoryDeleteFrame` | `PLANNED` |
| `memory.clear_all_frames` | `CameraMemoryView` | `WallModel` | `none` | `Destructive` | **Confirm** | `testMemoryClearAllFrames` | `PLANNED` |
| `memory.list_chapters` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `cameraID: String?, pinnedOnly: Bool?, limit: Int?` | `Inspect` | Auto | `testMemoryListChapters` | `EXISTING` |
| `memory.get_chapter` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `chapterID: String` | `Inspect` | Auto | `testMemoryGetChapter` | `EXISTING` |
| `memory.set_chapter_text` | `CameraMemoryView` | `WallModel` | `chapterID: String, text: String?` | `Reversible` | Auto | `testMemorySetChapterText` | `PLANNED` |
| `memory.toggle_pin` | `CameraMemoryView` | `WallModel` | `chapterID: String, pinned: Bool` | `Reversible` | Auto | `testMemoryTogglePin` | `PLANNED` |
| `memory.close_chapter_now` | `CameraMemoryView` | `WallModel` | `cameraID: String` | `Reversible` | Auto | `testMemoryCloseChapterNow` | `PLANNED` |
| `memory.rebuild_knowledge` | `CameraMemoryView` | `WallModel` | `none` | `ServiceAffecting` | Auto | `testMemoryRebuildKnowledge` | `PLANNED` |

---

### Category G: Watch Rules & Operational Monitoring

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `watch.list` | EventsSettings / WatchRules | `WallModel` | `none` | `Inspect` | Auto | `testWatchList` | `PLANNED` |
| `watch.create` | EventsSettings / WatchRules | `WallModel` | `text: String, cameraIDs: [String]?, ttlMinutes: Int?, forever: Bool?` | `Reversible` | Auto | `testWatchCreate` | `PLANNED` |
| `watch.cancel` | EventsSettings / WatchRules | `WallModel` | `watchID: String` | `Reversible` | Auto | `testWatchCancel` | `PLANNED` |
| `monitor.get_isapi_events` | `ISAPIEventMonitor` | `WallModel` | `cameraID: String?, limit: Int?` | `Inspect` | Auto | `testMonitorGetISAPIEvents` | `PLANNED` |
| `monitor.clear_isapi_events`| `ISAPIEventMonitor` | `WallModel` | `none` | `Destructive` | Auto | `testMonitorClearISAPIEvents` | `PLANNED` |
| `monitor.get_operational_events`| Unified Timeline | `ACTAAnalyticsCoordinator` | `cameraID: String?, kind: String?, limit: Int?` | `Inspect` | Auto | `testMonitorGetOperationalEvents` | `EXISTING` |
| `monitor.live_look` | Unified Chat | `ACTAAnalyticsCoordinator` | `camera: String?` | `Inspect` | Auto | `testMonitorLiveLook` | `EXISTING` |
| `monitor.export_report_html`| Reports | `WallModel` | `none` | `Inspect` | Auto | `testMonitorExportReportHTML` | `PLANNED` |

---

### Category H: SettingsHub (All 14 Sections)

| Action ID | UI Section / Key | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `settings.get_section` | `SettingsHubView` (all) | `WallModel` | `section: String` | `Inspect` | Auto | `testSettingsGetSection` | `PARTIAL — GENERAL/FEATURES ONLY` |
| `settings.update_system` | Sec 1: General & Streams | `WallModel` | `language: String?, columns: Int?, staleTimeoutMs: Int?, go2rtcPath: String?, apiPort: Int?, rtspPort: Int?, yoloThreshold: Double?, detectionFPS: Int?` | `Reversible` | Auto | `testSettingsUpdateSystem` | `PARTIAL — FOUR FIELDS` |
| `settings.update_models` | Sec 3: AI Models | `WallModel` | `enabledServices: [String]?, customPaths: [String: String]?` | `ServiceAffecting` | Auto | `testSettingsUpdateModels` | `PLANNED` |
| `settings.update_runtime_fall` | Sec 4: Advanced Runtime | `WallModel` | `torsoAngle: Double?, aspectRatio: Double?, heightCollapse: Double?, emaAlpha: Double?, minConfirmingSamples: Int?, maxTracks: Int?` | `Reversible` | Auto | `testSettingsUpdateRuntimeFall` | `PLANNED` |
| `settings.update_runtime_storage` | Sec 4: Storage Cleanup | `WallModel` | `maxMediaDiskMB: Int?, minFreeDiskGB: Double?, maxCropsPerIdentity: Int?, dataSaver: Bool?, trackRetentionDays: Int?, logRetentionDays: Int?` | `Reversible` | Auto | `testSettingsUpdateRuntimeStorage` | `PLANNED` |
| `settings.update_runtime_crop` | Sec 4: Crop Selection | `WallModel` | `bootstrapSeconds: Double?, intervalSeconds: Double?, movementFraction: Double?, staleTrackTTL: Double?, cropWindowSeconds: Double?, cropTopK: Int?` | `Reversible` | Auto | `testSettingsUpdateRuntimeCrop` | `PLANNED` |
| `settings.update_ai_config` | Sec 6: AI Backends | `WallModel` | `mode: String ("mlx", "vllm", "openai", "hybrid", "dry_run"), vllmURL: String?, vllmModel: String?, openAIURL: String?, cloudNanoModel: String?, cloudMiniModel: String?, cloudFullModel: String?, spokenBriefingEnabled: Bool?, language: String?` | `Reversible` | Auto | `testSettingsUpdateAIConfig` | `PLANNED` |
| `settings.update_ai_budget` | Sec 6: Cloud Privacy & Budget | `WallModel` | `blurFaces: Bool?, blurPlates: Bool?, dailyBudgetUSD: Double?, monthlyBudgetUSD: Double?` | `Reversible` | Auto | `testSettingsUpdateAIBudget` | `PLANNED` |
| `settings.set_api_key` | Sec 6: Keychain Credentials | `ACTAKeychainStore` | `account: String ("primary", "alert"), apiKey: String` | `Reversible` | Auto | `testSettingsSetAPIKey` | `PLANNED` |
| `settings.clear_api_key` | Sec 6: Keychain Credentials | `ACTAKeychainStore` | `account: String` | `Destructive` | **Confirm** | `testSettingsClearAPIKey` | `PLANNED` |
| `settings.update_schedules` | Sec 7: Scheduled Analysis | `WallModel` | `vlmScheduleIntervalMinutes: Int?, vlmSchedulePrompts: [String]?` | `Reversible` | Auto | `testSettingsUpdateSchedules` | `PLANNED` |
| `settings.update_events_alerts` | Sec 9: Events & Alerts | `WallModel` | `personCountAlertsEnabled: Bool?, personThreshold: Int?, holdSeconds: Double?, cooldownSeconds: Double?, criticalSoundEnabled: Bool?` | `Reversible` | Auto | `testSettingsUpdateEventsAlerts` | `PLANNED` |
| `settings.update_memory_policy`| Sec 10: Memory & Storage | `WallModel` | `chronologicalMemoryEnabled: Bool?, retainFullFrames: Bool?, retentionDays: Int?` | `Reversible` | Auto | `testSettingsUpdateMemoryPolicy`| `PLANNED` |
| `settings.update_feature_toggles`| Sec 11: Features & Access | `WallModel` | `feature: String, enabled: Bool` | `Reversible` | Auto | `testSettingsUpdateFeatureToggles`| `PARTIAL — UNIT TESTS / LIVE PROVIDER` |
| `settings.update_permissions` | Sec 11: Features & Access | `WallModel` | `allowExternalAI: Bool?, allowVoiceInput: Bool?, allowPlateRegistryLookup: Bool?` | `Reversible` | Auto | `testSettingsUpdatePermissions`| `IMPLEMENTED — CONFIRMATION / SERVICE TEST` |
| `settings.toggle_showcase` | Sec 12: Local Showcase | `WallModel` | `running: Bool, port: Int?` | `ServiceAffecting` | Auto | `testSettingsToggleShowcase` | `PLANNED` |
| `settings.update_reid_calibration`| Sec 13: ReID Calibration | `WallModel` | `personDistanceThreshold: Double?, vehicleDistanceThreshold: Double?, metricWeight: Double?` | `Reversible` | Auto | `testSettingsUpdateReID` | `PLANNED` |
| `settings.export_diagnostics` | Sec 14: System Diagnostics | `WallModel` | `none` | `Inspect` | Auto | `testSettingsExportDiagnostics`| `PLANNED` |
| `settings.run_health_check` | Sec 14: System Diagnostics | `WallModel` | `none` | `Inspect` | Auto | `testSettingsRunHealthCheck` | `PLANNED` |
| `settings.reload_models` | Sec 14: System Diagnostics | `WallModel` | `none` | `ServiceAffecting` | Auto | `testSettingsReloadModels` | `PLANNED` |

---

### Category I: Local Voice, Speech & Orchestration

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `voice.start_listening` | Mic Button / Push-to-Talk | `LocalVoiceCoordinator` | `locale: String?` | `Reversible` | Auto | `testVoiceStartListening` | `PLANNED` |
| `voice.stop_listening` | Mic Button Release | `LocalVoiceCoordinator` | `none` | `Reversible` | Auto | `testVoiceStopListening` | `PLANNED` |
| `voice.cancel_listening` | Keyboard Escape / Reset | `LocalVoiceCoordinator` | `none` | `Reversible` | Auto | `testVoiceCancelListening` | `PLANNED` |
| `voice.speak_text` | Agent Spoken Response | `LocalTTSClient` | `text: String, language: String?` | `Reversible` | Auto | `testVoiceSpeakText` | `PLANNED` |
| `voice.stop_speaking` | Interruption / Barge-in | `LocalTTSClient` | `none` | `Reversible` | Auto | `testVoiceStopSpeaking` | `PLANNED` |
| `agent.request_confirmation`| Spoken / Chat Approval | `ACTAActionRegistry` | `actionID: String, prompt: String` | `Inspect` | Auto | `testAgentRequestConfirmation` | `PLANNED` |
| `agent.resolve_confirmation`| Operator Voice / Click | `ACTAActionRegistry` | `actionID: String, confirmed: Bool` | `Reversible` | Auto | `testAgentResolveConfirmation` | `PLANNED` |

---

## 4. Prior Audit Gaps — Design Targets, Not Completion Evidence

1. **Action discovery:** A registry execution branch exists, but the local model still receives the old tool catalogue. End-to-end discovery and execution are pending.
2. **Voice:** On-device ASR exists. Local TTS, voice confirmation and interruption remain pending; no `LocalTTSClient` implementation is present.
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
