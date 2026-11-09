# Карта зависимостей выбранных функций

## Контекст

- `MODE`: `ANALYZE`; выбраны все 14 ID из source inventory.
- Source: `/Users/alexandr.bogdanov/Documents/multicamera/giraffai-main`.
- Target/output: `/Users/alexandr.bogdanov/Documents/compare`.
- Target на момент анализа содержит только `SOURCE_FUNCTIONAL_INVENTORY.md`; application code, manifests, tests, API contracts и архитектурные инструкции не обнаружены. Поэтому target side указан как `UNKNOWN / NOT PRESENT`, а интеграционные рекомендации ниже являются кандидатами, не утверждёнными решениями.
- Source исследовался статически. Никакие приложения, тесты, hardware, AI, network, install/deploy действия не выполнялись.

## Системный граф зависимостей source

```text
React UI (HTTP / SSE / MJPEG / WebSocket)
  -> FastAPI routes + auth/rate-limit middleware
    -> Supervisor singleton
      -> SourceManager -> SourceReader -> AVFoundation/OpenCV | file | link/screen
      -> ChannelWorker/optional VisionEngine -> YOLO segmentation + tracker
        -> cropper/quality/capture scheduler -> ONNX embeddings/attributes
          -> ObservationSink -> IdentityService (serialized) -> SQLite + media files
      -> background pollers -> AI/ops/knowledge services -> SQLite + events/files

Separate process: ghost_watcher -> read-only probes/door -> main API + host OS
                              -> optional cloudflared/public shares/backup relay
```

Граф отражает код и документацию, но не runtime execution evidence.

## Функциональные зависимости

| ID | Прямые source зависимости | Необходимые транзитивные зависимости / контракты | Необязательные / gated зависимости | Сложность и интеграционный минимум |
| --- | --- | --- | --- | --- |
| `CAP-01` | `api/sources.py`, `api/devices.py`, `api/channels.py`, `Supervisor`, `SourceManager`, source backends, SQLite models | `source -> channel` FK/lifecycle; source reader ownership; async/thread shutdown; timestamps/resolution; camera unique ID; upload path | AVFoundation/macOS TCC; optional link tunnel, phone ingest, screen capture, shared memory | Высокая. Минимум: source abstraction + lifecycle service + explicit permission/error contract; не переносить весь UI/runtime до выбора target платформы. |
| `CAP-02` | `ChannelWorker`, detector, cropper, capture scheduler, embedder, stream API, media storage | frame fan-out; model cache/weights; ByteTrack state per stream; process-wide detect semaphore; `CropObservation`; storage path contract; preview pacing | MPS/CoreML/CPU; high-resolution model profile; local child process mode; Redis transport | Очень высокая. Минимум: bounded frame input, per-channel processor, explicit output record/media adapter; hardware/backend contract обязателен. |
| `ID-01` | `IdentityService`, resolver/scoring/gallery/index, identity API | stable IDs; sighting/tracklet lifecycle; SQLite transaction/foreign-key expectations; normalized embeddings; lock ownership; audit; deletion/retention | HNSW approximate index; chroma; contextual topology; background dedup/split | Очень высокая. Минимум: domain service + repository and migration of all identity relationships together; do not integrate as isolated API endpoints. |
| `AI-01` | `describe.py`, `gate.py`, privacy, budget, client, schemas, describe API | crop media availability; identity-level candidate selection; claim/reap semantics; `ai_analyses`/`ai_attributes`; event/UI status | OpenAI/local model; optional redaction settings | Высокая. Минимум: provider interface, consent/budget gates, typed result schema and persisted run state. |
| `AI-02` | `research_agent.py`, `ai_ask.py`, tool registry, DB/image/SQL tools | read-only DB view; thread/message/tool-call persistence; SSE event schema; cited source IDs; image authorization; budget and prompt rules | Responses API; local dry-run; image uploads under policy | Высокая. Минимум: tools over a read-only application query service; no arbitrary target DB access. |
| `AI-03` | `ai_chat.py`, chat service, voice service, action persistence, identity/watch/role services | operator identity/role; thread-scoped context; action state machine (`proposed -> confirmed/rejected`); audit; upload limits | OpenAI/realtime voice; transcription/voice provider | Высокая. Минимум: proposal/confirmation API with server-side authorization and idempotent audited execution. |
| `MEM-01` | narrative sampler, ChannelWorker, Supervisor narrative queue, `narrative.py`, ghostmemory API/store | live frame timestamps; channel config; serialized queue; chapter schema; media path and lifecycle; privacy/budget | OpenAI/local vision; user-configurable sampling | Высокая. Минимум: independent sampler/queue with per-channel opt-in and durable chapter repository. |
| `OPS-01` | critical/crowd services, Supervisor pollers/queues, alert storage/API | live preview source; per-camera rules; queue backpressure; notice/event/history; clip retention; privacy/budget | AI provider; optional clip/share/voice report | Очень высокая. Минимум: event evaluator and durable alert store; keep frame sampling separate from model calls and UI. |
| `OPS-02` | missions/watch/consult/briefing/report/realtime APIs and services | channel lifecycle and preview; schedule/timezone semantics; persisted threads/runs; per-camera concurrency; report artifact ownership | AI provider, realtime voice | Высокая. Минимум: scheduler service and durable job/run state; external model operations must not execute on capture/API event loop. |
| `VHC-01` | plate detector, ChannelWorker, identity persistence, plate batch/API, poller | vehicle crop and channel/identity ownership; pending/claim/read status state; retention and privacy policy | optional `plates` extra/model; OpenAI/local vision; `data.gov.il` registry | Высокая. Минимум: separate plate job record and provider adapter; validate external registry and jurisdiction before adoption. |
| `KNW-01` | knowledge tools, lexicon, attribute index, FTS, dossier, routes, visits | `ai_attributes` schema; identity/sighting/channel joins; index rebuild/versioning; evidence crop IDs | lexical vocabulary; optional vector index shared with ID-01 | Средне-высокая. Минимум: derived read model over agreed identity/attribute schema; index rebuild must be reproducible. |
| `MON-01` | independent watcher server/state/probes/door/actions/shares/tunnel/backup | main health and channels API contract; port ownership; process launch contract; state file permissions; separate service lifecycle | `cloudflared`, LaunchAgent, backup key/provider, notifications | Высокая. Минимум: separate least-privilege monitor process; public read-only surface must not share admin actions. |
| `DEM-01` | showcase routes/session/chat/vision, auth middleware, frontend page | visitor cookie distinct from operator session; bounded uploads; session-scoped artifact cleanup; route allowlist; SSE | external vision/chat provider; temporary tunnel URL patterns | Средне-высокая. Минимум: separate guest-session boundary and isolated storage/retention; no reuse of operator auth implicitly. |
| `SYS-01` | main lifespan/config/auth/limits/storage/db/models/janitor | schema and migrations; single connection/lock/WAL; media ownership; authorization and retention; settings precedence; startup/shutdown ordering | Firebase verification; Redis/Postgres extras; macOS permission code | Очень высокая. Минимум: target must choose database, migration strategy, identity model, auth and lifecycle before feature work. |

## Общие сервисы и скрытые зависимости

1. **Supervisor / process lifecycle:** один process owner создаёт source manager, identity service, workers и polling threads. Изменение этой границы затронет `CAP-01`, `CAP-02`, `ID-01`, `MEM-01`, `OPS-01`, `OPS-02`, `VHC-01` и event delivery.
2. **IdentityService / shared mutable state:** worker threads могут одновременно submit observations, но identity decisions serialized под `RLock`. Finalization может быть вызван sweeper, EOS или stop. Любой распределённый/async-порт требует однозначного владельца identity state и exactly-once/duplicate semantics.
3. **SQLite + media:** DB IDs, foreign keys, relative media paths, file writes/deletes, retention/caps, collages/clips/reports связаны. Перенос схемы без media migration/retention contract оставит dangling references.
4. **AI guard chain:** consent/privacy -> provider routing -> budget -> queue/concurrency -> typed schema -> persistence -> event. Разорвать gate chain нельзя; `dry_run` не является доказательством внешней интеграции.
5. **Queues and scheduling:** describe/plate/critical/narrative/mission work выполняются разными pollers/queues; у них собственные claims, retries, timeouts, in-flight state и cleanup. Эти детали нельзя свести к простому HTTP call.
6. **Threading and backpressure:** source capture не должен блокироваться на detection, network, AI или UI; per-camera workers, shared detect semaphore, bounded event queues и stale-frame dropping влияют на latency/resource use.
7. **Security scopes:** operator session/viewer role, station unlock, showcase cookie, watcher admin loopback, public token view, monitor key и AI image opt-in — отдельные границы. Один общий auth role не эквивалентен source policy.
8. **Hardware and platform:** built-in/external/Continuity Camera, TCC, AVFoundation, MPS/CoreML and model artifacts are macOS/Apple-Silicon specific. Browser capture и uploaded clips имеют другой lifecycle.
9. **External systems:** OpenAI Responses API, allowlisted local model, Firebase token verification, data.gov.il, Redis, Postgres и Cloudflare имеют независимые credentials/network/privacy requirements.

## Необходимые и необязательные зависимости

- Необходимые для исходных workflows: Python/backend runtime; HTTP/API contract; database и persistent media; source/worker lifecycle; identity and event state; соответствующие permission/auth checks.
- Необходимые только при выбранном сценарии: macOS AVFoundation/TCC для camera capture; OpenAI/local provider для live visual AI; browser/WebSocket publisher для screen/link; model weights для detector/ReID.
- Необязательные для базового single-node source: `distributed` Redis/Postgres; `refine` hero crop stack; `plates` optional detector package; Cloudflare tunnel; Firebase public hosting auth; realtime voice.
- Нельзя объявить optional саму privacy/budget gate, audit/role checks, DB/media retention или thread cleanup: они поддерживают безопасность/целостность нескольких функций.

## Рекомендуемый порядок зависимостей (кандидат)

1. Утвердить target purpose, stack, platform, data/auth and deployment constraints.
2. Зафиксировать shared contracts: settings/config, auth, schema/repository, media lifecycle, event envelope, error model, observability.
3. Согласовать capture target: macOS local, browser stream, uploaded video или иной источник. `CAP-01` не следует реализовывать без этого выбора.
4. Если target поддерживает local video: `CAP-02` и media lifecycle; затем `ID-01` и операторская curation.
5. Поверх согласованной схемы подключать `KNW-01`, затем `AI-01`–`AI-03`, `MEM-01`, `VHC-01`, `OPS-01`–`OPS-02` с отдельными privacy/budget gates.
6. `DEM-01` и `MON-01` — отдельные trust/process boundaries, подключать после auth/API stability.
7. `SYS-01` hardening, миграционные/recovery тесты и documented deployment gates завершают общий release gate, но не устраняют необходимость platform-specific проверки.

## Интеграционный минимум

До утверждения target архитектуры безопасная конкретная интеграция не определена. При подтверждении source-compatible modular backend кандидатом являются явные service/repository/provider interfaces и event contracts; это предложение не разрешает перенос и не является выбранной target-архитектурой.
