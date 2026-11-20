# Local action broker (Phase 1 Waves 1A–1F complete)

## 2026-11-20 — Phase 1 Final Closure (Waves 1A–1F) Broker Update

- **Complete Production Catalogue:** `WallModel.buildProductionBrokerActions()` and `ACTAAnalyticsCoordinator.allBrokerActionIDs` now expose **123 typed action mappings** across Settings & Diagnostics, Main/Settings Navigation (`ACTANavigationBridge`), Cameras & Hardware Discovery, Canvas, Analytics Overrides & Restricted Zones, Safety Incidents & Evidence Metadata, VLM/ISAPI Alerts & Review/Clip Metadata, Watch Rules, Scheduled Missions, Memory & Narratives, Description Jobs, Identities/ReID/Crop Description/Similarity, Chat Threads, and Local Voice Controls & Dictation Language.
- **Direct GUI Audit (`initiator: "ui_direct"`):** `WallModel.recordDirectGUIAction(...)` writes redacted direct GUI mutation events into `ghost_chat_tool_calls` (`thread_id = "ui_direct"`), ensuring shared audit observability between GUI controls and agent broker actions.
- **Approved Model Exclusions:** `window.toggle_fullscreen`, `showcase.copy_link`, `ai.toggle_spoken_briefing`, `worker.edit_config`, `agent.request_confirmation`, and `agent.resolve_confirmation` are intentionally unmapped and return `AUTHORIZATION_DENIED` (verified by `ACTAWave1FFullClosureTests`).
- **Idempotency & Execution Deadlines:** `ACTAActionContext` now carries optional `idempotencyKey` and `timeoutSeconds`. `ACTAActionRegistry` deduplicates verified successful mutations per `(actionID, threadID, idempotencyKey)` (bounded 256-entry FIFO cache) and enforces structured cancellation-safe deadlines (`ACTION_TIMED_OUT`). `ACTALocalActionBroker.make` defaults to a 30s per-action deadline (`actionTimeoutSeconds`).
- **Session Camera Scope:** `WallModel.askACTAAgent` passes active canvas camera selection (or configured camera IDs) into `openSession(..., historyCameraIDs:)`.
- **Secret-Safe Broker Contracts:**
  - `settings.set_api_key` accepts only `account` (`primary`/`alert`) and invokes a native `NSSecureTextField` prompt after operator confirmation so raw API keys never enter LLM arguments, review text, tool outputs, or audit logs.
  - `camera.add_network` and `camera.edit` accept structured credential-free fields (`scheme`, `host`, `port`, `path`) that satisfy `parametersAreDisplayable` without relaxing URL/credential rejection.
  - `camera.set_favorite` is wired with process-local revision tracking (`ACTALocalFavoriteReviewDomain`); `UserDefaults` does not provide cross-process atomicity.
- **Residual Process/Hardware Caveats:** Advisory file locks and process-local revisions do not exclude older uncoordinated binaries or guarantee power-loss durability across heterogeneous stores (JSON + SQLite + Keychain + `UserDefaults`). Live GUI/hardware/Qwen/vLLM Metal acceptance remains in Phases 2–4.

---

Camera configuration and runtime lock files are checked for a single regular
file owned by the current user, private permissions and stable identity when
acquired. This does not protect against later lock-file replacement or
coordinate writers and runtimes that do not use the locks.

Broker action requests use an operation UUID shared by request, validation,
review and result audit events. The trusted review UI displays it; the durable
audit stores only that UUID in metadata, not review parameters. It is not an
authorization capability. Direct inspection audit events do not have this ID.

### Per-camera analytics foundation (not registered)

`ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, ...)` reviews one
field for a UUID camera. It supports the camera switches, sensitivity profile,
and optional sampling FPS/cooldown; the string `inherit` clears either numeric
override. A missing override is created with defaults. It preserves unrelated
fields and zones, and does not remove overrides or edit zones. The review warns
that global inheritance and camera state may suppress the effective change.
The separate prepared `.removeCameraOverride` action reviews removal of the
override and its restricted zones. It is also unregistered; its isolated tests
use a synthetic inventory and do not establish production camera coordination.

The action is deliberately excluded from `Kind.productionCases`, used by production
registration. `ACTAEngineAnalyticsMutationDomain` supplies the real settings
CAS, but camera inventory is not yet a coordinated production domain. Before
registering the action, implement `ACTAAnalyticsCameraInventory.withCamera`
over a shared cross-process, non-reentrant inventory writer boundary. It must
validate camera existence and memory/disk agreement while holding that boundary
through settings capture, compare-and-commit and readback; use an ABA-safe
inventory revision, invalidated on every write and uncertain failure. Route
all GUI, discovery, import, reload, legacy and other instance writers through
that same boundary. Establish a consistent inventory-before-settings lock order
and fail closed on contention or failed reconciliation. Older binaries and
non-cooperating writers must be excluded. Wire the resulting domain explicitly
into the broker only after these invariants hold; update the model catalog then.

`withLockedSnapshot` can cover the analytics CAS and its snapshot comparison
detects ABA by cooperating camera-store writers. It cannot alone fence in-memory
changes: `cameraWriterGate.capture` does not exclude writes, `WallModel.config`
has direct mutation paths (including worker lease changes), and analytics
publication can synchronously re-enter observers after its settings CAS.
Detecting a changed `cameraInventoryRevision` afterward would be too late to
prevent that commit. The camera file lock is also advisory: an old
`ConfigurationStore.save` writer can change and restore bytes without advancing
the coordinated revision. Both paths are exercised with synthetic fixtures;
they are not production-path or GUI end-to-end tests.

The analytics settings store now checks the lock file's owner, permissions,
link count, type and identity before and after the locked operation. If that
check fails, a write may already have occurred and requires reconciliation.
This only strengthens participating settings writers; it cannot prevent a
replacement race or coordinate legacy writers and does not satisfy the camera
inventory contract. The added synthetic unsafe-lock test has not run: SwiftPM's
sandbox setup was denied in this environment.

The isolated tests exercise the real settings store CAS with synthetic data,
a synthetic inventory, stale/ABA rejection, one-shot broker approval and
readback. Before production registration, add real integrated multi-process
inventory/settings races, camera removal/re-addition ABA, GUI/discovery drafts,
reentrant publication, contention, failure/recovery and end-to-end catalog
tests. No real camera, GUI, restart readiness or crash durability is verified.

The GUI settings editor now asks for confirmation before removing a camera
override (including its zone count) or a restricted zone from its draft. The
confirmation checks that the reviewed draft content is unchanged; saving is a
separate step guarded by the existing settings revision. This is a preparatory
GUI safeguard, not production camera-inventory coordination or an end-to-end
GUI verification.

Incident and mission mutations remain registered in the legacy shared registry;
they are not registered in the scoped production broker. `registryTools` retains
its legacy entries, but the current model-facing catalogue is assembled from
the scoped broker's registered actions and transport mappings. Legacy direct
registry calls are still trusted and can execute these actions without broker
review or audit. Two **unregistered
prepared foundations**, created only by
trusted code as `ACTAPreparedIncidentAcknowledgeAction(domain:)` and
`ACTAPreparedMissionDisableAction(domain:)`, expose respectively
`incident.transition_status` (active -> acknowledged, no note) and
`mission.edit` (enabled -> disabled while idle). They require a domain that
atomically coordinates every GUI, engine, audit, scheduler, legacy and external
writer and changes the revision on every relevant write, including ABA. The
current stores do not implement that contract. The fake-only tests establish
broker review, one-shot handling, stale rejection and readback behavior, not
production storage, durability, audit integrity or side-effect safety.
Evidence deletion, mission deletion and consultation clearing remain disabled;
two-stage protection and recovery are not implemented. Cancellation after a
commit may leave a pending verification receipt that blocks further writes.
Legacy registrations and direct domain calls are not protected by this broker.

### Required integration patch (not implemented)

`UnifiedIncidentManager.localRevisionSnapshot(incidentID:)` is implemented and
used by no action. It changes on this manager's persisted-mutation attempts and
rejects an unhealthy or ambiguous local snapshot. It is **not** a shared or
durable revision, a disk/audit check, or an atomic compare-and-write.

The existing disable-only proposal below does not implement create/edit. To
integrate those actions, `WallModel.swift` must provide a model-owned capture
and compare-and-commit boundary for the complete reviewed mission change:

1. Capture the full proposed mission and prior document, `missionReviewRevision`,
   `cameraInventoryRevision`, the camera-store snapshot (including its revision),
   and feature-policy snapshot/revision under the mission access gate, camera
   gate, feature lock and camera lock, in the existing lock order. Reject
   unversioned policy where ABA cannot be excluded. Include target camera,
   schedule, enabled state, effects on active/queued runs, and the complete
   before/after values in the review.
2. On approval reacquire the same boundary and compare all captured revisions
   and state before calling the locked save, not the current
   `saveCameraMission` API which accepts no expected review. Require unique new
   IDs or the exact existing mission, preserve history, and reject any stale,
   busy, unavailable or unsafe-to-rewrite state. Cover synchronous `@Published`
   reentrancy, scheduler and cancellation effects, and quarantine uncertain
   post-commit outcomes; do not report failure as proof of no write.
3. Route every GUI/scheduler/consultation writer and participating process
   through the same revision and service lease. Advisory locks cannot protect
   against old binaries or other nonparticipants. Register prepared actions in
   the model's broker action array, add their transport mappings and only then
   restore them to the model-facing catalogue. Broker request/approval/result
   audit is separate from the JSON mission write: a result-audit failure can
   occur after the write; it is not an atomic mission/audit transaction.
4. Exercise the real model-owned boundary and broker together with synthetic
   stores: approve/deny/replay/revoke, audit failures, GUI/scheduler changes,
   camera and policy ABA, lock contention across processes, reentrant
   observers, unknown commit outcomes and history preservation. No camera or
   Keychain is needed.

The earlier disable-only integration sketch is:

```swift
// @MainActor, implemented by the model-owned mission domain:
func captureReviewedMissionDisable(_ id: UUID) throws -> ACTAMissionDisableObservation?
func commitReviewedMissionDisable(
    expected: ACTAMissionDisableObservation
) throws -> ACTAMissionDisableObservation?
```

Those signatures alone are insufficient. The same domain must own every
mutation of `cameraMissions`, `cameraMissionRuns`, `cameraMissionConsultMessages`,
`forcedMissionID`, `activeMissionID`, feature availability, and the underlying
document: initial/reload paths, `saveCameraMission`, `deleteCameraMissionChecked`,
`requestMissionRunChecked`, consultation, `finishMission`, scheduler start/end,
disconnect and feature transitions. It must compare and commit under one
non-reentrant boundary after any synchronous `@Published` callbacks, including
the idle check, and reject on every intervening write (even ABA). A queued or
running mission must not be cancelled by this action. Existing GUI callers must
use that same domain. The model now holds a mission service lease and
`saveCameraMission` locks feature and camera snapshots during the save, but it
does not compare an approved mission, camera or policy revision inside that
boundary. `CameraMissionStore.save` itself does not acquire the service lease;
another process or old binary can bypass it. Registration requires a verified
single-writer deployment or participation by *every* writer.

The feature-policy lock now rejects an unsafe or replaced lock file before or
after a locked operation. If replacement is detected after its callback, effects
may already have occurred. These checks do not prevent replacement between
checks or make nonparticipating writers cooperate. Synthetic policy tests cover
lock replacement, contention and policy ABA; they do not prove mission
capture/commit or broker integration.

For incidents the corresponding model-facing bridge is:

```swift
// @MainActor, delegates to a single coordinated incident/audit domain:
func captureReviewedIncidentAcknowledgement(_ id: UUID) throws -> ACTAIncidentAcknowledgeObservation?
func commitReviewedIncidentAcknowledgement(
    expected: ACTAIncidentAcknowledgeObservation
) throws -> ACTAIncidentAcknowledgeObservation?
```

The shared domain must subsume all `UnifiedIncidentManager` mutations and
`OperatorAuditLog.record`, including background ingestion and secondary
verification, and coordinate GUI publication in `LocalVideoAnalyticsEngine`.
`transitionStatus` additionally clears suppression state for matching incidents;
the current acknowledgement contract promises no such other effects. Either
the contract and operator review must cover those effects or the domain must
reject states where they would occur. Incident and audit are currently separate
JSON replacements, with the manager lock released before audit; a lock around
only the reviewed action cannot make them atomic. A crash-recoverable transaction
covering both files, all writers, and startup recovery is required; it must not
silently migrate or overwrite existing data. Verify complete preserved state,
audit and GUI readback under that same coordination. Do not bind either action
to the broker until these conditions and competing-process/recovery tests pass.

`canvas.get_state` is also wired for scoped model-facing inspection. It returns
only presentation, arrange mode, status and filter/selection active flags from
the unique attached view; it never returns search text, location or camera IDs.
This is a point-in-time state snapshot, not proof of rendering or connectivity,
and may be stale by the time the result is consumed. Synthetic chat, authorization,
revocation and audit-failure tests pass.

`ACTALocalActionBroker` is connected to local chat and voice inspections and
to the model-requested `settings.update_reid_calibration` action,
and to minimal read-only `camera.list`, `camera.get`, `incident.list`, `incident.get`, `alert.vlm_list`, `monitor.get_isapi_events`, `mission.list`, `reid.calibrate`, `watch.list` and
`settings.get_section` (current grid columns, stale timeout, detection threshold
and FPS), and
`analytics.get_settings` (global switches, configured mode, sensitivity,
overlays and advanced values).
`mission.history` returns bounded run identifiers, status and timestamps for
one mission, without summaries or consultation text. Like mission list, its
memory/storage comparison does not coordinate external writers.
`mission.run_now` is advertised but returns `UNAVAILABLE`: the new mission
service lease and lifecycle still require end-to-end scheduler validation.
The prepared action rejects a changed camera session or reconnect between
review and approval; this has only been checked in a synthetic lifecycle harness.
The mission service now rechecks its lock file identity and safety before reads
and mutations, at active-mutation checkpoints, and after mutations. A detected
loss permanently invalidates that service instance; a failed post-check may
follow an already-performed side effect. These checks cannot prevent replacement
between checks or coordinate older/non-participating processes. GUI camera
runtime ownership and all camera configuration writers are not yet coordinated,
so they cannot provide the cross-process camera guarantee needed to enable
`mission.run_now`.
`memory.toggle_pin` is available only when the shared narrative presentation
state is healthy, and requires review. It rejects stale state and will not pin
an unmarked chapter. Old application versions must be closed.
`settings.export_diagnostics` is available; `monitor.export_report_html` and
`mission.export_pdf` are offered when mission storage is available. The
operator selects a new destination, previews the frozen content and confirms;
the model cannot supply a path. Existing files are not replaced. The selected
directory must not be manipulated concurrently by untrusted writers.
`camera.snapshot` accepts only a camera ID; the operator selects the destination
and reviews and confirms the captured JPEG. Source validity is checked before
publication, but is not atomic with a concurrent camera stop.
`identity.set_follow_up` requires review and sets only an operator reminder,
not an identity determination. Uncertain outcomes block changes until the
operator inspects and acknowledges the stored flag in the identity screen.
Older application versions must be closed; crash durability is not proven.
Analytics checks runtime against persisted settings, but does not expose camera
overrides, drafts or engine health, and does not coordinate external writers. The watch
list compares GUI and stored rules but does not coordinate external writers.
ISAPI inspection similarly compares GUI and stored history and exposes only event
IDs and received times, not camera IDs or untrusted event text; external writers
are not coordinated.
Other model-requested
registry mutations and legacy action confirmations are rejected. Direct GUI
and domain calls and scheduled work are not protected by this broker.

The intended UX is that model-requested inspections run only in a scoped local
session, while **every model-requested mutation needs operator approval**.
The model sees only that approval is required, not the review handle, token,
title or parameters. GUI/domain operations retain their existing behavior;
schedules and other initiators must not be assigned a broker session until
separately authorized.

Trusted host code must retain the operator and session capabilities in process,
restrict each session to explicit action IDs and a trusted thread, intersect
model calls with the actual request catalogue, and provide a durable audit
sink. Audit events do not contain parameter values. Failed pre-execution audit
prevents execution; failed post-execution audit reports that execution may have
occurred. Inspection output still requires action-specific privacy review.

`ACTABrokerReviewView` is a separate trusted UI component: it displays the
complete title, thread, action and parameters in an unambiguous escaped form,
requires an explicit acknowledgement before approval, and can reject without
acknowledgement. Values with URL-like content, sensitive field names, or
excessive size are rejected before execution. These heuristics do not identify
every possible secret; the view must remain private and the host must not log,
persist or send its review to the model. Review approval does not prove a human
saw the display.

**Integration limitation:** local sessions currently receive named inspection
capabilities for all retained cameras, not an operator-selected camera subset.
The broker has a session-bound camera-ID grant check with an empty default, but
production history and legacy inspection paths do not use it. It is not an
effective restriction on those paths and is not a substitute for their audit or
revocation checks.
The review component is used for these window-local actions only. Remaining actions need
their own authorized integration, privacy review and domain-level freshness
checks. Approval of parameters alone is not a state snapshot.

Capabilities are not an OS security boundary. Closing a session revokes future
work; it cannot undo an operation already started. Reviews are in-memory and
expire conservatively, and are lost on process restart.
Cancellation during execution or verification is reported as `ACTION_CANCELLED`.
For a confirmed mutation this does not imply rollback: a side effect may already
have occurred.

Six reviewed analytics mutations are registered: `analytics.set_global_toggle`,
`analytics.set_threshold`, `analytics.set_sampling_fps`, `analytics.set_overlay`
`analytics.set_sensitivity_profile` and `analytics.set_execution_mode`. Execution
mode changes the saved setting only; it does not switch routing or establish
distributed worker readiness. These actions use the live engine and can stop
and restart analytics; a successful settings readback does not establish that
the detector is healthy. Camera overrides and zones are not covered.

The engine uses a local reentrancy gate and compare-and-save snapshots; editor
drafts capture a local revision and stale drafts are rejected. The settings
store uses an advisory lock and a separate UUID revision file to detect
cooperating writes and ABA; it rejects lossy, incomplete, duplicate or unknown
JSON fields. Old application versions must be closed, and arbitrary external
writers can bypass this protocol. Unconditional store saves are serialized but
do not themselves prevent stale overwrites. The revision is written before the
settings file, but crash/power-loss durability has not been established. A
failed audit or cancellation can occur after a side effect; it is not a
rollback. Lock contention is reported rather than silently overwritten.
If initial settings loading fails, analytics does not start and the error stays
visible. After a stale external change or failed initial load, restart the app
to reload the engine; reopening the editor alone does not reload storage.

Camera flag preparation is available only as an unregistered foundation:
`ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)` implements
`camera.set_enabled`, and `ACTAPreparedCameraFlagsAction(kind: .processing,
domain: domain)` implements `camera.set_processing` (`yolo` or `ai_chat`).
Construct them on the main actor only after supplying an independently audited
`ACTACameraFlagsReviewDomain`; do not add them to the production broker today.
The contract requires one atomic cross-process boundary covering GUI and legacy
writers, unique revisions including ABA, consistent memory/disk state, and
exclusion of all immediate service effects. Current WallModel setters do not
provide it: enabling can reconnect, and YOLO changes detection state. Future
service starts may use a changed flag. Readback does not establish crash
durability or device readiness. UUID-only arguments and fixed errors exclude
camera names, endpoints and domain error details from these actions' reviews
and outputs; the contract itself does not establish an OS security boundary.

#### Camera writer patch interface (not wired)

`ACTACameraWriterGate` is a concrete **process-local** synchronous gate.
It rejects nested writes/reads and invalidates observations on every attempted
write, including one that throws. It is not a storage lock or a production
domain. Merely wrapping the three toggle callbacks does not make these actions
safe.

The smallest integration boundary needed in `WallModel` and its shared store is:

```swift
// One instance per authoritative configuration, not one per view or action.
@MainActor let cameraWriterGate: ACTACameraWriterGate

// All readers used by reviewed actions:
let snapshot = try cameraWriterGate.capture {
    try authoritativeStore.readConsistentCameraAndRuntimeState(cameraID)
}

// All GUI/legacy writers, including unsuccessful and no-op attempts:
try cameraWriterGate.write {
    try authoritativeStore.mutateAndPublish(/* the existing operation */)
}

// Reviewed write: both checks and the mutation must be inside this body.
try cameraWriterGate.writeIfCurrent(snapshot.revision) {
    try authoritativeStore.compareRevisionMutateAndPublish(/* durable revision,
                                                               identity, runtime, flag */)
}
```

`authoritativeStore` above is a required **new implementation**, not an
existing API. Its compare-and-mutate operation must use a single cross-process
transaction for complete configuration, unique camera identity, a non-reused
durable revision, and all relevant runtime/effect eligibility; it must reject
stale or unsafe state without writing. Each process must share that authority;
a file lock is only advisory and cannot exclude an old binary or arbitrary
writer. Existing `ConfigurationStore.save` uses atomic file replacement without
CAS or a durable generation, and cannot implement that transaction. A safe
cutover therefore requires an explicit migration/rollback and a way to exclude
uncoordinated writers; until both are proved, reject reviewed writes.

`WallModel.apply` now uses the gate, writer lease and CAS, with fail-closed
handling after an uncertain publication. Thirteen isolated writer tests passed;
WallModel integration has only been syntax checked. This does not coordinate
the full runtime lifecycle, stale GUI drafts, Keychain or older writers.

For the remaining integration, route **every** configuration mutation through the same gate and
authority, not just `setEnabled`, `setYOLOEnabled`, and `setAIChatEnabled`:
`setYOLOEnabledForAll`, `updateCameraPreference`, `apply`, `applySettings`,
`saveSystemSettings`, bookmark refresh in `connectFile`, startup/worker
provisioning, and the direct detection-setting setters. Replace
`DefaultACTASystemSettingsProvider.saveConfiguration` and any other
`ConfigurationStore.save` consumer too. Lock down direct `config` mutation,
coordinate runtime start/stop and other state influencing effects, and audit
all callbacks and other processes. Avoid nesting `write` when one operation
calls another: only the outer transaction owns the gate. Preserve existing
GUI effects separately; reviewed mutations may not invoke `apply`/reconnect or
YOLO reset unless those effects are explicitly reviewed and verified.

`@Published` currently calls observers before installing `config`. A reviewed
commit also needs a publication mechanism that cannot allow observers to act
on partial or old state; a gate around the existing assignment alone is not
proof. On an uncertain storage/publish failure, quarantine the domain until
recovery rather than claiming rollback. Extend the action snapshot with both
the gate's identity revision and the store revision; the existing UUID alone
is not a cross-process proof. Finally create the two actions with the **same**
audited domain at broker construction and add their IDs only after integration
tests cover GUI/legacy, reentrancy, ABA, cross-process, crash recovery, audit
and service effects. No such production adapter or registration exists now.

Window-local adapters track intervening changes, including ABA, with process-local
revisions, but do not coordinate with external writers. The five reviewed canvas
and analysis actions commit a single state snapshot after synchronous observers
have run and freshness checks have been repeated. Leaving Chat is rejected while
voice input is starting or recording. Window state now publishes object-level
changes rather than individual `@Published` field publishers; actual SwiftUI
rendering and microphone behavior have not been verified. If a root window
`onDisappear` callback were delivered after a later reappearance, its unscoped
teardown could stop the newer voice attempt and detach the active state; this
ordering has not been verified or excluded. Direct registry adapters are not a
security boundary. Session revocation during an already-started asynchronous
mutation does not guarantee prevention of its side effect.

The broker can review `settings.update_system` for interface language only when
the application supplies its live language settings instance. It checks the
in-memory revision and stored language before committing and verifies readback;
external UserDefaults writers are not coordinated. Language changes publish
object-level notifications rather than an individual `@Published` publisher.

The mission panel's HTML export now renders a frozen snapshot of actual mission
runs, asks the operator for a destination, shows all escaped HTML and its
destination, and asks for a separate final confirmation. It creates a private
file without replacing an existing name and checks the published bytes. Failure
may leave a file: inspect the destination before retrying. The operator must
choose a directory not concurrently manipulated by untrusted processes; this
is not a defence against hostile renames or writers, and power-loss durability
is not established. The save panel and actual GUI interaction have not been
exercised in tests.

The same real renderer and publisher can be used by the prepared
`monitor.export_report_html` action, but it is **not wired into the production
agent**. To wire it, append
`ACTAMissionHTMLExport.make(runs: self.cameraMissionRuns)` to `actions` in
`WallModel.askACTAAgent` before deriving `actionIDs`; in
`ACTAAnalyticsCoordinator.brokerActionIDs`, map
`"acta__monitor__export_report_html"` to `"monitor.export_report_html"`.
The captured runs are a snapshot at broker creation, not live at approval.
Retain the existing broker review UI and durable audit; do not accept report
bytes or paths from the model. Session revocation after publication starts is
not guaranteed to stop it. Other export types are not covered by this path.
