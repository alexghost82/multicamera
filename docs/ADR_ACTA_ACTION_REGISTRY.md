# ADR-001: Unified ACTA Action Registry & Shared Domain-Service Adapters

- **Status:** Proposed  
- **Date:** 2026-11-17  
- **Context:** Native Swift macOS ACTA (`alexghost82/multicamera`)  
- **Authors:** Implementation Engineer & Reviewer  
- **Supersedes:** Hardcoded switch in `ACTAAnalyticsCoordinator.swift:1454` and `reviewAndExecuteChatAction:2535`  

---

## 1. Context and Problem Statement

The ACTA macOS application contains 108 distinct user-accessible operations across Camera management, Video Analytics, Safety Incidents, Identity Tracking, Missions, Memory, Watch Rules, and 14 sections of `SettingsHubView`.

Currently:
1. Only 16 read-only query tools exist in `ACTAAnalyticsCoordinator.swift`.
2. Only 3 mutations (`rename_identity`, `merge_identities`, `split_identity`) are supported in `reviewAndExecuteChatAction`.
3. The remaining 89 operations can only be executed by manually clicking through SwiftUI controls.
4. Business logic is partially split between SwiftUI view callbacks (`WallView`, `SettingsHubView`) and domain services (`WallModel`, `LocalVideoAnalyticsEngine`, `CameraFeatureCoordinator`).
5. Natural language voice and text requests cannot safely or predictably control camera configurations, detection parameters, incident states, or runtime settings.

ACTA requires a unified, typed, auditable, actor-isolated action registry where both GUI buttons and Agent invocations (text and voice) execute the exact same domain service adapters without duplicating business logic or bypassing safety checks.

---

## 2. Decision Drivers

- **Parity Principle:** Anything the user can do in the GUI must be controllable via natural language, subject to policy and confirmation.
- **Single Source of Truth:** View controls and agent tools must call identical domain service methods.
- **OpSec & Safety:** Destructive actions (camera removal, evidence deletion, identity merging, clearing credentials) must require explicit two-phase operator confirmation.
- **Concurrency & Actor Isolation:** Seamless interop between `@MainActor` UI services (`WallModel`) and background actors/threads (`LocalTrackingStore`, `CameraMemoryStore`, inference engines).
- **Read-After-Write Verification:** Actions must programmatically verify that requested mutations actually took effect in the underlying stores before claiming success.
- **Auditability:** Complete execution history preserved in SQLite (`ghost_chat_actions`, `ghost_chat_tool_calls`).

---

## 3. Architecture Design

```
+------------------------------------------------------------------------+
|                      User Interaction Layer                            |
|       SwiftUI Views  /  Text Chat  /  Local Voice (ASR & Push-to-Talk) |
+-----------------------------------+------------------------------------+
                                    |
                                    v
+------------------------------------------------------------------------+
|                     ACTAActionRegistry (Actor)                         |
|  - Capability Discovery & OpenAI-Compatible Tool Schema Generation     |
|  - Permission & Policy Evaluation (Inspect, Reversible, Destructive)   |
|  - Idempotency & Rate Limiting                                         |
|  - Two-Phase Confirmation Coordinator                                  |
|  - Audit Logger (SQLite ghost_chat_actions / tool_calls)               |
+-----------------------------------+------------------------------------+
                                    |
                                    v
+------------------------------------------------------------------------+
|                     Shared Domain Service Adapters                     |
|  - CameraServiceAdapter           -> WallModel, Go2RTC                 |
|  - AnalyticsServiceAdapter        -> LocalVideoAnalyticsEngine         |
|  - IncidentServiceAdapter         -> SafetyIncidentStore, Evidence     |
|  - IdentityServiceAdapter         -> LocalTrackingStore, Resolver      |
|  - MissionServiceAdapter          -> CameraMissionEngine               |
|  - MemoryServiceAdapter           -> CameraMemoryStore, Narratives     |
|  - SettingsServiceAdapter         -> WallConfig, VLM, Features, Runtime|
+-----------------------------------+------------------------------------+
                                    |
                                    v
+------------------------------------------------------------------------+
|                     Read-After-Write Verification                      |
|  Query persistent stores (SQLite, JSON, Keychain) to confirm state     |
+------------------------------------------------------------------------+
```

---

## 4. Detailed Component Specifications

### 4.1 Typed Action Protocol (`ACTAActionProtocol`)

```swift
public enum ACTAActionClassification: String, Codable, Sendable {
    case inspect           // Read-only query (Auto-approved)
    case reversible        // Non-destructive mutation (Auto-approved or single notice)
    case serviceAffecting  // Reloads streams, models, or network (Notice provided)
    case destructive       // Permanent loss of data or identity (Requires explicit operator confirmation)
}

public struct ACTAActionParameterSchema: Codable, Sendable {
    public let name: String
    public let type: String // "string", "number", "integer", "boolean", "array", "object"
    public let description: String
    public let isRequired: Bool
    public let allowedValues: [String]?
}

public struct ACTAActionResult: Codable, Sendable {
    public let actionID: String
    public let success: Bool
    public let summary: String
    public let outputData: [String: AnyCodable]
    public let verified: Bool
    public let error: String?
}

public protocol ACTAActionProtocol: Sendable {
    var id: String { get }
    var title: String { get }
    var description: String { get }
    var classification: ACTAActionClassification { get }
    var parameters: [ACTAActionParameterSchema] { get }
    
    func execute(
        parameters: [String: AnyCodable],
        context: ACTAActionContext
    ) async throws -> ACTAActionResult
    
    func verify(
        parameters: [String: AnyCodable],
        context: ACTAActionContext
    ) async throws -> Bool
}
```

### 4.2 Actor Isolation & Concurrency

- `ACTAActionRegistry` is an `actor`. It serializes concurrent mutation requests to prevent race conditions on shared files (`cameras.json`, `vlm.json`, `features.json`) and SQLite tables.
- UI state updates and `@MainActor` service calls are bridged via `await MainActor.run { ... }`.
- Read-only tools (`inspect`) can run concurrently.
- Per-action cancellation tokens and timeouts (default 15 seconds) prevent hung network or device calls from blocking the agent loop.

### 4.3 Two-Phase Confirmation Flow for Destructive Actions

When an action with `.destructive` classification is invoked:
1. `ACTAActionRegistry` creates an `ACTAChatActionRecord` with status `"proposed"` in `ghost_chat_actions`.
2. A unique confirmation token is assigned (e.g. `ACTA-CONFIRM-7F2A`).
3. The agent formats a clear spoken and textual confirmation prompt to the operator:
   > *"Внимание: удаление камеры 'Вход во двор' приведет к остановке записи и анализа. Подтвердите удаление (Да / Отмена)."*
4. The execution is suspended until:
   - The operator confirms via Voice (detected affirmative response) or UI click on the confirmation banner.
   - Or the operator cancels / timeout expires (5 minutes).
5. Upon confirmation, the registry executes the underlying adapter and verifies state removal.

### 4.4 Read-After-Write Verification

Every mutating action implementation is required to verify its result:
- **Camera Configuration:** After `camera.add_network`, the adapter reloads `model.config.cameras` and verifies the camera ID and RTSP URL are present and active.
- **Analytics Toggles:** After `analytics.set_global_toggle`, the adapter reads back `engine.settings` to verify the flag changed.
- **Settings Persistence:** After modifying `VLMPreferences`, `ModelSelectionPreferences`, or `AdvancedRuntimePreferences`, the adapter re-reads the JSON file from disk to ensure atomic write succeeded.
- If verification fails within 2.0s, the action returns `verified = false` with an explicit diagnostic code, preventing false "success" reports to the user.

### 4.5 Audit Trail and Observability

Every execution (whether initiated by Text, Voice, Automation, or UI) is recorded into `ghost_chat_actions` and `ghost_chat_tool_calls` with:
- Timestamp & Execution Duration (ms)
- Action ID & Arguments JSON
- Initiator: `text_chat`, `voice_asr`, `ui_direct`, `mission_schedule`
- Pre-execution validation status
- Operator confirmation record (if destructive)
- Post-execution verification verdict

---

## 5. Consequences & Trade-offs

### Positive
- **Complete Parity:** The agent gains the ability to control 100% of app features and settings.
- **Guaranteed Safety:** Prompt injections cannot trick the model into silently deleting cameras or clearing evidence; destructive actions are intercepted by the registry before reaching domain services.
- **Zero UI Duplication:** UI buttons and agent tools share the exact same domain adapters.
- **Testability:** Every action can be unit-tested via automated round-trip tests (`Action -> Execute -> Verify`).

### Negative / Mitigations
- *Code Size Increase:* Introduces ~2,000 lines of typed action declarations and adapters.  
  *Mitigation:* Use clean generic protocols and grouping by domain modules (Camera, Analytics, Settings, Incident, Identity, Memory).
- *Latency Overhead:* Read-after-write verification adds ~5–20 ms to mutations.  
  *Mitigation:* Verification is performed asynchronously in background tasks and does not block the UI thread.


## Phase 1 implementation checkpoint — 2026-11-17

This ADR remains only partially implemented. Current code adds primitive validation,
explicit unsupported results, security-sensitive and per-feature confirmation gates,
MainActor live settings/analytics providers, an eleven-action model catalogue, durable
operator proposals, pre-execution tool audit and one-shot UI token review. Overlapping
registry mutations are rejected with ACTION_BUSY, not queued. Mutations without an
explicit verifier fail verification.

Unimplemented: full GUI parity, remaining domain adapters, complete authorization,
durable idempotency, deadline/cancellation policy, transactional compensation across
files and SQLite, recovery of pending tokens after restart, and universal GUI audit.
Read IMPLEMENTATION_REPORT.md for exact validation evidence and limitations. The
positive consequences above are design goals, not verified completion claims.

Operational follow-up on baseline ad95a8c: seven additional runtime adapters now call
shared incident, watch and memory services (18 advertised actions total). Tests verify
persistent status/notes, watch lifecycle, operator-gated physical deletion and disabled/
corrupt-storage failures. Bulk memory deletion and cross-store crash compensation
remain unimplemented. See the operational checkpoint in IMPLEMENTATION_REPORT.md.

Analytics/canvas follow-up: 26 advertised actions, complete advanced numeric/global
flag/overlay tables, strict rejection before writes, camera-specific effective reads,
rectangle-zone lifecycle and verified canvas state/layout. Profiles, full per-camera
fields and polygon/policy edits remain missing; no full-GUI-parity claim is made.

Further Phase 1 checkpoint: 31 advertised actions with global profile selection/apply,
complete per-camera detector/profile/rate fields, zone UUID policy/point editing and
reviewed narrative pin/text mutations preserving aiSummary. The operator can expand
full redacted parameters before approval. Localization gate now covers the action
layer; no full hardware/model/accessibility coverage is claimed.

Mission checkpoint: 39 advertised actions; mission CRUD/history and asynchronous
run/consult admission share GUI services and preserve default JSON paths. Corrupt/stale
mission snapshots are rejected before writes; delete/consult clear require review.
Saved runs survive mission deletion and are attributable through the evidence ledger.
Queue admission is not inference completion; real model/camera and restart recovery
remain open acceptance gates.

Camera checkpoint: 45 advertised actions with disabled source registration, metadata
editing and per-camera processing flags. Receipts certify configuration, not capture.
Specific validation runs before proposals; secret-bearing URL arguments are rejected.
Keychain identifiers are unchanged; a testable credential store supports checked delete
and best-effort compensation on config failure. Cross-endpoint credential reuse requires
the secure native editor. Real discovery/capture/Keychain/reconnect remain runtime gates.
