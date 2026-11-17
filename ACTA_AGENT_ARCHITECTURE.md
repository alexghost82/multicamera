# ACTA — macOS Swift Agent Full Control & Local Qwen Inference
Version: 2026-11-17 · Design specification · NOT an implementation report

## 0. Scope and baseline
- Repository: `alexghost82/multicamera`; remote `main` observed at `94127031e02232dd7bfe16d73c612987a8a8d715` on 2026-11-17.
- Remote tree inspection showed 267 entries, including `native/Package.swift`, `ACTAAnalyticsCoordinator.swift`, `ACTAAIClient.swift`, `LocalVoiceInput.swift`, `ACTAKnowledgeAndMemory.swift`, `SettingsHubView.swift`, and tests. This does **not** verify local working-tree state or runtime.
- Modify **only native macOS Swift ACTA application** and its explicitly required local test/configuration assets. No DGX, remote workers, cloud inference, external server, or unrelated Python/Kotlin systems. Do not silently delete existing optional integrations; leave unrelated code untouched.
- Goal: every user-accessible ACTA operation and setting must be discoverable and controllable by the agent through text and voice, subject to permissions and confirmations. “All” means verified parity with existing GUI and backend capabilities, not unrestricted arbitrary code execution.

## 1. Non-negotiable design principles
1. Inventory first: enumerate every SwiftUI control, settings field, command, camera lifecycle operation, analytics option, event/incident/evidence workflow, memory/identity operation, diagnostic and export action. Produce `GUI_TO_AGENT_COVERAGE.md` with unique action ID, UI path, owner/service, arguments, read/write classification, authorization, confirmation, tests, and status. No blanket claims of 100% until coverage is verified.
2. Single source of truth: both GUI and agent call the same domain service; do not automate UI clicks or duplicate business logic.
3. Typed `ACTAActionRegistry` with schemas, validation, authorization, execution, structured result, error codes, audit trail, and read-after-write verification. All writes serialized where needed; transactional rollback/compensation for multi-step changes.
4. Separate read-only inspection, reversible settings, service-affecting operations, and destructive/privacy-sensitive actions. Explicit user approval for destructive or security-critical changes; do not allow prompt injection to grant permission.
5. Local-only by default: images, audio, memories, credentials, and video never leave Mac through agent inference. No automatic cloud fallback. Secrets in Keychain; redact logs.
6. Maintain existing camera connectivity, Pose/FSM, event engine, memory, localization, migration compatibility and performance protections.

## 2. Architecture
```
SwiftUI / Text chat / Microphone
          |
 Local ASR -> Intent/Conversation Orchestrator -> Local TTS
          |              |            |
          |         Memory Retrieval   |-- Qwen inference adapter (OpenAI-compatible)
          |                           |
          +-------------------- ACTAActionRegistry
                                    |
                        Policy / approval / validation
                                    |
                  Existing Swift domain services and stores
                                    |
                  Camera / analytics / incidents / memory / settings
```
- Use actors for mutable shared state; bound queues, cancellation, deadlines, per-action idempotency keys, generation IDs for stale async results.
- Agent reports executed, rejected, failed and unverified outcomes separately; never claim success from a model response alone.
- Multi-turn speech: push-to-talk MVP; interruption/barge-in and full duplex only after latency/resource validation. ASR/TTS use local macOS APIs or verified offline engines. Clearly surface microphone permission and listening state.
- Memory retrieval required for history-dependent questions; citations to camera/event/frame/time; distinguish observed facts, AI hypotheses and operator-confirmed corrections. Errors observable, retention/backup/restore and prompt-injection boundaries preserved.
- GUI must show agent tool actions, approvals, diagnostics, and voice/inference status; preserve RU/EN and accessibility.

## 3. Qwen inference on Apple Silicon — verified upstream implementation
- **Confirmed upstream:** `https://github.com/vllm-project/vllm-metal` is a community-maintained Apple Silicon hardware plugin in the `vllm-project` organization, supporting macOS 15+ and using MLX/Metal for compute while retaining vLLM scheduling/API infrastructure. Source: upstream README, checked 2026-11-17.
- **Official support matrix:** `https://github.com/vllm-project/vllm-metal/blob/main/docs/supported_models.md` lists Qwen3 and Qwen3.5/3.6/3.8 as supported on MLX; hybrid model prefix caching is experimental. An example checkpoint is `mlx-community/Qwen3.8-27B-8bit`, **not** a recommendation for a 24GB Mac without memory testing.
- **Installation documented by upstream:** `brew tap vllm-project/vllm-metal https://github.com/vllm-project/vllm-metal` followed by `brew install vllm-project/vllm-metal/vllm-metal`. Treat these as documentation, **not** authorization to install.
- vLLM Metal is the **preferred target** for ACTA, not an unverified speculative option. However, target-machine compatibility of the selected exact Qwen checkpoint, quantization, tool-calling format, streaming, simultaneous requests, latency, peak unified memory, camera workload interference and runtime lifecycle remains a mandatory integration/benchmark gate.
- Test OpenAI-compatible local loopback endpoints, streaming, cancellation, batching, bounded concurrency and error semantics. Require explicit configuration and no remote fallback. Measure TTFT, tokens/s, p50/p95 latency, queue depth, unified memory, thermal throttling and live camera/analytics responsiveness.
- Do not silently substitute MLX-LM standalone or a different inference engine if the target checkpoint fails. Report precise failure and seek approval for model/runtime changes. No DGX, Linux VM, Docker or cloud service.

## 4. Phases / acceptance
### Phase 0 — read-only audit and inventory
- Record local path, branch, HEAD, `git status`, build/test commands, machine specs, actual model and inference configuration.
- Map all UI controls to domain services, settings persistence, agent tools and permissions. Compare against remote HEAD but treat local uncommitted work as authoritative; no reset/checkout/overwrite.
- Audit existing voice, Qwen, AI tool-calling, memory, incident/evidence, analytics lifecycle, model loading and security.
- Output gap matrix and implementation plan with effort/risk. Stop for approval of architecture and any destructive migration.

### Phase 1 — action layer
- Add protocol-based registry and adapters to existing services, with schema, capability discovery, action results and unit tests.
- Read-only operations first; then reversible settings, camera connect/disconnect, analytics controls, incident review, memory search and safe exports.
- Build GUI↔agent parity tests for every inventoried operation. Unknown or unsupported actions must return explicit `UNSUPPORTED`.

### Phase 2 — local voice and conversation
- Offline speech recognition, streaming conversation, local voice response, interruption policy, language selection, mic permissions, on-device privacy.
- Confirmation dialogue for sensitive actions and spoken status with traceable operation ID.
- Test noisy speech, ambiguous camera names, accidental activation and canceled operations.

### Phase 3 — Qwen serving
- vLLM Metal integration spike on target Mac using the upstream Apple Silicon plugin; model-specific and performance acceptance evidence required before integration.
- If approved and feasible, integrate bounded parallel inference with model load/unload, health, backpressure and fallback **only to explicitly approved local runtime**.
- Stress-test concurrent speech, memory retrieval, camera analytics and agent actions.

### Phase 4 — reliability and release gates
- Regression: camera RTSP/USB, Pose/FSM, fall/fight heuristics, event evidence, SQLite migrations, ACTA naming compatibility, local_only, app restart, cancellations and stale inference.
- Build/test on target Mac; 64-camera claims require actual E2E benchmark, not scheduler-only tests.
- Security, privacy, resource, localization, signing/notarization and rollback verification.
- Production NO-GO unless all acceptance evidence is available.

## 5. Definition of done
- Every existing user-exposed function has a coverage row and either a working typed agent action or a documented, approved exclusion.
- No action without authorization; critical actions require explicit approval; every mutation has observable result and audit.
- Text and voice can execute equivalent supported operations; no remote data transfer; no GUI freeze.
- vLLM Metal + selected Qwen checkpoint proven on target hardware with measured concurrency; otherwise unresolved model/performance gate clearly documented.
- All tests pass; no silent data migrations, loss of credentials or evidence, or regressions.
- Provide `IMPLEMENTATION_REPORT.md` with changed files, commits/diffs, commands/results, performance numbers, open risks and rollback instructions.

## 6. Open decisions
- Exact local Mac hardware/RAM/macOS/Xcode and Qwen model/quantization.
- Exact vLLM Metal version and supported Qwen checkpoint/quantization, including acceptable resource limits.
- Approval policy for camera deletion, evidence export/deletion, identity merge, network/security settings.
- Target interactive latency and acceptable analytics performance budget.
