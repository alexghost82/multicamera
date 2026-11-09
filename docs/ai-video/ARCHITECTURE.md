# Предлагаемая архитектура

**Статус:** Phase 2 реализована в существующем Swift-клиенте `native/`: embedded coordinator, headless workers, mTLS peer pins, static camera leases, heartbeat, local Pose runtime и per-user LaunchAgent. Отдельный backend не добавлен. Физические mTLS/multi-worker acceptance tests и cluster capacity остаются Gate C.

## Текущее состояние

```text
Swift UI
  -> Go2RTC -> FFmpeg/libavformat -> VideoToolbox
  -> CVPixelBuffer -> display
  -> separate YOLO26n detect scheduler -> COCO boxes -> local track history

Kotlin UI (Compose/Swing)
  -> CameraStore / Go2Rtc -> GStreamer -> vtdec_hw
  -> appsink -> CVPixelBuffer -> display (independent client)

Python aiohttp
  -> independent OpenCV/FFmpeg RTSP/browser inputs
  -> YOLO26n detection + optional local VLM
  -> aiohttp HTTP/WebSocket/UI contracts
```

Swift ingest/render path находится в `native/Sources/CameraWall/CameraSession.swift` и `native/Sources/VideoBridge/VideoBridge.c`; coordinator/worker boundary отсутствует. YOLO scheduling расположен в `native/Sources/CameraWall/WallModel.swift`, runtime — `YOLO26Detector.swift`, config — `native/Sources/CameraCore/Configuration.swift`.

## Рекомендуемое направление

Расширять существующий Swift client и использовать его camera sessions/VideoToolbox-decoded frames. Не открывать второй RTSP connection на analytics, не блокировать decode/display, не создавать отдельную копию модели на каждую камеру и не накапливать старые кадры.

```text
owned camera session / session generation
  -> existing FFmpeg/VideoToolbox decoder (no extra RTSP connection)
  -> bounded latest-frame handoff
  -> coordinator assigns camera to a registered worker
  -> shared per-worker Core ML Pose runtime
  -> per-camera ByteTrack-compatible tracker + 5s pose history
  -> pose quality/temporal features
  -> separate fall and inactivity FSMs
  -> worker-local bounded incident spool + auditable state transitions
  -> coordinator incident view/store + existing Swift operator surface
```

Multi-worker roles находятся внутри существующего Swift executable; второй backend не используется. Worker authenticates through a Keychain `SecIdentity`, trusted certificate chain and pinned leaf fingerprint; the coordinator maps the verified pin to worker UUID. Camera URLs and credentials remain provisioned on each worker. Coordinator assignments are explicit/static, capacity-bounded, generation-tagged leases; heartbeat sequence and session identity reject replay/stale state. The headless worker reuses the existing go2rtc/`CameraSession` pipeline and a shared per-worker Core ML Pose runtime. A bounded local event spool is durable and backpressures at capacity, but Phase 2 has no incident producer or remote event forwarding. `LocalShowcaseServer` remains loopback-only and is not reused as control plane. Physical TLS, restart and multi-worker behavior still require Gate C validation.

Fight remains independent: interaction candidate generation may be implemented as non-alarm telemetry, но пользовательскую тревогу нельзя выдавать до подключения и независимой проверки реального fight/non-fight classifier. При отсутствии подходящей лицензированной модели статус — `MODEL_NOT_VALIDATED`.

## Контракты и изоляция

- Идентификаторы должны включать `camera_id`, generation/`stream_session_id`, `frame_id`, capture/receive timestamp, model version и per-camera `track_id`. Track ID не является личностью и сбрасывается при новом RTSP session.
- Одна модель на worker обслуживает камеры через scheduler. На каждую камеру — собственные tracker state и temporal history. Результат устаревшей сессии игнорируется.
- Перенос inference из callback обязателен: `Bridge.mm` продолжает отображать кадр независимо от очереди аналитики. Очередь bounded, drop policy и latency измеряются отдельно.
- Наблюдения keypoints должны кодировать `observed`, `low_confidence`, `predicted`, `missing`; предсказанные точки не считаются измерением для тревоги.
- Fall и possible incapacitation — отдельные наблюдаемые safety состояния; неизвестная видимость возвращает `INSUFFICIENT_VISIBILITY`. Медицинский диагноз запрещён. Критические события требуют human verification.
- Сначала хранить incident metadata и ограниченный evidence только при реальном событии/разрешённом retention. Существующий Swift JPEG lookback не является требуемым 15s/30s video recorder и не переносится как будто он им является.
- External delivery, durable outbox, API contract, roles и event acknowledgements остаются выключенными до отдельного согласования receiver и threat model.

## Масштаб и потоки

Первый MVP остаётся multi-worker-capable, а не single-worker-only. Текущая доступная среда состоит из одного Mac; colocated coordinator+worker mTLS registration/heartbeat/lease round-trip уже проверен на loopback с временными in-memory identities. Production Keychain, LaunchAgent, RTSP recovery и acceptance на отдельных физических workers ещё не проверялись. Число камер на узел определяется измерениями, а не фиксируется как 16. На 24 GB unified memory уже наблюдался высокий swap; MLX VLM и Pose runtime нельзя считать безопасными для одновременного запуска до измерения.

На 64 камеры суммарный decoded input — 1600 source FPS; при 5/10/15 sampled FPS на камеру модель получает 320/640/960 inference FPS. Sampling не устраняет стоимость 25 FPS decode. Идея 4 workers × 16 cameras и capacity 115 FPS/worker остаётся гипотезой prompt: ни один узел/кластер этого не подтвердил. Multi-worker orchestration входит в MVP, но производственная ёмкость на 64 камеры, автоматический failover и резерв ресурсов требуют отдельного performance gate.

## Возможные интеграционные файлы (только после Gate A)

- Изучить/расширить: `native/Sources/CameraWall/CameraSession.swift`, `VideoBridge.c`, `Go2RTC.swift`, `YOLO26Detector.swift`, `WallModel.swift`, `native/Sources/CameraCore/Configuration.swift`, `native/Package.swift`.
- Новые Swift domain-модули-кандидаты: worker protocol/runtime, bounded frame scheduler, Pose result schema, camera-scoped tracker/history, pose analytics, fall/inactivity FSM, incident repository/outbox. Точный persistence/API и ownership выбрать до implementation.
- Тесты: `native/Tests/CameraCoreTests/`, `native/Tests/CameraWallTests/`; нужны отдельные multi-worker integration и реальный Core ML/native video validation. Нельзя считать unit tests proof для кластера.
- Не менять в рамках MVP: `kotlin-client/`, Python/HTML, пользовательские model artifacts, camera configuration semantics, текущий RTSP recovery, network settings и автозапуск без отдельного одобрения.

## Отвергнутые автоматические решения

- Не вводить Kubernetes, Redis, Kafka, PostgreSQL, новый backend или новый RTSP client автоматически.
- Не создавать второй параллельный backend: coordinator должен быть частью согласованной Swift architecture либо интеграция должна быть остановлена до отдельного approval.
- Не менять существующий RTSP ingest и не добавлять соединения к камерам ради Pose.
- Не принимать YOLO26 Pose как fight classifier.
- Не включать recording всех потоков: storage budget и необходимость не подтверждены.
- Не считать локальный M5 равным четырём worker-узлам и не включать автоматический failover без резерва.
