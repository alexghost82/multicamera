# Отчёт совместимости source / target

## Итог

**Результат: BLOCKED — target пуст, совместимость функций подтвердить нельзя.** Пользователь выбрал все 14 функциональных групп для анализа. В target `/Users/alexandr.bogdanov/Documents/compare` обнаружен только `SOURCE_FUNCTIONAL_INVENTORY.md`; source-анализ описан в этом документе и в `DEPENDENCY_MAP.md`. Нет кода, manifest, тестов, API, target data model, deployment config или видимого Git-каталога. Следовательно, нельзя выбрать безопасные integration points или назвать verified compatibility. Текущие рекомендации — варианты для решения, не утверждение миграционного дизайна.

## Факты о сравниваемых проектах

- **Source (`CONFIRMED`):** Python `>=3.12,<3.13`, FastAPI/Uvicorn, Pydantic 2, SQLite/WAL, OpenCV, Ultralytics YOLO26-seg, PyTorch `>=2.9,<2.14`, ONNX Runtime, NumPy; Apple Silicon/macOS — задокументированная и целевая среда. Frontend: React 18, React Router 6, TypeScript 5.6, Vite 5. Source включает отдельный `ghost_watcher` на Python standard library.
- **Target (`CONFIRMED`):** каталог пуст до генерации analysis reports; нет приложений/manifest/test/config файлов для сравнения. `TARGET_STACK = UNKNOWN`, platform/versions/DB/API/auth/state/deployment = `UNKNOWN`.
- **Runtime verification (`NOT PERFORMED`):** ни один код, тест, build, hardware, external integration или deployment не запускался. Нельзя считать target compatible только потому, что его files отсутствуют.

## Найденные конфликты / пробелы

### CMP-01 — Нет target architecture и integration boundaries

- **PROBLEM:** для всех 14 функций отсутствуют target entry points, module contracts, API и существующие механизмы reuse.
- **CAUSE:** target directory не содержит приложения или описания требований.
- **IMPACT:** файлы назначения, интерфейсы, module ownership, error handling и технологии нельзя выбрать на доказательной основе.
- **RISK:** `CRITICAL` — реализация сейчас фактически станет созданием нового продукта, а не миграцией в существующую архитектуру; легко ошибочно закрепить неподходящий stack.
- **RECOMMENDED SOLUTION:** до реализации утвердить target purpose, preferred stack/platform и architecture owner; затем оформить target design и пересмотреть функции/границы.
- **ALTERNATIVE SOLUTION:** явно преобразовать задачу в greenfield reimplementation всех 14 групп на source-compatible modular stack; отдельно утвердить это как новую архитектурную цель.
- **Evidence status:** source и пустота target `CONFIRMED`; target intended architecture `UNKNOWN`.

### CMP-02 — Платформа и аппаратный доступ

- **PROBLEM:** `CAP-01`/`CAP-02` используют macOS camera/TCC, AVFoundation, Apple Silicon MPS/CoreML; target OS/CPU/GPU/browser permissions неизвестны.
- **CAUSE:** source README фиксирует macOS Apple Silicon; target не описан.
- **IMPACT:** камера, model inference, performance, permissions, model export и realtime preview могут не работать или требовать иной capture/inference adapter.
- **RISK:** `HIGH` — core capture/detection может быть несовместим с target runtime.
- **RECOMMENDED SOLUTION:** решить intended deployment matrix. Либо ограничить target macOS/Apple Silicon, либо отдельно спроектировать capture provider и inference backend с реальными acceptance tests по каждой платформе.
- **ALTERNATIVE SOLUTION:** переносить только backend-independent identity/knowledge logic и отложить live capture/detection до наличия совместимого hardware interface.
- **Evidence status:** source platform `CONFIRMED`; target hardware/platform `UNKNOWN`; inference behavior not tested.

### CMP-03 — Data model, database и media ownership

- **PROBLEM:** source предполагает связную SQLite schema (source/channel/identity/sighting/crop/AI/ops), relative media paths, foreign keys, WAL/connection lock, retention/crop caps; target storage и текущие данные отсутствуют.
- **CAUSE:** target пуст; нет target schema, migration policy, media store или retention policy.
- **IMPACT:** identity, history, AI attributes, clips/reports и operator actions не могут быть перенесены изолированными endpoints; требуется согласовать schema/data migration или чистый запуск.
- **RISK:** `CRITICAL` при переносе исторических данных; `HIGH` даже для пустого старта из-за межтабличных/файловых связей и destructive purge.
- **RECOMMENDED SOLUTION:** решить fresh target vs existing data migration, DB type, schema versioning, backup/restore, media store, retention and deletion semantics; описать migration rehearsal.
- **ALTERNATIVE SOLUTION:** начать без исторических данных и временно сохранить source как отдельный read-only service; cross-system identity lookup не считать эквивалентом полноценной миграции.
- **Evidence status:** source schema/media contracts `CONFIRMED`; target data/storage `UNKNOWN`.

### CMP-04 — Lifecycle, concurrency, queues и scheduling

- **PROBLEM:** source использует process-wide Supervisor, threads, `RLock`, source fan-out, per-channel workers, bounded queues, stale claims, retries и pollers с разным cadence; target concurrency model неизвестна.
- **CAUSE:** нет target runtime/event-loop/worker model.
- **IMPACT:** наивный async/HTTP порт может блокировать capture/event loop, дублировать jobs, терять alerts/crops или оставить ресурсы открытыми.
- **RISK:** `HIGH` — потеря наблюдений, подвисшие workers и некорректная финализация identities.
- **RECOMMENDED SOLUTION:** утвердить ownership/lifecycle model для capture, identity decisions и scheduled jobs; определить backpressure, idempotency, cancellation и shutdown contracts до имплементации.
- **ALTERNATIVE SOLUTION:** оставить capture/identity как отдельный локальный service и интегрировать target через versioned API/event contract.
- **Evidence status:** source concurrency/lifecycle `CONFIRMED` по `SourceReader`, `Supervisor`, `ChannelWorker`, `IdentityService`; target model `UNKNOWN`.

### CMP-05 — Authorization, privacy, external AI и публичные поверхности

- **PROBLEM:** source разделяет operator/viewer/station/showcase sessions, public watcher token view, monitor key, per-channel upload consent, AI budget и read-only SQL; target security model отсутствует.
- **CAUSE:** пустой target не задаёт identity provider, trust boundary, secrets handling, privacy policy или public access requirement.
- **IMPACT:** `AI-01`–`AI-03`, `OPS-01`–`OPS-02`, `VHC-01`, `DEM-01`, `MON-01` затрагивают изображения/идентификационные данные, external AI и/или публичный доступ.
- **RISK:** `CRITICAL` — нежелательная передача изображений/данных, privilege escalation или случайная публикация admin actions.
- **RECOMMENDED SOLUTION:** утвердить data classification, consent, retention, auth/RBAC, secret source, provider allowlist, budget and external network policy; preserve separate guest/admin/public boundaries.
- **ALTERNATIVE SOLUTION:** начать с локальных, read-only функций (`KNW-01` over approved data) без image upload/public/tunnel features до privacy review.
- **Evidence status:** source gates/roles `CONFIRMED` статически; live policy effectiveness `NOT VERIFIED`; target policy `UNKNOWN`.

### CMP-06 — Dependencies, model artifacts, ports и packaging

- **PROBLEM:** source имеет тяжёлые native ML dependencies, large downloaded weights, optional extras, fixed local ports (8017/8027/8020/8021; watcher 8018/8019), separate Node build and platform markers; target package/deployment constraints неизвестны.
- **CAUSE:** target manifests/deploy config отсутствуют.
- **IMPACT:** dependency conflict, package size, unsupported wheels, port collisions, model provisioning and offline install strategy не определены.
- **RISK:** `HIGH` для полного переноса; `MEDIUM` для pure data/query modules.
- **RECOMMENDED SOLUTION:** подтвердить Python/Node versions, OS/arch, network/offline policy, ports, model distribution, optional dependencies and deployment owner; проверить license constraints (Ultralytics AGPL noted in source README).
- **ALTERNATIVE SOLUTION:** вынести ML/runtime в отдельный optional service и сначала мигрировать независимые API/domain contracts; license review всё равно необходим.
- **Evidence status:** source manifests/ports/dependency groups `CONFIRMED`; target capabilities and licensing policy `UNKNOWN`.

### CMP-07 — Observability, retention, recovery и acceptance verification

- **PROBLEM:** target не содержит tests/build/health/recovery criteria. Source behavior relies on persisted events, health endpoint, logging, janitor, watcher, queue recovery and optional restart door.
- **CAUSE:** нет target operational SLOs, backup/restore plan, alerting ownership or test environment.
- **IMPACT:** нельзя определить acceptance criteria for `MON-01`, alerts/missions, rollback, migration data integrity or readiness.
- **RISK:** `HIGH` — failed deployments or silent state/data loss may not be detected.
- **RECOMMENDED SOLUTION:** определить test tiers, service health/readiness, SLO/retention, backup restore test, incident owner and rollout/rollback gate before first implementation stage.
- **ALTERNATIVE SOLUTION:** staged private pilot with explicit non-production classification and manual recovery; this must be approved and is not equivalent to production readiness.
- **Evidence status:** source provides health/watch/retention modules `CONFIRMED`; target ops/test capability `UNKNOWN`.

## Кандидатная архитектура (не утверждена)

Если target предназначен для той же локальной macOS-станции, наименее рискованный baseline для обсуждения — modular monolith с versioned boundaries: capture adapters; vision pipeline; identity domain + repository; AI provider/gate layer; ops scheduler/alert services; FastAPI API; React UI; SQLite/media repository; отдельный least-privilege watcher process. Это лишь переносимые концепции source, не выбранные target технологии и не решение по коду.

Варианты для решения:

1. **Source-compatible reimplementation:** Python/FastAPI + React, SQLite, macOS Apple Silicon; минимизирует платформенные изменения, но всё равно требует новой реализации и новой миграционной архитектуры.
2. **Target-first adaptation:** пользователь задаёт stack/platform; каждый feature group получает adapter/service boundary. Capture/ML может остаться external/local service, если target не может владеть hardware.
3. **Split migration:** начать с выбранных backend-independent read/query функции, сохранить source application для capture/identity; это снижает начальный риск, но не доставляет все 14 функций в target.

Ни один вариант не утверждён. Переход к файловому плану implementation блокируется до выбора.

## Решения, необходимые для снятия блокировки

1. Каково назначение target `compare`: новый продукт, экспериментальный порт, либо конкретное приложение/репозиторий, ошибочно указанный пустым каталогом?
2. Какой stack и deployment target обязательны: macOS local/Apple Silicon, Windows/Linux, browser/cloud или несколько платформ?
3. Должны ли переноситься исторические SQLite/media data, или target начинает с пустой базы?
4. Разрешены ли внешние AI requests, Cloudflare/public links, Firebase, registry lookup и audio processing; какие privacy/retention rules обязательны?
5. Все 14 групп остаются выбранными после ознакомления с `VERY HIGH` оценкой и полной системной зависимостью, или разделить на этапы/MVP?

До ответа безопасная target adaptation не определена. `IMPLEMENT` не разрешён.
