# ACTA: GUI to Agent Functional Coverage Matrix

Date: 2026-11-17  
Target: Native Swift/macOS ACTA Application (`alexghost82/multicamera`)  
Version: 1.0.0-baseline  

---

## 1. Executive Summary

Current implementation checkpoint: **59 previously advertised actions plus `reid.calibrate`, `settings.run_health_check`, `settings.update_ai_budget`, `settings.update_ai_config`, `camera.set_favorite`, `canvas.set_filter`, `canvas.select_cameras`, `canvas.set_arrange_mode`, and `canvas.set_presentation`**, with row-specific limitations below. The original baseline inventory is not proof of exhaustive UI coverage.

This working inventory maps currently identified UI/domain operations to agent action contracts. Exhaustive control-by-control parity has not been established.

- **Action rows:** baseline inventory plus subsequently discovered contracts; exhaustive UI coverage remains unverified.
- **Baseline legacy tools:** 16 read-only query tools + 1 terminal tool (`present_answer`)
- **Baseline legacy mutations:** 3 (`rename_identity`, `merge_identities`, `split_identity`)
- **Baseline gap estimate:** the old 89 / 82.4% figure depended on the unsupported 108-operation total and is not accepted as a coverage measurement.

### Additional GUI inventory candidates

These are proposed identifiers, not registered action contracts. Their scope,
authorization policy and agent/GUI parity remain unverified.

| Candidate | GUI operation | Current limitation |
| :--- | :--- | :--- |
| `camera.set_all_running` | Start or stop the camera wall | `camera.set_enabled` changes one configuration flag. Screen capture late-start fencing is fake-tested; actual stop is asynchronous and `running` is not stream readiness. Full isolated lifecycle proof remains missing. |
| `camera.import_sources` | Import RTSP sources from a file | Import may handle credentials; anonymous disabled `camera.add_network` is not equivalent. |
| `camera.set_favorite` | Mark or unmark a camera as favorite | Registered and advertised; current preference readback is verified, but durable disk synchronization and live GUI update are not. |
| `canvas.set_filter` | Filter by status, favorite, events, search or location | Registered for these filters in the unique attached view; rendered GUI remains unverified. |
| `canvas.select_cameras` | Select individual cameras, all or none | Registered for the unique attached view; readback and enabled-camera inventory verified, live rendering unverified. |
| `canvas.set_tile_frame`, `canvas.set_arrange_mode` | Arrange and move camera tiles | Arrange toggle is registered and checked in the unique attached view. Geometry remains unsupported: whole-layout writes can overwrite concurrent updates or an in-progress drag. |
| `chat.select_thread`, `chat.new_thread` | Switch or create a chat thread | Switching cancels an active request; agent parity is not established. |
| `chat.cancel_request` | Cancel an active chat request | A GUI cancellation test exists, but an agent contract is not established. |
| Operator track grouping / separation | Group selected tracks or remove them from operator groups | Distinct from legacy identity merge/split; separation can partially succeed. |
| ReID pair review | Inspect candidates, mark Same/Different or undo Different | Same can also group tracks; operator attribution and stale-pair checks are needed. |
| Cross-camera proposal creation | Propose a match between tracks | Pair freshness and provenance have not been established. |
| Incident evidence viewing | Display evidence frames | Sensitive-image disclosure and delivery policy are unresolved. |
| Alert lookback clips | View or delete a clip | Deletion spans alert storage and clip files and may partially fail. |
| Alert review history | Inspect prior operator reviews | Notes are sensitive; safe disclosure policy is unresolved. |
| Crop description / visual similarity | Describe a saved crop or find visually similar crops | Model and privacy controls and evidence semantics require review. |
| Spoken tactical briefing | Enable or disable speech in AI settings | Not registered: existing briefing generation can send context to a configured external backend. |
| Grid/list and fullscreen | Change camera display mode or fullscreen | Window-local grid/list is registered; key-window fullscreen is not. |

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
| `camera.list` | `WallView` / `CameraManager` | `WallModel` | `includeDisabled: Bool?` | `Inspect` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `IMPLEMENTED — CONFIGURATION INSPECTION` |
| `camera.get` | `CameraEditor` | `WallModel` | `cameraID: String` | `Inspect` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `IMPLEMENTED — CONFIGURATION; NOT HARDWARE INVENTORY` |
| `camera.add_network` | `CameraEditor` sheet | `WallModel` | `name, url, mainstream?; no credentials/query/fragment; always disabled` | `ServiceAffecting` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `PARTIAL — ANONYMOUS/DISABLED; DISCOVERY UNVERIFIED` |
| `camera.add_local` | `LocalCameraEditor` sheet | `WallModel` | `device_id, name; always disabled` | `ServiceAffecting` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `PARTIAL — DISABLED CONFIG; CAPTURE UNVERIFIED` |
| `camera.add_screen` | `ScreenCaptureCameraEditor` | `WallModel` | `display_id (>0), name; always disabled` | `ServiceAffecting` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `PARTIAL — DISABLED CONFIG; CAPTURE UNVERIFIED` |
| `camera.add_file` | `VideoFileCameraEditor` | `WallModel` | `file_path (absolute regular readable file), name?; always disabled` | `ServiceAffecting` | Auto | `testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials` | `PARTIAL — BOOKMARK/CONFIG; DECODING UNVERIFIED` |
| `camera.edit` | `CameraEditor` sheet | `WallModel` | `camera_id, name?, location?, clear_location?, url?, mainstream?, clear_mainstream?` | `ServiceAffecting` | **Confirm URL changes** | `testMetadataProcessingAndURLChangesPreserveCredentialAndSourceIdentity` | `PARTIAL — METADATA/SAFE URLS; CREDENTIAL UI REMAINS` |
| `camera.set_processing` | Camera context settings | WallModel | `camera_id, feature: yolo/ai_chat, enabled: Bool` | `Reversible` | **Confirm AI flag change** | `testMetadataProcessingAndURLChangesPreserveCredentialAndSourceIdentity` | `IMPLEMENTED — CONFIG/GUI SERVICE TEST` |
| `camera.set_enabled` | `CameraManager` toggle | `WallModel` | `cameraID: String, enabled: Bool` | `ServiceAffecting` | **Confirm on enable** | `testMetadataProcessingAndURLChangesPreserveCredentialAndSourceIdentity` | `IMPLEMENTED — CONFIG FLAG; STREAM UNVERIFIED` |
| `camera.remove` | `WallView` remove alert | `WallModel` | `cameraID: String` | `Destructive` | **Confirm** | `testRemovalRequiresReviewAndChecksCredentialDeletion` | `IMPLEMENTED — CONFIG/FAKE CREDENTIAL STORE; LIVE KEYCHAIN UNVERIFIED` |
| `camera.reconnect` | Camera context menu | `WallModel` | `cameraID: String` | `ServiceAffecting` | Auto | `CameraReconnectAttemptTests` (fake helper only) | `GAP — RELAY CANCELLATION, LATE AVCAPTURE START AND GUI SESSION INSTALLATION UNVERIFIED` |
| `camera.set_favorite` | Camera context menu | `UserDefaults` / `ACTACameraFavorites` | `camera_id: UUID or unique name, favorite: Bool` | `Reversible` | Auto | `ACTACameraFavoriteActionTests` | `PARTIAL — SHARED PREFERENCE/READBACK; DISK SYNCHRONIZATION AND LIVE GUI UNVERIFIED` |
| `camera.snapshot` | Camera action bar | `WallModel` | `cameraID: String` | `ServiceAffecting` | Destination/confirmation policy pending | Not implemented | `GAP — GUI WRITES JPEG THROUGH A SAVE PANEL; NOT A READ-ONLY QUERY` |
| `camera.toggle_expand` | Video canvas double-click | `WallModel` | `cameraID: String` | `Reversible` | Auto | `testCanvasActionsShareGUIStateAndVerifySavedLayout` | `IMPLEMENTED — UI STATE; STREAM UNVERIFIED` |
| `canvas.set_columns` | SystemSettings / Canvas | `WallModel` | `columns: Int (1...16)` | `Reversible` | Auto | `testCanvasSetColumns` | `IMPLEMENTED — SERVICE TEST` |
| `canvas.reset_layout` | Window menu / Toolbar | `WallModel` | `none` | `Reversible` | Auto | `testCanvasActionsShareGUIStateAndVerifySavedLayout` | `IMPLEMENTED — DISK/FAILURE TEST` |
| `canvas.set_filter` | Camera view | `ACTACanvasFilterState` | `search?, location?, status: all/live/offline?, favorites_only?, events_only?` | `Reversible` | Auto | `ACTACanvasFilterActionTests` | `PARTIAL — UNIQUE ATTACHED VIEW STATE; LIVE RENDER UNVERIFIED` |
| `canvas.select_cameras` | Camera picker | `ACTACanvasFilterState` | `mode: all/none/subset, camera_ids: CSV UUIDs for subset` | `Reversible` | Auto | `ACTACanvasSelectCamerasActionTests` | `PARTIAL — ENABLED CAMERA SNAPSHOT; LIVE RENDER AND CONNECTIVITY UNVERIFIED` |
| `canvas.set_arrange_mode` | Camera view menu | `ACTACanvasFilterState` | `enabled: Bool` | `Reversible` | Auto | `ACTACanvasArrangeActionTests` | `PARTIAL — WINDOW-LOCAL TOGGLE; RENDER AND TILE GEOMETRY UNVERIFIED` |
| `canvas.set_presentation` | Camera view grid/list picker | `ACTACanvasFilterState` | `mode: grid/list` | `Reversible` | Auto | `ACTACanvasPresentationActionTests` | `PARTIAL — WINDOW-LOCAL STATE; RENDER UNVERIFIED` |

---

### Category B: Video Analytics & Detection Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `analytics.get_settings` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String?` | `Inspect` | Auto | `testCameraOverrideAndZoneLifecyclePreservePolicyAndIDs` | `IMPLEMENTED — GLOBAL/OVERRIDE/EFFECTIVE READ` |
| `analytics.set_global_toggle` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `feature: String, enabled: Bool` | `Reversible` | Auto | `testAllOverlaysAndGlobalFlagsUseActualService` | `IMPLEMENTED — 15 GLOBAL FLAGS` |
| `analytics.set_threshold` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `parameter: String, value: Double` | `Reversible` | Auto | `testNumericSettingsRoundTripAndRejectInvalidValuesBeforeWriting` | `IMPLEMENTED — 12 NUMERIC PARAMETERS` |
| `analytics.set_sampling_fps` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `fps: Double, idleFPS: Double?, boostFPS: Double?` | `Reversible` | Auto | `testNumericSettingsRoundTripAndRejectInvalidValuesBeforeWriting` | `IMPLEMENTED — RATE VALIDATION / DISK TEST` |
| `analytics.set_overlay` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `layer: String, enabled: Bool` | `Reversible` | Auto | `testAllOverlaysAndGlobalFlagsUseActualService` | `IMPLEMENTED — 8 OVERLAYS` |
| `analytics.set_camera_override` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `camera_id, enabled?, inherit?, fps?, clear_fps?, cooldown_seconds?, clear_cooldown?, sensitivity_profile?, 9 detector switches?` | `Reversible` | Auto | `testAdvancedCameraOverridesAndConfirmedRemoval` | `IMPLEMENTED — SWITCHES/PROFILE/FPS/COOLDOWN` |
| `analytics.set_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String, name: String, x: Double, y: Double, width: Double, height: Double` | `Reversible` | Auto | `testCameraOverrideAndZoneLifecyclePreservePolicyAndIDs` | `PARTIAL — RECTANGLE GEOMETRY ONLY` |
| `analytics.remove_restricted_zone` | `AnalyticsSettingsEditor` | `LocalVideoAnalyticsEngine` | `cameraID: String, name: String` | `Reversible` | Auto | `testCameraOverrideAndZoneLifecyclePreservePolicyAndIDs` | `IMPLEMENTED — UNIQUE NAME` |

| `analytics.set_sensitivity_profile` | AnalyticsSettingsEditor / profile + apply | LocalVideoAnalyticsEngine | `profile: enum, apply_values: Bool?` | `Reversible` | Auto | `testSensitivityProfilesMatchGUIAndSelectionDoesNotApplyPreset` | `IMPLEMENTED — ALL PROFILES` |
| `analytics.remove_camera_override` | AnalyticsSettingsEditor / remove override | LocalVideoAnalyticsEngine | `camera_id: UUID` | `Destructive` | **Confirm** | `testAdvancedCameraOverridesAndConfirmedRemoval` | `IMPLEMENTED — DISK/CONFIRMATION TEST` |
| `analytics.update_restricted_zone` | RestrictedZoneSettingsEditor / policy + polygon | LocalVideoAnalyticsEngine | `camera_id, zone_id, new_name?, enabled?, hold_seconds?, severity?, point_index?, point_x?, point_y?, append_point?, remove_point?` | `Reversible` | Auto | `testPolygonAndZonePolicyEditsPreserveIdentityAndRejectInvalidOperations` | `IMPLEMENTED — POLICY/POINT OPERATIONS` |
| `analytics.set_execution_mode` | AnalyticsSettingsEditor / execution mode | LocalVideoAnalyticsEngine | `mode: LOCAL / DISTRIBUTED` | `ServiceAffecting` | Scope decision pending | Not implemented | `GAP — DISTRIBUTED OUTSIDE CURRENT LOCAL TARGET` |

---

### Category C: Safety Incidents & Alert Management

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `incident.list` | `SafetyIncidentCenterView` | `LocalVideoAnalyticsEngine` | `open_only: Bool?, camera_id: UUID?, query: String?, limit: Int?` | `Inspect` | Auto | `ACTAIncidentSearchTests`, `testIncidentTransitionAndQueryUsePersistentDomainService` | `PARTIAL — QUERY/SERVICE TESTED; FULL RECORDS ARE SENSITIVE` |
| `incident.get` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID` | `Inspect` | Auto | `ACTAIncidentReadActionsTests`, `testIncidentTransitionAndQueryUsePersistentDomainService` | `PARTIAL — MINIMAL METADATA; GUI DETAIL FIELDS NOT EXPOSED` |
| `incident.transition_status` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID, status: enum, note: String?` | `Reversible` | Confirm for `false_positive` or a nonempty note | `testIncidentTransitionAndQueryUsePersistentDomainService` | `PARTIAL — STATUS/NOTE; CUSTOM SUPPRESSION PENDING; FULL RECORD IN OUTPUT` |
| `incident.update_note` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incident_id: UUID, note: String (empty clears)` | `Reversible` | **Confirm — operator attribution** | `ACTAIncidentNoteActionTests` | `PARTIAL — GUI SERVICE/PERSISTENCE TESTED; RAW NOTE IN EXISTING OPERATOR AUDIT` |
| `incident.delete_evidence` | `SafetyIncidentDetailView` | `LocalVideoAnalyticsEngine` | `incidentID: String` | `Destructive` | **Confirm** | `testEvidenceDeletionRequiresApprovalAndPreservesIncidentRecord` | `IMPLEMENTED — SERVICE/CONFIRMATION TEST` |
| `alert.vlm_list` | Events / Timeline | `WallModel` | `camera_id: UUID?, unacknowledged_only: Bool?, limit: Int? (1...100)` | `Inspect` | Auto | `ACTAAlertReadActionsTests`, `testAlertAndISAPIReadsUseVerifiedGUIState` | `PARTIAL — MINIMAL METADATA; SOURCE MUST MATCH GUI` |
| `alert.vlm_acknowledge` | Events / Alerts Queue | `WallModel` | `alert_id: UUID, acknowledged: Bool` | `Reversible` | Auto | `ACTAAlertMutationActionsTests` | `PARTIAL — GUI SERVICE/SQL/LOCK TESTED; NO SWIFTUI OR FAILURE RECOVERY TEST` |
| `alert.vlm_review` | Events / Alerts Queue | `WallModel` | `alert_id: UUID, status: String, priority: String?, note: String?` | `Reversible` | **Confirm — operator review** | `ACTAAlertMutationActionsTests` | `PARTIAL — GUI SERVICE/SQL/LOCK TESTED; NO SWIFTUI OR FAILURE RECOVERY TEST` |
| `alert.clear_all` | Events / Alerts Queue | `WallModel` | `none` | `Destructive` | **Confirm** | `ClearVLMAlertsTests` (GUI only) | `GAP — GUI REPORTS PARTIAL FAILURES; CROSS-STORE RECOVERY REQUIRED` |

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
| `identity.review_proposal` | Cross-Camera Identity | `WallModel` | `proposalID: String, accept: Bool` | `Reversible` | Policy pending | Not implemented | `GAP — GUI RECHECKS TRACKS AND REVIEW SNAPSHOT; FEATURE POLICY RACE AND CROSS-STORE CRASH ATOMICITY REMAIN` |
| `identity.undo_merge` | Cross-Camera Identity | `WallModel` | `proposalID: String` | `Reversible` | Confirmation/version policy pending | Not implemented | `GAP — CONSEQUENCES CHANGE IF THE IDENTITY GRAPH CHANGES` |
| `identity.delete_tracked_object`| `IdentityHistoryView` | `WallModel` | `trackID: String` | `Destructive` | **Confirm** | Not implemented | `GAP — PARTIAL DELETE AND CROP FAILURE RECOVERY REQUIRED` |
| `identity.read_vehicle_plate` | `IdentityHistoryView` | `WallModel` | `trackID: String` | `ServiceAffecting` | Privacy/persistence policy pending | Not implemented | `GAP — GUI OCR MAY PERSIST EVIDENCE WHEN OPTED IN; SHARED VERIFIED WORKFLOW REQUIRED` |
| `identity.clear_vehicle_plate` | `IdentityHistoryView` | `WallModel` | `trackID: String` | `Destructive` | Policy pending | Not implemented | `GAP — GUI CLEARS TRACK FIELD ONLY WITH WARNING; INDEX COPIES REMAIN` |
| `reid.calibrate` | `ReIDCalibrationView` | `LocalTrackingStore` / `ReIDThresholdCalibrator` | `target_precision: number (0.90...1.0)` | `Inspect` | Auto | `ACTAReIDCalibrationActionTests`; isolated GUI/store integration | `PARTIAL — AGGREGATE RECOMMENDATION ONLY; DOES NOT APPLY SETTINGS` |

---

### Category E: Scheduled Missions & Local Patrols

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `mission.list` | `CameraMissionsPanel` | `WallModel` | `none` | `Inspect` | Auto | `testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore` | `IMPLEMENTED — SAVED MISSIONS / RUNTIME STATE` |
| `mission.create` | `CameraMissionsPanel` | `WallModel` | `mission_id (edit), camera_id, name, brief, interval_seconds?, schedule_kind?, clock_times CSV?, weekdays CSV (0=Sunday)?, time_zone?, enabled?` | `Reversible` | Auto | `testClockScheduleValidationAndScheduleRecalculation` | `IMPLEMENTED — INTERVAL/CLOCK / DISK TEST` |
| `mission.edit` | `CameraMissionsPanel` | `WallModel` | `mission_id (edit), camera_id, name, brief, interval_seconds?, schedule_kind?, clock_times CSV?, weekdays CSV (0=Sunday)?, time_zone?, enabled?` | `Reversible` | Auto | `testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore` | `IMPLEMENTED — PRESERVES HISTORY` |
| `mission.delete` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `Destructive` | **Confirm** | `testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore` | `IMPLEMENTED — CONFIRMED / RUNS PRESERVED` |
| `mission.run_now` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `ServiceAffecting` | Auto | `testManualRunIsAnIdempotentQueueReceiptNotACompletedAnalysis` | `PARTIAL — QUEUE RECEIPT; REAL INFERENCE UNVERIFIED` |
| `mission.history` | CameraMissionsPanel / saved results | WallModel / CameraMissionStore | `mission_id: UUID, limit: Int? (1...100)` | `Inspect` | Auto | `testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore` | `IMPLEMENTED — SAVED RUN/CONSULT PROVENANCE` |
| `mission.ask_consult` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID, question: String (<=2000)` | `ServiceAffecting` | Auto | `testConsultationReceiptAndSavedReplyUseLocalDomainWorkflow` | `PARTIAL — ADMISSION/SCRIPTED REPLY; REAL MODEL UNVERIFIED` |
| `mission.clear_consult` | `CameraMissionsPanel` | `WallModel` | `mission_id: UUID` | `Destructive` | **Confirm** | `testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore` | `IMPLEMENTED — CONFIRMED / RUNS PRESERVED` |

---

### Category F: Chronological Memory & Narrative Engine

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `memory.list_frames` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `cameraID: String?, since: String?, until: String?, limit: Int?` | `Inspect` | Auto | `testMemoryListFrames` | `EXISTING` |
| `memory.view_frame` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `frameID: String` | `Inspect` | Auto | `testMemoryViewFrame` | `EXISTING` |
| `memory.delete_frame` | `CameraMemoryView` | `WallModel` | `frameID: String` | `Destructive` | **Confirm** | `testMemoryDeletionRequiresApprovalAndRemovesActualImage` | `PARTIAL — SERVICE/CONFIRMATION TEST; LEGACY PROCESSES DO NOT HONOR THE NEW LOCK` |
| `memory.clear_all_frames` | `CameraMemoryView` | `WallModel` | `none` | `Destructive` | **Confirm** | Not implemented | `GAP — GUI BINDS THE INDEXED SET AND SUPPORTS RECOVERY; ACTION NOT REGISTERED, LEGACY PROCESSES AND POWER-LOSS DURABILITY UNVERIFIED` |
| `memory.list_chapters` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `cameraID: String?, pinnedOnly: Bool?, limit: Int?` | `Inspect` | Auto | `testMemoryListChapters` | `EXISTING` |
| `memory.get_chapter` | `CameraMemoryView` | `ACTAAnalyticsCoordinator` | `chapterID: String` | `Inspect` | Auto | `testMemoryGetChapter` | `EXISTING` |
| `memory.set_chapter_text` | `CameraMemoryView` | `WallModel` | `chapter_id: String, text: String? (<=16000), clear: Bool?` | `Reversible` | **Confirm — operator attribution** | `testNarrativeActionsRequireReviewAndPreserveAISummary` | `IMPLEMENTED — SQL/REVIEW TEST` |
| `memory.toggle_pin` | `CameraMemoryView` | `WallModel` | `chapterID: String, pinned: Bool` | `Reversible` | **Confirm — operator attribution** | `testNarrativeActionsRequireReviewAndPreserveAISummary` | `IMPLEMENTED — IDEMPOTENT STATE/REVIEW TEST` |
| `memory.close_chapter_now` | `CameraMemoryView` | `WallModel` | `cameraID: String` | `ServiceAffecting` | Policy pending | Not implemented | `GAP — IN-PROCESS RETRY ONLY; CRASH DURABILITY AND FULL RECOVERY NOT PROVEN` |
| `memory.rebuild_knowledge` | `CameraMemoryView` | `WallModel` | `none` | `ServiceAffecting` | Auto | `testMemoryRebuildKnowledge` | `PLANNED` |

---

### Category G: Watch Rules & Operational Monitoring

| Action ID | UI Route / Screen | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `watch.list` | EventsSettings / WatchRules | `WallModel` | `none` | `Inspect` | Auto | `testWatchActionsShareGUIServiceAndVerifyDisk` | `IMPLEMENTED — SERVICE TEST` |
| `watch.create` | EventsSettings / WatchRules | `WallModel` | `text: String, cameraIDs: [String]?, ttlMinutes: Int?, forever: Bool?` | `Reversible` | Auto | `testWatchActionsShareGUIServiceAndVerifyDisk` | `IMPLEMENTED — SERVICE/VALIDATION TEST` |
| `watch.cancel` | EventsSettings / WatchRules | `WallModel` | `watchID: String` | `Reversible` | Auto | `testWatchActionsShareGUIServiceAndVerifyDisk` | `IMPLEMENTED — SERVICE TEST` |
| `monitor.get_isapi_events` | `ISAPIEventMonitor` | `WallModel` | `camera_id: UUID?, limit: Int? (1...100)` | `Inspect` | Auto | `ACTAISAPIReadActionsTests`, `testAlertAndISAPIReadsUseVerifiedGUIState` | `PARTIAL — EXISTING LOCAL HISTORY; NO LIVE MONITOR VERIFICATION` |
| `monitor.clear_isapi_events`| No current GUI control; unused `WallModel.clearISAPIEvents` | `WallModel` | `none` | `Destructive` | Confirmation required | `ACTAClearISAPIEventsActionTests` (isolated service only) | `GAP — SERVICE NOT INTEGRATED; LIVE BASELINE AND PARTIAL-FAILURE HANDLING REQUIRED` |
| `monitor.get_operational_events`| Unified Timeline | `ACTAAnalyticsCoordinator` | `cameraID: String?, kind: String?, limit: Int?` | `Inspect` | Auto | `testMonitorGetOperationalEvents` | `EXISTING` |
| `monitor.live_look` | Unified Chat | `ACTAAnalyticsCoordinator` | `camera: String?` | `Inspect` | Auto | `testMonitorLiveLook` | `EXISTING` |
| `monitor.export_report_html`| Reports | `WallModel` | GUI chooses report and destination | `ServiceAffecting` | Report/destination/confirmation policy pending | Not implemented | `GAP — TWO SENSITIVE REPORT TYPES USE SEPARATE SAVE PANELS; NO SHARED SAFE DESTINATION CONTRACT` |

---

### Category H: SettingsHub (All 14 Sections)

| Action ID | UI Section / Key | Service Owner | Typed Arguments | Action Type | Policy | Unit / Parity Test | State |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `settings.get_section` | SettingsHub sections | `WallSettingsAction` / `WallModel` | `section: enum` | `Inspect` | Auto | `testSectionInspectionRedactsEndpointsAndReturnsUnsupportedInsteadOfInventing` | `PARTIAL — CONFIGURATION ONLY; IDENTITY UNSUPPORTED; NO HEALTH/READINESS PROOF` |
| `settings.update_system` | Sec 1: General & Streams | `WallModel` / GUI `LanguageSettings` | `language: en/ru (separate call), columns?, stale_threshold_ms?, detection_threshold?, detection_fps?` | `Reversible` | Auto | `ACTASystemLanguageActionTests`; isolated GUI/store integration | `PARTIAL — LANGUAGE + FOUR FIELDS; PORTS/PATH UNSUPPORTED` |
| `settings.update_models` | Sec 3: AI Models | `WallModel` | GUI service selection and custom paths | `ServiceAffecting` | Confirmation and path identity policy pending | Not implemented | `GAP — PATH OBJECT MAY CHANGE BEFORE DEFERRED MODEL LOAD` |
| `settings.update_runtime_fall` | Sec 4: Advanced Runtime | `WallModel.saveRuntimePreferences` | 22 advanced GUI fields; four common fields use analytics actions | `ServiceAffecting` | Auto | `testAllGUIFallFieldsAndCropFieldsPersistThroughRuntimeService` | `IMPLEMENTED — TEMP STORE / SERVICE TEST` |
| `settings.update_runtime_storage` | Sec 4: Storage Cleanup | `WallModel.saveRuntimePreferences` | `maxMediaDiskMB: Double?, minFreeDiskGB: Double?, maxCropsPerIdentity: Int?, dataSaverEnabled: Bool?, trackImageRetentionDays: Int?, logRetentionDays: Int?` | `SecuritySensitive` | **Confirm** | `testReviewedStorageAndMemoryPolicyMatchDiskWithoutClaimingCleanup` | `IMPLEMENTED — POLICY VERIFIED; CLEANUP NOT RUN` |
| `settings.update_runtime_crop` | Sec 4: Crop Selection | `WallModel.saveRuntimePreferences` | Six capture scheduler fields plus `cropWindowSeconds: Double?, cropTopK: Int?, cropImprovementRatio: Double?` | `ServiceAffecting` | Auto | `testAllGUIFallFieldsAndCropFieldsPersistThroughRuntimeService` | `IMPLEMENTED — TEMP STORE / SERVICE TEST` |
| `settings.update_ai_config` | Sec 6: AI Backends | `WallModel.saveVLMPreferences` | `language: ru/en/he` | `SecuritySensitive` | **Confirm** | `ACTAAIConfigActionTests` | `PARTIAL — LANGUAGE ONLY; BACKENDS/ENDPOINTS UNSUPPORTED; STALE CONFIRMATION AND NETWORK POLICY REMAIN OPEN` |
| `settings.update_ai_budget` | Sec 6: Cloud Privacy & Budget | `WallModel.saveVLMPreferences` | `blurFaces: Bool?, blurPlates: Bool?, dailyBudgetUSD: Double?, monthlyBudgetUSD: Double?` | `SecuritySensitive` | **Confirm** | `ACTAAIBudgetActionTests` | `PARTIAL — CONFIGURATION VERIFIED; SAVE SIDE EFFECTS AS ABOVE; NO BILLING CAP OR ANONYMIZATION GUARANTEE` |
| `settings.set_api_key` | Sec 6: Keychain Credentials | `ACTAKeychainStore` | `account: String ("primary", "alert"), apiKey: String` | `Reversible` | Auto | `testSettingsSetAPIKey` | `PLANNED` |
| `settings.clear_api_key` | Sec 6: Keychain Credentials | `ACTAKeychainStore` | `account: String` | `Destructive` | **Confirm** | `testSettingsClearAPIKey` | `PLANNED` |
| `settings.update_schedules` | Sec 7: Scheduled Analysis | `WallModel.saveVLMPreferences` | `scheduleEnabled: Bool?, intervalSeconds: Int?, analyzeAllEnabledCameras: Bool?, camera_ids: CSV UUID string?` | `SecuritySensitive` | **Confirm** | `testEventsAndSchedulesPreserveUnrelatedBackendAndPermissions` | `IMPLEMENTED — CONFIGURATION; NO INFERENCE COMPLETION PROOF` |
| `settings.update_events_alerts` | Sec 9: Events & Alerts | `WallModel.saveOperationsPreferences` | `personCountAlertsEnabled: Bool?, personThreshold: Int?, holdSeconds: Int?, cooldownSeconds: Int?, criticalSoundEnabled: Bool?` | `Reversible` | Auto | `testEventsAndSchedulesPreserveUnrelatedBackendAndPermissions` | `IMPLEMENTED — TEMP STORE / SERVICE TEST` |
| `settings.update_memory_policy` | Sec 10: Memory & Storage | `WallModel.saveFeaturePolicy` | `retainFullFrames: Bool?, retentionDays: Int?`; feature enablement separate; sampled frames cap 7 days | `SecuritySensitive` | **Confirm** | `testReviewedStorageAndMemoryPolicyMatchDiskWithoutClaimingCleanup` | `IMPLEMENTED — POLICY VERIFIED` |
| `settings.save_alert_rule` | Sec 7: Alert Rules | `WallModel.saveVLMPreferences` | `rule_id: UUID?, condition: String?, enabled: Bool?, cooldownSeconds: Int?, priority: enum?` | `SecuritySensitive` | **Confirm** | `testAlertRuleLifecycleIsReviewedAndUnrelatedPreferencesSurvive` | `IMPLEMENTED — CREATE/EDIT; TEMP STORE TEST` |
| `settings.remove_alert_rule` | Sec 7: Alert Rules | `WallModel.saveVLMPreferences` | `rule_id: UUID` | `SecuritySensitive` | **Confirm** | `testAlertRuleLifecycleIsReviewedAndUnrelatedPreferencesSurvive` | `IMPLEMENTED — TEMP STORE TEST` |
| `settings.update_feature_toggles`| Sec 11: Features & Access | `WallModel` | `feature: String, enabled: Bool` | `Reversible` | Auto | `testSettingsUpdateFeatureToggles`| `PARTIAL — UNIT TESTS / LIVE PROVIDER` |
| `settings.update_permissions` | Sec 11: Features & Access | `WallModel` | `allowExternalAI: Bool?, allowVoiceInput: Bool?, allowPlateRegistryLookup: Bool?` | `Reversible` | Auto | `testSettingsUpdatePermissions`| `IMPLEMENTED — CONFIRMATION / SERVICE TEST` |
| `settings.toggle_showcase` | Sec 12: Local Showcase | `WallModel` | `running: Bool, port: Int?` | `ServiceAffecting` | Auto | `testSettingsToggleShowcase` | `PLANNED` |
| `settings.update_reid_calibration` | Sec 13: ReID Calibration | `ReIDCalibrationView` / `ReIDThresholdCalibrator` | GUI has transient `targetPrecision`, not the previously listed persistent settings | `Reversible` | Scope decision pending | Not implemented | `GAP — SLIDER STATE IS NOT CONTROLLED; reid.calibrate COMPUTES THE RECOMMENDATION WITHOUT PERSISTING OR APPLYING SETTINGS` |
| `settings.export_diagnostics` | Sec 14: System Diagnostics | `WallModel` | GUI chooses destination | `ServiceAffecting` | Destination/confirmation policy pending | Not implemented | `GAP — FILE EXPORT; NOT A READ-ONLY QUERY` |
| `settings.run_health_check` | Sec 14: System Diagnostics | `WallModel` | `none` | `ServiceAffecting` | Notice | `ACTARunHealthCheckActionTests` | `PARTIAL — FRESH IN-APP SNAPSHOT/HISTORY TESTED; NO INDEPENDENT WATCHER OR LIVE CAMERAS` |
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
