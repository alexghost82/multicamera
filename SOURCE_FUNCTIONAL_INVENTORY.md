# Каталог функциональности source-проекта

## Область и ограничения

- `MODE`: `ANALYZE`.
- `SOURCE_PROJECT_PATH`: `/Users/alexandr.bogdanov/Documents/multicamera/giraffai-main`.
- `TARGET_PROJECT_PATH`: `/Users/alexandr.bogdanov/Documents/compare`.
- `OUTPUT_DIRECTORY`: `/Users/alexandr.bogdanov/Documents/compare`.
- `FEATURES_TO_MIGRATE`: не заданы. Ниже каталог возможностей для выбора, а не утверждённая область переноса.
- Source и target проверены как отдельные, не вложенные каталоги. Output совпадает с корнем пустого target; сюда разрешено записать только документы анализа.
- Статически изучены исходники, конфигурация, README и наличие тестов. Приложение, тесты, модели, камера, AI API, туннели и оборудование не запускались. Runtime-поведение и точность моделей не подтверждались.
- Сложность ниже описывает связанность функции в source. Совместимость с target пока `UNKNOWN`, поскольку его архитектура ещё не исследовалась.

## Статусы доказательств

- `CONFIRMED`: точка входа, реализация или конфигурация найдена при статическом чтении. Это подтверждает наличие реализации, не её успешную работу в runtime.
- `INFERRED`: вывод следует из соседних модулей/контрактов, но полная цепочка не проверялась.
- `UNKNOWN`: требуется отдельная проверка.
- `NOT IMPLEMENTED`: используется только при явном отсутствии/заглушке; в этом каталоге такой вывод не сделан без достаточного доказательства.

## Обзор проекта

- `CONFIRMED`: локальная macOS-система многоканального сбора изображений и учёта персон/транспорта. Backend: Python `>=3.12,<3.13`, FastAPI, SQLite/WAL, OpenCV, Ultralytics YOLO26-seg, PyTorch/MPS и ONNX Runtime. Frontend: React 18, TypeScript, Vite 5. Доказательства: `README.md`, `pyproject.toml`, `frontend/package.json`.
- `CONFIRMED`: поток: `SourceReader` на физический источник -> `ChannelWorker` на канал -> singleton `IdentityService` -> SQLite и media files -> FastAPI -> React. Live preview отделён от detect/identity. Доказательства: `backend/app/capture/source.py`, `backend/app/workers/channel_worker.py`, `backend/app/identity/service.py`, `backend/app/workers/supervisor.py`.
- `CONFIRMED`: API собирается в `backend/app/main.py`; React содержит Dashboard, Sources, Channels, Identities, Inspect, Chat, Settings и Showcase.
- `CONFIRMED`: отдельный `ghost_watcher` использует Python standard library, отдельные процессы/порты и собственное состояние; его README заявляет отсутствие доступа к `data/ghost.db`. Его сервер и probes находятся вне FastAPI процесса.
- `CONFIRMED`: Redis/Postgres, refine и plate detector package объявлены optional extras; базовая установка использует SQLite. `AI_MODE=dry_run` предусмотрен для AI путей.
- `CONFIRMED`: в `tests/` есть тестовые модули для API/auth, capture, identity, AI, ops, storage и watcher. Наличие подтверждено просмотром каталога; тесты не запускались.

## Каталог возможностей

### CAP-01 — Источники видео и lifecycle каналов

- **Описание:** регистрация macOS-камер, загрузка видео, создание link/screen push-источников, привязка к каналу, запуск/остановка и группировка камер.
- **SOURCE FILES / entry points:** `backend/app/api/devices.py`; `backend/app/api/sources.py` (`create_camera_source`, `upload_video`, `create_link_source`, `create_screen_source`, `screen_stream`); `backend/app/api/channels.py` (`create_channel`, `start_channel`, `stop_channel`); `backend/app/workers/supervisor.py` (`start_channel`, `_start_channel_locked`, `stop_channel`); `backend/app/capture/source.py` (`SourceReader`, `SourceManager`); `camera_source.py` (`CameraSource`), `file_source.py` (`FileSource`), `avf_source.py` (`AVFSource`), `link_hub.py`.
- **Зависимости и flow:** выбор устройства/файла или создание push source -> `/api/sources/*` сохраняет source (upload пишет файл и probe-ит видео) -> `/api/channels/{id}/start` -> Supervisor выбирает backend -> SourceManager создаёт/переиспользует один reader на physical source -> reader fan-out-ит кадры подписчикам.
- **Условия / фон:** явный API start; reader работает в daemon thread. Live sources используют freshest-frame/drop semantics; файл paced и сигнализирует EOS. Камера повторяет open с backoff, кроме отказа в разрешении.
- **Data / интеграции:** device unique ID, видео или JPEG push -> `Frame` с timestamp/index/resolution -> channel subscribers и опциональный shared-memory ring. Интеграции: macOS AVFoundation/TCC, OpenCV, browser screen publisher, phone/link ingest и optional tunnel.
- **Side effects / errors / cleanup:** SQLite source/channel; upload в `data/uploads`; некорректный файл удаляется при ошибке probe. Удаление source останавливает его каналы. Stop финализирует worker и освобождает source/ring, если он больше не используется. Camera permission/link не тестировались.
- **Статус:** `CONFIRMED` по API/source abstractions/Supervisor. Тесты существуют: `test_api.py`, `test_avf_lock.py`, `test_link_ingest.py`, `test_screen_source.py`, `test_camera_groups.py` (не запускались).
- **Migration complexity:** `HIGH` — аппаратный lifecycle, macOS permissions, streaming, source sharing, threads и cleanup.

### CAP-02 — Обнаружение, tracking, cutouts и live preview

- **Описание:** detection/tracking людей и транспорта, capture crop/cutout, embeddings/visual attributes и live preview с overlay.
- **SOURCE FILES / entry points:** `backend/app/workers/channel_worker.py` (`ChannelWorker._run`, `_handle_detections`); `backend/app/vision/detector.py` (`Detector.process`); `cropper.py` (`make_crop`); `embedder.py` (`Embedder`); `backend/app/workers/capture.py` (`CaptureScheduler`); `backend/app/api/stream.py`; `backend/app/storage/media.py`.
- **Зависимости и flow:** reader frames -> detect stride/semaphore -> YOLO26-seg + ByteTrack -> scheduler выбирает capture моменты -> cropper/mask/attributes/chroma -> ONNX ReID embedding -> `ObservationSink` -> identity service. Отдельный preview thread рисует overlays на свежих frames; API отдаёт MJPEG или WebSocket JPEG frames.
- **Условия / фон:** запускается вместе с каналом; отдельные worker threads; detect/embedding ограничены process-wide semaphore. `transport_mode=local` переносит detect в `VisionEngine`; default работает in-process.
- **Data / интеграции:** BGR frames -> detections, masks, crop metadata, vectors, color/chroma/plate cues -> `data/crops`, `data/frames`, `data/posters`; preview -> browser. Требуются model weights в `data/models`; конфигурация tracker может записываться per channel.
- **Side effects / errors / cleanup:** запись файлов/метаданных, загрузка моделей, генерация tracker YAML. Init error публикуется как `PHASE_ERROR`; detect errors попадают в telemetry, невалидные embeddings пропускаются. При завершении worker отписывает reader, финализирует identity state и отключает канал. README запрещает `--reload` из-за двойного открытия камеры.
- **Статус:** `CONFIRMED` по worker -> detector -> crop/embed -> sink и stream API. Тесты: `test_capture_cadence.py`, `test_display_track.py`, `test_tracker_config.py`, `test_stream_ws.py`, `test_preview_clock.py` (не запускались). Доступность весов и реальная скорость/точность `UNKNOWN`.
- **Migration complexity:** `VERY HIGH` — ML runtime, GPU/память, потоковая обработка, файловое хранилище и несколько transport modes.

### ID-01 — Cross-channel identity resolution и операторская курация

- **Описание:** tracklets/sightings/crops, automatic match/new/suggestion, поиск похожих, trajectory и ручное исправление назначений.
- **SOURCE FILES / entry points:** `backend/app/identity/service.py` (`IdentityService.observe`, `_finalize`, `finalize_channel`, merge/detach/purge); `resolver.py` (`resolve`); `scoring.py`, `gallery.py`, `vector_index.py`, `continuity.py`, `topology.py`; `backend/app/api/identities.py`; `frontend/src/pages/Identities.tsx`, `Inspect.tsx`.
- **Зависимости и flow:** `CropObservation` -> сериализованный `IdentityService.observe` -> tracklet/sighting -> media write вне identity lock -> crop metadata -> provisional match -> stale sweeper или channel stop вызывает `_finalize` -> resolver проверяет ReID, crop agreement, color, контекст, временное окно и cannot-link -> match/suggest/new -> gallery/DB и UI events. Ручные API действия идут через service либо прямые DB updates с audit.
- **Условия / фон:** каждое observation вызывает ingestion; singleton identity owner с `RLock`; sweeper работает в фоне. Supervisor запускает continuity/duplicate и impurity-split sweeps.
- **Data / интеграции:** vectors, color/chroma, timestamps, camera topology, co-visibility -> SQLite (`identities`, `sightings`, `crops`, links, audit) + in-memory gallery/index -> gallery/similar/trajectory/merge/detach/purge APIs.
- **Side effects / errors / recovery:** persistent crops, создание/слияние identities, learning camera edges, audit. Crop caps/janitor ограничивают хранение. Отсутствующий identity удаляется из gallery; слабый transient tracklet может быть отброшен. Purge удаляет crops/media без undo. Реальная идентификация не тестировалась.
- **Статус:** `CONFIRMED` по service/resolver/API/SQLite schema. Тесты: `test_identity_matching.py`, `test_identity_purity.py`, `test_identity_purge.py`, `test_track_stitch.py`, `test_continuity_sweep.py`, `test_identity_operator_queue.py` (не запускались). Качество на реальных данных `UNKNOWN`.
- **Migration complexity:** `VERY HIGH` — shared mutable state, сериализация решений, алгоритмические пороги, индекс, история и destructive curation.

### AI-01 — Vision descriptions и searchable attributes

- **Описание:** фоновое описание crop изображений структурированными карточками; поля доступны для поиска.
- **SOURCE FILES / entry points:** `backend/app/workers/supervisor.py` (`_gate_poll_loop`, `run_describe_batch_sync`); `backend/app/ai/describe.py` (`run_describe_batch`), `gate.py`, `privacy.py`, `budget.py`, `client.py` (`GhostAIClient`), `schemas.py`; `backend/app/api/ai_describe.py`, `backend/app/api/identities.py`.
- **Зависимости и flow:** crop pending -> 2s describe gate собирает best crop per identity и ждёт batch/window -> privacy/channel gates -> claims -> collage -> budget gate -> Responses API parse или dry-run -> `ai_analyses`/`ai_attributes`/description records -> status/event/UI.
- **Условия / фон:** автоматический poller, запускает batch только при активном gate и достаточном количестве или истёкшем окне; есть batch caps и stale-claim recovery.
- **Data / интеграции:** local crop -> collage -> OpenAI Responses API либо allowlisted local endpoint -> SQLite analysis, attributes, model/prompt/schema, usage/cost. Внешняя отправка зависит от privacy master switch, per-channel opt-in и бюджета; dry-run без сети.
- **Side effects / errors / recovery:** локальные analysis/run/usage записи и conditional image transfer. Ошибки отражаются в run/claim status; stale claims возвращаются в очередь. Live AI не проверялся.
- **Статус:** `CONFIRMED` по gate, batch, client и API. Тесты: `test_describe_gate.py`, `test_crop_describe.py`, `test_budget.py`, `test_privacy_cache.py` (не запускались). Качество модели `UNKNOWN`.
- **Migration complexity:** `HIGH` — provider/schema, privacy/consent, бюджет, очередь, изображения и retries.

### AI-02 — Read-only research agent с evidence citations

- **Описание:** вопросы к локальным сведениям о каналах/identity/sightings/crops; агент вызывает read-only tools, может получать crop images и возвращает SSE events.
- **SOURCE FILES / entry points:** `backend/app/api/ai_ask.py` (`POST /api/ai/ask`, thread/report routes); `backend/app/ai/research_agent.py` (`ask`, `_dry_run`); `backend/app/ai/tools/registry.py`, `db_tools.py`, `sql_tool.py`, `image_tool.py`; `backend/app/ai/prompts/`; `backend/app/storage/db.py`.
- **Зависимости и flow:** request -> thread/message persistence -> bounded Responses API tool loop -> local SQLite dispatch -> results/images -> следующий turn -> SSE answer/events/usage. Dry-run использует реальные локальные read tools без внешнего запроса.
- **Условия / фон:** request-driven async generator, ограничение числа turns. Threads имеют list/get/merge/link/pin/delete и HTML/PDF report routes.
- **Data / интеграции:** local DB/media -> OpenAI Responses API live mode; `run_sql_readonly` использует SQLite URI `mode=ro` и SELECT/WITH. Thread/message/tool-call/usage records локальны.
- **Side effects / errors / recovery:** создаются threads/messages/tool-call/usage; внешний запрос может содержать вопрос и выбранные crops. Есть budget check, stream error event и dry-run. Реальное citation quality не проверялось.
- **Статус:** `CONFIRMED` по route, agent и registry. Тесты: `test_ai_client_loop.py`, `test_sql_tool.py`, `test_chat_queries.py`, `test_chat_stream.py`, `test_chat_opsec.py` (не запускались).
- **Migration complexity:** `HIGH` — tool-call protocol, read-only SQL, streaming, thread persistence и AI provider.

### AI-03 — Intelligence chat, voice preparation и подтверждаемые действия

- **Описание:** streaming операторский чат; голосовая заметка преобразуется в текст; предложенное Ghost изменяющее действие выполняется только после отдельного подтверждения оператора.
- **SOURCE FILES / entry points:** `backend/app/api/ai_chat.py` (`/chat`, `/voice/prepare`, `/chat/actions/*/confirm`, `/reject`); `backend/app/ai/chat/`, `voice.py`, `opsec.py`; `backend/app/storage/db.py` (chat action/thread tables); `backend/app/identity/service.py`; `frontend/src/pages/Chat.tsx`, `frontend/src/hooks/useGhostChatSession.ts`, `useMicRecorder.ts`.
- **Зависимости и flow:** chat -> `ghost_chat.chat` -> SSE/thread/action proposal. Proposal сохраняется как proposed -> оператор вызывает confirm -> args validation -> существующий identity/watch/role handler -> audit. Voice upload проверяется по размеру, обрабатывается в memory и выдаёт SSE text; текст можно отправить отдельно.
- **Условия / фон:** user-triggered async HTTP/SSE; mutation только по confirm request.
- **Data / интеграции:** operator prompt/camera scope/identity context -> AI provider; proposals -> SQLite; voice bytes -> AI transcription pipeline. README/комментарий route указывает на удаление audio buffer после обработки.
- **Side effects / errors / recovery:** подтверждённое действие может merge/rename/watchlist/role и создаёт audit. Предложение без подтверждения не исполняется. Ошибки выдаются как SSE error. Реальная voice-интеграция не проверялась.
- **Статус:** `CONFIRMED` по route и confirm handler. Тесты: `test_chat_api.py`, `test_voice_prepare.py`, `test_chat_stream.py`, `test_chat_opsec.py` (не запускались).
- **Migration complexity:** `HIGH` — stateful AI interaction, authorization, confirmation, audit и audio limits.

### MEM-01 — Ghost Memory: хронологическая память канала

- **Описание:** выбор кадров с изменениями/новыми объектами, описание периода и сохранение главы памяти для камеры.
- **SOURCE FILES / entry points:** `backend/app/workers/narrative_sampler.py`; `channel_worker.py` (`_make_narrative`, `_narrative_idle`, `_flush_narrative`); `supervisor.py` (`NarrativeJobQueue`, `run_narrative_sync`); `backend/app/ai/narrative.py` (`run_narrative_batch`); `backend/app/knowledge/ghostmemory.py`; `backend/app/api/channels.py` story routes; `frontend/src/pages/Channels.tsx`.
- **Зависимости и flow:** worker sampler -> cadence/change sampler -> serialized queue -> collage + privacy/budget gates -> AI narrative либо local blocked summary -> chapter в `ghostmemory` -> event/UI. Есть ручной `story/now`; config управляет opt-in.
- **Условия / фон:** sampling в channel worker; batch выполняется daemon thread; при остановке/отключении narrative flush.
- **Data / интеграции:** sampled JPEGs и sighting/identity counts -> collage -> AI provider при разрешённой отправке -> segment/meta/collage path в SQLite/filesystem.
- **Side effects / errors / recovery:** главы, коллажи и AI usage; при privacy/budget block сохраняется local summary. Ошибки batch логируются; queue ограничена. Точность narrative не проверялась.
- **Статус:** `CONFIRMED` по sampler/worker/supervisor/narrative/API. Тесты: `test_narrative_memory.py`, `test_channel_story.py` (не запускались).
- **Migration complexity:** `HIGH` — live lifecycle sampling, queue serialization, privacy/budget, media/history.

### OPS-01 — Live critical alerts и crowd events

- **Описание:** анализ live frames на операторские critical rules, crowd watch, уведомления, история, ack и reports.
- **SOURCE FILES / entry points:** `backend/app/workers/supervisor.py` (`_critical_poll_loop`, `_crowd_poll_loop`, `CriticalJobQueue`); `backend/app/ops/critical.py` (`watch_supervisor`, `scan_frame`), `crowd.py`, `alert_queue.py`, `alert_log.py`, `alert_report.py`; `backend/app/api/ops.py`, `camera_groups.py`.
- **Зависимости и flow:** armed rule -> poller samples current preview into ring -> serialized vision job -> privacy/budget/dry-run gates -> verdict -> alert/clip/notice persistence -> event bus and briefing/UI. Crowd loop independently evaluates counts/caps. Persisted history permits UI catch-up after lost WebSocket event.
- **Условия / фон:** critical sampling nominally 0.2s; model calls run on separate queue. Per-camera busy state, bounded retries/heal; crowd polling every second.
- **Data / integrations:** live JPEG ring/collage + rule text -> AI provider -> alert log/SQLite, optional clip and HTML/PDF -> UI/SSE/briefing.
- **Side effects / errors / recovery:** gated AI calls, alert events, clips, reports and ack state. Queue retries are capped; rules include cooldown/severity. Provider/alert delivery не запускались.
- **Статус:** `CONFIRMED` по pollers/critical implementation/API. Тесты: `test_critical.py`, `test_crowd.py`, `test_alert_log.py`, `test_alert_urgency.py`, `test_alertkey_settings.py` (не запускались).
- **Migration complexity:** `VERY HIGH` — latency-sensitive polling, per-camera rings, queued model calls, durable events/media and recovery.

### OPS-02 — Scheduled missions, watch rules, consult и reports

- **Описание:** повторяющиеся осмотры камер по brief; текстовые watch rules; AI consult/briefing, история расследований и PDF/HTML reports; часть workflows поддерживает realtime voice.
- **SOURCE FILES / entry points:** `backend/app/api/ops.py`; `backend/app/ops/missions.py` (`due_missions`, `run_mission`); `watch.py`, `consult.py`, `briefing.py`, `report.py`, `realtime.py`; `backend/app/workers/supervisor.py` (`_mission_poll_loop`, `kick_mission`); `frontend/src/pages/Chat.tsx`, `Channels.tsx`.
- **Зависимости и flow:** mission scheduler checks due rows every 2s -> daemon task per camera -> samples changed frames -> collage/AI -> run/thread/report. Watch/consult start via API/chat and persist rule/thread. Reports render saved thread/event content.
- **Условия / фон:** interval или clock/timezone schedules; DB enable flag; one active mission per camera per supervisor. Watch/consult/realtime request-driven.
- **Data / integrations:** live preview + operator brief -> AI provider -> mission run/thread and HTML/PDF. Consult/voice may need external AI.
- **Side effects / errors / recovery:** schedules/runs/threads/reports and external calls. Per-camera busy set prevents overlap; exception logged and busy state cleared in `finally`. Полный recovery watch/consult не прослежен.
- **Статус:** `CONFIRMED` для API, scheduler и mission poller; `INFERRED` для полного report workflow, часть watch/consult internals не прослежена. Тесты: `test_missions.py`, `test_ops_watch.py`, `test_ops_consult.py`, `test_ops_report.py`, `test_ops_briefing.py` (не запускались).
- **Migration complexity:** `HIGH` — schedules/timezones, live sampling, AI, threads, report generation and concurrency.

### VHC-01 — Обнаружение и чтение номерных знаков

- **Описание:** локальное обнаружение plate region на vehicle crop и пакетное чтение с возможным registry enrichment.
- **SOURCE FILES / entry points:** `backend/app/workers/channel_worker.py` (`_detect_plate` call); `backend/app/vision/plate_detector.py`; `backend/app/identity/service.py` (`_persist_plate_row`); `backend/app/ai/plates.py` (`run_plate_batch`); `backend/app/api/ai_plates.py`; `backend/app/workers/supervisor.py` (`_plate_poll_loop`); optional `plates` extra в `pyproject.toml`.
- **Зависимости и flow:** vehicle crop -> optional detector сохраняет plate crop/pending row -> manual API или poller threshold -> privacy gate -> collage -> structured model read -> 7/8 digit validation/confidence -> DB update и optional `data.gov.il` enrichment -> event/UI.
- **Условия / фон:** local detect при `plate_detect_enabled`; auto-read требует `plate_auto_run`, non-dry vision и достаточное число pending crops.
- **Data / integrations:** local model -> plate crop/SQLite queue -> OpenAI/local vision -> SQLite reading; optional vehicle registry `data.gov.il`.
- **Side effects / errors / recovery:** plate media/queue/run/usage writes. Ошибка model call возвращает claims в pending; dry-run не осушает очередь. Наличие модели и registry access не проверялись.
- **Статус:** `CONFIRMED` по worker/batch/poller/API. Точное тестовое покрытие detector/reader отдельно не установлено; shared AI budget tests есть, тесты не запускались.
- **Migration complexity:** `HIGH` — optional package/model, чувствительные изображения, batch AI, jurisdiction-specific validation и внешний registry.

### KNW-01 — Поиск внешнего вида, dossier, маршрутов и визитов

- **Описание:** read-only tools для поиска по AI attributes/text index/visual similarity, маршрутам камер, визитам, dossiers и окнам присутствия.
- **SOURCE FILES / entry points:** `backend/app/ai/tools/knowledge_tools.py`, `registry.py`; `backend/app/knowledge/attribute_index.py`, `dossier.py`, `fts.py`, `lexicon.py`, `routes.py`, `visits.py`; `backend/app/api/ai_knowledge.py`; `backend/app/ai/tools/sql_tool.py`.
- **Зависимости и flow:** research/chat tool call -> registry -> Hebrew/English lexicon -> attribute/FTS/SQLite lookup -> ranked results and evidence crop IDs; movement/visits join sightings and learned camera edges. Coverage/rebuild API управляет индексом.
- **Условия / фон:** tools request-driven; knowledge index can be rebuilt explicitly. Таблицы разделяются с identity и description flows.
- **Data / integrations:** `ai_attributes`, identities/sightings/camera edges -> local facet/FTS results -> agent answer. Сам lookup локальный; генерация ответа — соседний внешний AI layer.
- **Side effects / errors / recovery:** lookup read-only, rebuild изменяет derived local index. Неопознанные атрибуты могут перейти к текстовому поиску. Качество поиска не benchmark-илось.
- **Статус:** `CONFIRMED` по implementations/registry/API. Тесты: `test_knowledge.py`, `test_chroma.py`, `test_chroma_gate.py`, `test_chat_queries.py` (не запускались).
- **Migration complexity:** `MEDIUM-HIGH` — требуется совместимая identity/attribute model, lexicon, FTS/index и evidence links.

### MON-01 — Независимый `ghost-watcher`: мониторинг, recovery и share surfaces

- **Описание:** отдельный macOS service с dashboard, periodic health probes, notices, recovery door, optional auto-start, tunnel/public token shares и backup Responses relay.
- **SOURCE FILES / entry points:** `ghost_watcher/README.md`; `server.py` (`monitor_loop`, HTTP handlers); `probes.py` (`run_all_probes`); `door.py` (`backend_up`, `request_restart`); `state.py`, `actions.py`, `notifier.py`, `shares.py`, `tunnel.py`, `backup.py`, `crops.py`, `ghost_watcher/ui/`.
- **Зависимости и flow:** monitor thread вызывает HTTP/process/disk/log probes -> state machine применяет debounce -> macOS notice и optional autoheal -> door `:8017` проксирует к backend или показывает recovery. Admin/public listeners loopback; tunnel — отдельный optional process.
- **Условия / фон:** запускается отдельными scripts; LaunchAgent установка опциональна. README указывает polling 5s. При анализе сервис не стартовал.
- **Data / integrations:** probes читают API/host process state; собственное JSON/log/share state, без доступа к main SQLite согласно README. Public share имеет read-only subset; optional `cloudflared` и backup OpenAI endpoint.
- **Side effects / errors / cleanup:** может перезапустить backend через configured launcher, управляет tunnel/shares. Admin действия отделены от public view. README называет LaunchAgent единственной операцией с записью вне project. Tunnel/service не запускались.
- **Статус:** `CONFIRMED` для monitor/probes/door по коду; share/tunnel/backup описаны README и имеют модули, но не прослежены полностью. Тесты: `test_watcher_backup.py`, `test_watcher_door.py`, `test_watcher_duplicates.py`, `test_watcher_restart_policy.py` (не запускались).
- **Migration complexity:** `HIGH` — отдельный процесс, macOS service management, port ownership/proxy, restart policy и публичные границы безопасности.

### DEM-01 — Showcase / public demo session

- **Описание:** ограниченная showcase surface с visitor session, demo camera/scan/ask/chat/invite flows и отдельным operator-only invite administration.
- **SOURCE FILES / entry points:** `backend/app/api/showcase.py`; `backend/app/showcase/session.py`, `chat.py`, `vision.py`; `backend/app/auth.py` (showcase allowlist); `frontend/src/pages/Showcase.tsx`, `Invite.tsx`.
- **Зависимости и flow:** status -> visitor session -> showcase cookie -> bounded JPEG uploads -> demo vision/chat SSE -> session artifacts. Admin invite routes требуют operator session.
- **Условия / фон:** visitor-triggered API; отдельная cookie boundary от operator account.
- **Data / integrations:** visitor frames/prompts -> demo session/AI -> session-scoped artifacts/responses; provider зависит от настроек/gates.
- **Side effects / errors / recovery:** session/upload storage; frame count/size caps; errors закрываются offline state без raw stack trace. Полный lifecycle cleanup не прослежен.
- **Статус:** `CONFIRMED` для routes/cookie split/upload bounds; cleanup details `INFERRED`. Тесты: `test_showcase.py`, `test_pilot_access.py` (не запускались).
- **Migration complexity:** `MEDIUM-HIGH` — guest/operator authorization split, ephemeral data, upload bounds, SSE и AI reuse.

### SYS-01 — Accounts, конфигурация, storage и retention

- **Описание:** operator/viewer login, station unlock, settings, auth/rate limits, SQLite schema, media storage и retention/data-saver controls — общая основа функций.
- **SOURCE FILES / entry points:** `backend/app/auth.py`, `auth_firebase.py`; `backend/app/api/auth.py`, `settings.py`, `system.py`; `backend/app/main.py` (middleware/lifespan), `config.py`; `backend/app/storage/db.py`, `models.py`, `media.py`, `janitor.py`; `limits.py`.
- **Зависимости и flow:** HTTP middleware выполняет rate limit/public/station/login/viewer checks -> handlers используют shared DB/media. Lifespan запрашивает camera permission, инициализирует SQLite/AI schema, применяет crop caps, создаёт Supervisor, запускает optional ingest/clip/Redis consumer; shutdown останавливает сервисы.
- **Условия / фон:** process startup создаёт global services; SQLite single connection с lock/WAL; env/`.env` плюс persisted settings; cleanup/retention работают через workers.
- **Data / integrations:** `data/ghost.db` и media subtrees; hashed auth sessions, PBKDF2 password hashes; optional Firebase token verification, Redis transport и Postgres extra.
- **Side effects / errors / recovery:** startup создаёт data directories (код в `config.py` делает это при import), schema и возможно keys; maintenance удаляет media. Поэтому source не импортировался и команды не запускались в ANALYZE.
- **Статус:** `CONFIRMED` по config/auth/main/DB/storage. Тесты: `test_auth.py`, `test_prod_hardening.py`, `test_storage_retention.py`, `test_ai_backup.py` (не запускались).
- **Migration complexity:** `VERY HIGH` как shared foundation — cross-cutting schema, authorization, privacy, lifecycle и storage.

## Общие сервисы и скрытые зависимости

- `Supervisor` владеет `SourceManager`, `IdentityService`, active workers, event subscribers и polling threads; runtime функций камер зависит от его lifecycle.
- `IdentityService`/gallery — единый mutable identity state; `RLock` сериализует решения каналов. Tracklet keys принадлежат worker-каналам; finalization — stale timeout или channel stop.
- SQLite — единая БД со связями source/channel/identity/sighting/crop/AI/ops. DB records и media paths являются общим контрактом; purge влияет на связанные представления/индексы.
- `GhostAIClient` — общий внешний/local transport с concurrency semaphores, retry/backoff/circuit breaker, dry-run, local host allowlist и fallback bridge. Privacy, budget и результат контролируют вышестоящие модули.
- Privacy master switch, per-channel upload opt-in, model routing и budget kill switch — общие preconditions для visual AI, narrative, plate reading и alerts.
- Supervisor event fan-out доставляет события в bounded queues; `/api/ws/events` передаёт события и telemetry frontend.
- Media directory общий для crops/frames/collages/clips/reports. Janitor/caps могут физически удалить файлы, используемые UI/AI.
- Один source может иметь нескольких channel subscribers; source закрывается только после остановки последнего. Redis transport требует storage, доступного центральному узлу (это условие описано в `workers/transport.py`).
- Browser contracts включают JSON HTTP, SSE, MJPEG, WebSocket и multipart uploads; session/role/CORS rules endpoint-specific.

## Ограничения и непроверенное

- Архитектура target не исследована; совместимость, reuse и требуемые адаптации не утверждаются.
- Функции не выбраны; этот каталог не предлагает переносить весь проект.
- Не запускались unit/integration/E2E тесты, backend/frontend build, камера, модели, AI provider, Firebase, Cloudflare, ingest, watcher или registry endpoints.
- Наличие теста подтверждает только наличие файла, не актуальность и не прохождение.
- Не прослежены все ancillary endpoints, миграции схемы, packaging и deployment; для выбранных функций это нужно сделать при следующем шаге.

## Следующий шаг

Выберите ID для последующего анализа, например `CAP-01`, `ID-01`, `AI-02`; можно выбрать несколько. После выбора будет исследован target и подготовлены dependency map, compatibility report, migration plan и checklist. До отдельной команды `IMPLEMENT` код не изменяется.
