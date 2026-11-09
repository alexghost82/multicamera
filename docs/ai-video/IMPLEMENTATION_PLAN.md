# План реализации

**Текущий статус:** Phase 1 `GATE_B_PASS` для зафиксированного acceptance set. Phase 2 worker/coordinator implementation добавлена в `native/`: mTLS, static leases, headless Pose workers, bounded local event spool и per-user LaunchAgent commands. Полный Swift suite и local Pose fixture tests проходят; Gate C multi-node/network acceptance, deployment и sustained capacity остаются открыты.

## Фаза 0 — аудит

- Выполнено статическое чтение Swift, Kotlin и Python частей workspace, manifests, документов и тестовых деревьев.
- Считаны аппаратные сведения, версии Xcode/Python/FFmpeg/GStreamer, текущие swap/disk snapshots.
- На PHASE 0 сборки и тесты не запускались. Позже в PHASE 1 Swift tests прошли (149 CameraWall, 113 CameraCore, 5 Swift Testing; 2 skipped, 0 failures); физические camera/worker-network tests и deployment не выполнялись. Выполнены локальные PyTorch/Core ML smoke и parity checks, включая offline sandbox inference.
- Результаты: этот каталог `docs/ai-video/`.
- Gate A одобрил Swift embedded coordinator и multi-worker scope. Phase 2 фиксирует mTLS peer pins, локальную camera authority и статические leases; конкретный worker inventory и двухузловая сеть проверяются в Gate C.

## Решения Gate A

Подтверждено владельцем: target — `native/` Swift client; первый MVP не ограничивать одним worker.

Gate A решения владельца:

- Swift `native/` — target; multi-worker — часть MVP; coordinator role предполагается внутри существующего Swift product, второй backend не добавлять.
- Выполнение Phase 1, официальный model provisioning и изолированные dependency environments разрешены.

Текущая доступная среда — один Mac (`en0`: `10.0.0.12`); других worker hosts и `worker.json` нет. Multi-worker остаётся продуктовым scope, но сейчас возможна только colocated single-host проверка; 64-camera capacity и source rollback не подтверждены.

## Фаза 1 — model provisioning (`GATE B PASS` для зафиксированного acceptance set)

- Только отдельное Python environment; версии фиксировать после подтверждения совместимости Python/Ultralytics/PyTorch/coremltools.
- Сверить официальный `yolo26s-pose.pt`, task, 17-point contract, release provenance, размер и лицензию. Никаких случайных зеркал.
- Зафиксировать checksum/manifest; сохранить `.pt`; создать отдельный Core ML artifact; не менять текущую YOLO26n модель.
- PyTorch baseline -> Core ML FP16 export -> локальное inference сравнение boxes/keypoints/confidences/latency/memory -> offline startup.
- Не использовать INT8/palettization без точностной оценки. Не утверждать ANE placement без измерения.
- Результаты и hashes сохранены в model manifest и `MODEL_VALIDATION.md`; Phase 1 Gate B пройден для зафиксированного acceptance set. В Phase 1 package остался отдельным artifact; Phase 2 worker загружает локальный `poseModelPath` и не меняет UI model bundle.
- Если позднее выяснится, что task, export parity или runtime evidence недействительны, приостановить integration и повторно пройти соответствующую acceptance проверку; production model не переключать.

### Результаты текущей попытки

- `yolo26s-pose.pt` получен из официального `ultralytics/assets v8.4.0`; size 24,151,790 bytes, SHA совпадает с release digest. `task=pose`, `kpt_shape=[17,3]`.
- Причина прежних export failures: Ultralytics auto-updated NumPy 2.3.5 в уже работающем process, но потребовал restart; процесс продолжил с импортированной NumPy 2.5.4. Новый process с `runtime_numpy=2.3.5` экспортировал модель.
- Вызов: `model.export(format="coreml", imgsz=640, quantize=16, batch=1, dynamic=False, device="cpu")`; `nms` не задавался. Экспорт завершился за 3.4 s, artifact `yolo26s-pose.mlpackage`.
- После разрешённого compatibility test создан отдельный Torch 2.7.0 / torchvision 0.22.0 venv. Тот же FP16 export создал `yolo26s-pose-torch27.mlpackage` за 10.6 s. FP32 diagnostic artifact `yolo26s-pose-fp32.mlpackage` создан отдельно за 3.6 s; он не target.
- Core ML direct inference: output `(1,300,57)` finite; Ultralytics backend: bus 4 persons × 17×3, blank 0 persons. Offline process sandbox inference прошёл. Backend policy `CPU_AND_NE`; compute plan предпочитает ANE для 303 операций и CPU для 19 из 322 операций с определённым usage, но это estimate, не actual runtime trace.
- Core ML Instruments trace на Python target, sandboxed без сети, зарегистрировал 10 `AneInference Prediction` intervals для модели; 2.7389–2.8040 ms каждый. Это actual ANE activity evidence, но не полный op-by-op device breakdown.
- Ранний parity run с auto-rect PyTorch против fixed-square Core ML был некорректен и не является acceptance evidence: он дал min bbox IoU 0.744 и p95 keypoint error 24.00 px. При `rect=False` в обоих путях preprocessing tensors bitwise-identical. Corrected FP16 parity: bus 4/4 совпали; bbox IoUs `[0.99558, 0.99526, 0.99436, 0.98950]`; bbox coordinate error p50/p95/max 0.65674/0.75182/0.75745 px; detection confidence delta p95 0.01561; keypoint error p50/p95/max 0.75557/1.96607/3.11854 px; keypoint confidence delta p95 0.02940. Missing keypoints 0/0, outputs finite; blank frame 0/0. Все заранее зафиксированные Phase 1 tolerances пройдены для этого acceptance set. Torch 2.7 FP16 дал те же метрики; corrected FP32 diagnostic практически совпал с PyTorch.
- Swift regression command `CAMERAWALL_GO2RTC="$PWD/native/.build/tools/go2rtc" swift test --package-path native --disable-automatic-resolution`: `CameraWallTests` 149 (2 skipped), `CameraCoreTests` 113, Swift Testing 5; zero failures. Это non-regression evidence для локальных tests, не hardware/cluster acceptance.

## Фаза 2 — Swift worker и multi-worker foundation (implementation landed; Gate C validation pending)

- Реализованы `WorkerControl` request/response envelopes, 64 KiB framed JSON codec, mTLS listener/client с chain validation и leaf SHA-256 pinning, transport identity→worker UUID mapping, explicit-IP bind, 32 connection cap и 10-second incomplete-request timeout.
- `WorkerCoordinator` обеспечивает authenticated registration, protocol/session/heartbeat sequence checks, capacity reports, atomic static camera batch assignment, expiring leases и generation increments. Dynamic failover не включён.
- Headless `--worker` mode в том же Swift executable использует существующие `Go2RTC`/`CameraSession`, локальные Keychain camera credentials и shared YOLO26s Pose runtime; pose inference остаётся вне VideoToolbox callback. Обычный UI path YOLO26n не менялся.
- Durable local event spool использует atomic JSON, mode `0600`, 10,000-record / 16 MiB bounds, 64 KiB payload cap и backpressure вместо eviction. Phase 2 пока не производит и не пересылает safety incidents.
- Per-user LaunchAgent plist install/bootstrap/bootout/uninstall commands реализованы; install и bootstrap разделены. Coordinator assignment config статичен и хранится локально, worker camera config/credentials не передаются по сети.
- Targeted tests: control/lease/wire, launchd plist, strict IP/pin config, event spool и Swift Pose decoder. Полный native Swift suite и local Pose `bus.jpg` inference прошли.
- Gate C остаётся pending: same-host loopback mTLS registration/heartbeat/static-lease round-trip прошёл на ephemeral in-memory identities. Production login-Keychain identity, RTSP camera reconnect/lease recovery и LaunchAgent после login/reboot ещё не проверялись. Дополнительных узлов в текущем окружении нет, поэтому physical multi-node handshake и cluster inference metrics недоступны; 64-camera capacity не подтверждена; Kotlin/Python clients не менялись.

## Фаза 3 — safety analytics (отдельный quality gate)

- Реализовать pose temporal analytics и `unknown`/visibility state; затем Fall FSM и Possible-Incapacitation FSM как наблюдаемые признаки, с hysteresis, cooldown, evidence features и human verification.
- Не блокировать предварительное fall событие порогом inactivity; occlusion/disappearance → `INSUFFICIENT_VISIBILITY`.
- Fight: Stage A interaction features могут создавать кандидаты, но не финальную fight alarm. Stage B подключать только при наличии проверенного dataset/checkpoint/license/runtime; иначе явно `MODEL_NOT_VALIDATED`.
- Датасет: независимые train/validation/test с разбиением по сцене/камере/субъектам, hard negatives и разрешёнными правами использования. Отдельно измерять false alarms per camera per day.
- Gate D: независимая оценка качества и согласование human-response workflow; без этого не production-ready.

## Фаза 4 — incidents, evidence, UI/API

- До UI выбрать локальную durable schema, retention/quota, roles и incident lifecycle. Текущий Swift-клиент не содержит общего safety DB/event API; не добавлять тяжёлую инфраструктуру заранее.
- Сначала локальное incident history/acknowledgement и camera overlay; external integration только после подписанного receiver contract, auth, idempotency, durable outbox и security review.
- Оригинальный evidence clip (15s pre / 30s post) требует отдельного recorder/ring buffer и source timestamps; JPEG lookback Swift не достаточен. Запись всех камер исключена из этого предложения.
- Gate E: security/privacy review, evidence-access audit, retention verification и совместимость интеграции.

## Фаза 5 — multi-camera/cluster scale

- Multi-worker registration/assignment входит в MVP; эта фаза проверяет масштаб нагрузки. Benchmark матрица 1/4/8/16/24/32 камер и затем кластер 64. На каждом размере измерить per-worker decode/inference FPS, assignment stability, drops, bounded queue delay, P95/P99 end-to-end, memory/swap, CPU/GPU/ANE placement, thermal/power, reconnect/restart и потерю coordinator/worker.
- 5/10/15 FPS — режимы для измерения, не обещание. 4×16 и 115 sustained FPS на worker проверяются, не предполагаются.
- Автоматический failover включать только после capacity model и подтверждённого резервного ресурса. Не вводить Kubernetes/Redis/Kafka автоматически.
- Gate F: sustained benchmark и recovery approval.

## Проверки и rollback

- Не запускать `make -C native test`, `make -C native stress`, `make -C kotlin-client test` без контроля side effects: targets способны скачивать модели/fixtures/tools. Swift XCTest выполнены прямым `swift test --disable-automatic-resolution` с уже существующим go2rtc helper.
- Unit: transforms/keypoint quality/tracking/session reset/FSM/timestamps/idempotency/retention. Native integration: реальный Core ML invocation, VideoToolbox/GStreamer path, bounded handoff, приём frames во время inference. Scenario: сидение, приседание, наклон, диван, подъём, упражнения, окклюзия, дальняя камера, ночь и безопасно постановочное падение.
- Regression: текущие Swift RTSP discovery, H.264/H.265 VideoToolbox, reconnect, UI/layout, Keychain config и native bridge tests; Kotlin/Python должны оставаться неизменными.
- Без Git baseline безопасный rollback источников не гарантирован. До фазы 2 требуется согласованный backup/version-control checkpoint; модельные artifacts должны быть отдельными и переключаться конфигурацией, без перезаписи текущих.
- Gate G: отдельное письменное production deployment approval; deployment не входит в этот план до этого решения.
