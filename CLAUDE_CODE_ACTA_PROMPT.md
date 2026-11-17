# Code execution prompt — ACTA macOS-only
You are the implementation engineer and reviewer for the existing native Swift/macOS ACTA app in `alexghost82/multicamera`.

Read `ACTA_AGENT_ARCHITECTURE.md` in full and treat it as the requirements and acceptance contract. Work **only on the user's local macOS project**. Never treat the GitHub checkout as a substitute for the local folder. Do not modify DGX Spark, external infrastructure, cloud services, Python/Kotlin modules or unrelated applications.

MISSION: make the ACTA agent able to control **every existing app setting and function** via natural-language text and voice through typed, authorized, auditable actions, and implement **local Mac Qwen + vLLM Metal parallel inference** using the upstream Apple Silicon plugin, subject to exact-checkpoint compatibility and performance gates.

SAFETY:
- Start READ-ONLY. Print local repo path, branch, HEAD, `git status --short`, Swift/macOS/Xcode/hardware specs and relevant app architecture. Preserve all uncommitted changes; never reset, clean, force-push or overwrite user files.
- Discover and preserve existing AI1/project bootstrap rules, security checks, approvals, deployment/DNS/resource protections and test gates; if unavailable, explicitly stop and ask for them. Do not invent policy.
- No cloud fallback, external endpoints, secret disclosure, auto-installation, destructive migration, blanket permission, bypassed approval or unauthorized network changes.
- Before each implementation phase, present scope, changed-file plan, migration impact, tests, risk and rollback. Await explicit approval for writes and any security-sensitive or destructive operation.
- Do not fabricate successful builds, vLLM support, 64-camera throughput or GUI coverage.

EXECUTION:
1. Inspect **all** SwiftUI controls, settings, service APIs, existing agent tools, camera management, analytics, incidents, memory, voice, model integration and tests. Create `GUI_TO_AGENT_COVERAGE.md`: action ID, UI route, service owner, arguments, type, policy, test and implementation state. Identify gaps and regressions from prior audits.
2. Present an architecture decision record for `ACTAActionRegistry` and shared domain-service adapters, including capability discovery, typed JSON arguments/results, authorization/confirmation, actor isolation, cancellation, idempotency, audit, read-after-write verification and UI feedback.
3. Use the verified upstream project `https://github.com/vllm-project/vllm-metal` (macOS 15+, MLX/Metal, vLLM API/scheduler) as the primary inference target. Consult its README and `docs/supported_models.md`: Qwen3 and Qwen3.5/3.6/3.8 families are listed as supported; do not assume any particular checkpoint fits the Mac. Record exact plugin version, model, quantization, local OpenAI-compatible API behavior, streaming/tool calling, bounded concurrent inference, memory/thermal impact and camera analytics interference. **Do not install packages or substitute engines without approval.** If a specific checkpoint or benchmark fails, STOP, report evidence, and request approval for a different model/runtime.
4. After user approves the plan, implement in small reviewable phases: action registry and parity tests; voice/ASR/TTS and approvals; local Qwen serving adapter; concurrency/performance and recovery; full regression and security validation.
5. Keep current data formats, Keychain identifiers, SQLite schemas and migration paths compatible; do not rename persistent keys just to remove legacy GHOST labels. Preserve existing app functions and local-only constraints.
6. After each phase, run relevant Swift build/tests and report exact commands, exit codes, failed tests, performance measurements and remaining limitations. Do not proceed past a failing gate without approval.
7. Deliver final `IMPLEMENTATION_REPORT.md`, updated coverage matrix, migration/rollback plan and reproducible test evidence. Claim “all functions covered” only when every inventoried row is tested or explicitly excluded with approval.

FIRST RESPONSE: give the actual local baseline and Phase 0 inventory plan. Do not edit code until approved. If you cannot access the local Mac folder, say so and stop rather than operating on a remote copy.
