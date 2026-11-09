# Аудит проекта: локальная видеоаналитика безопасности

**Статус:** PHASE 0 завершена; PHASE 1 `GATE_B_PASS` для зафиксированного acceptance set. Официальный checkpoint, Core ML export/inference, corrected parity, offline sandbox, Swift regression и actual ANE activity trace подтверждены. Swift исходники и рабочие настройки не менялись.

## Вывод

Workspace содержит не один backend, а три самостоятельных клиента: нативный Swift, Kotlin/JVM и Python/aiohttp. Владелец подтвердил целевым клиентом Swift и уточнил, что MVP нельзя ограничивать одним worker. Kotlin и Python остаются отдельными клиентами, не целью этой интеграции.

Существующий путь Swift/Core ML — **YOLO26n object detection**, не Pose. `yolo26s-pose.pt` проверен по официальному digest и `task=pose`; два FP16 `.mlpackage` exports и отдельный FP32 diagnostic package созданы. После совпадающего static preprocessing (`rect=False`) parity прошёл зафиксированные Phase 1 tolerances на multi-person и blank frames. Safety engines, incident lifecycle и worker scheduler не реализованы; нагрузка 64 камер не проверялась.

**Рекомендация:** Phase 1 Gate B пройден для model artifact validation. Swift Pose runtime и Phase 2 не внедрялись; запуск integration остаётся отдельным следующим этапом с существующим RTSP pipeline и multi-worker design. Gate B не подтверждает CCTV safety quality или нагрузку на 64 камеры.

## Архитектура workspace

### Нативный Swift-клиент

- RTSP relay и credentials: `native/Sources/CameraWall/Go2RTC.swift`; адреса хранятся отдельно от пароля, пароль использует macOS Keychain.
- Декодирование: `native/Sources/CameraWall/CameraSession.swift` и `native/Sources/VideoBridge/VideoBridge.c`. Код требует VideoToolbox-декодер, начинает с ключевого кадра и возвращает `CVPixelBuffer`; RTSP использует TCP.
- Аналитика: `native/Sources/CameraWall/YOLO26Detector.swift`, `native/Sources/CameraCore/ObjectDetection.swift`, вызов и per-camera tracking в `native/Sources/CameraWall/WallModel.swift`. Модель и контракт — COCO object detection с NMS-free выходом `[1, N, 6]`; scheduler однопоточный, round-robin и ограниченный.
- История: `native/Sources/CameraCore/IdentityTracking.swift`; локальная история объектов и пользовательские cross-camera review-механизмы не являются межкамерной идентификацией по умолчанию.
- События: `native/Sources/CameraWall/ISAPIEventMonitor.swift` принимает read-only Hikvision metadata. `native/Sources/CameraCore/CriticalAlertClips.swift` хранит выборочные JPEG lookback-кадры, а не исходный видеоклип.
- Локальный VLM через MLX Swift и его конфигурация описаны в `native/README.md`. Это отдельная функция; она не превращает Pose detector в action classifier.

### Kotlin/JVM-клиент

- RTSP и отображение: `kotlin-client/src/main/kotlin/camerawall/VideoWall.kt`, `NativeVideo.kt`, `Go2Rtc.kt`; нативный мост — `kotlin-client/native/Bridge.mm`.
- В `Bridge.mm` GStreamer `rtspsrc` принимает H.264/H.265, `vtdec_hw` декодирует, очередь ограничена одним буфером с drop, `appsink` отдаёт NV12 в `CVPixelBuffer`, далее отображает `AVSampleBufferDisplayLayer`. Это наиболее близкая точка интеграции для анализа существующих decoded frames без второго RTSP connection.
- Камерные credentials используют Keychain. Настройки и layout локальные. Клиент независим от Swift, его README называет реализацию неполным миграционным срезом.
- В Kotlin-клиенте не обнаружены inference, Pose/tracking state, события безопасности, запись evidence, общий REST/WebSocket API или worker distribution.

### Python/aiohttp-прототип

- `multi_camera_vlm_server_yolo2.py` — отдельный server с `aiohttp`, OpenCV/FFmpeg RTSP capture, обычным Ultralytics YOLO object detection и VLM-клиентом с default endpoint `http://localhost:11434/v1`.
- `multi_camera_vlm_ui.html` и `BROWSER_CAMERA_SETUP.md` обслуживают browser-camera flows. В коде есть WebSocket для локальных браузерных кадров и pairing/TLS ограничения для LAN-доступа.
- Этот путь не является продолжением Kotlin/Swift RTSP pipeline. Перед повторным использованием нужно отдельно проверить хранение RTSP URLs, зависимости и lifecycle; он не выбран целевой архитектурой.

## Реализовано / отсутствует

| Область | Наблюдаемое состояние | Статус |
| --- | --- | --- |
| RTSP ingest и hardware decode | Swift: FFmpeg + VideoToolbox; Kotlin: GStreamer `vtdec_hw`; оба имеют reconnect. | IMPLEMENTED по исходникам; runtime в аудите не проверялся |
| YOLO26 inference | Swift использует YOLO26n object-detection Core ML; Python использует обычный YOLO detect. | IMPLEMENTED, но не требуемая Pose-модель |
| `yolo26s-pose.pt` | Официальный release asset, SHA-256 совпал с GitHub release metadata; task `pose`, `kpt_shape=[17,3]`. | PROVISIONED / PYTORCH SMOKE TESTED |
| `yolo26s-pose.mlpackage` | Официальный Ultralytics FP16 export; вход 640×640, выход `[1,300,57]`; Core ML/offline inference и matched-preprocessing parity прошли. | GATE_B_PASS для зафиксированного Phase 1 acceptance set |
| Pose keypoints | Нет в найденном detector output/data contract. | NOT IMPLEMENTED |
| Multi-object tracking | Swift имеет короткоживущий per-camera bbox-overlap track assignment; это не ByteTrack/BOT-SORT и не identity. | Частично IMPLEMENTED; не Pose track validation |
| Fall / fight / inactivity | Соответствующие safety engines и validated fight checkpoint не обнаружены. | NOT IMPLEMENTED |
| Events / evidence | Есть ISAPI event metadata и ограниченный JPEG lookback. Нет общего safety incident lifecycle и оригинальных 15s/30s video clips. | Частично IMPLEMENTED |
| API / integrations | Python server имеет HTTP/WebSocket; Kotlin — локальный go2rtc control API; Swift — внутренние/локальные функции. Общего версионированного incident API/outbox нет. | Частично IMPLEMENTED |
| 64 камеры / несколько workers | Есть краткие decoder concurrency smoke tests в Swift, но не sustained inference benchmark; Kotlin README явно не сертифицирует 60-stream нагрузку. | NOT VALIDATED |

## Аппаратная и инструментальная проверка

Снимок системы на 2026-11-08:

- MacBook Pro, Apple M5: 10 CPU cores (4 performance + 6 efficiency), 10-core GPU, 24 GB unified memory; Metal поддерживается.
- macOS 27.2; Xcode 27.2; `coremlcompiler` доступен.
- FFmpeg 9.0.2 доступен, сборка включает VideoToolbox; FFmpeg сообщает `videotoolbox` как hardware acceleration method.
- GStreamer 1.28.8 доступен; `vtdec_hw` plugin присутствует и описан как hardware-only.
- Системный Python 3.15.0; `.venv` Python 3.14.7, Ultralytics 8.4.182, PyTorch 2.14.1, torchvision 0.29.1. `coremltools` в `.venv` отсутствует. `native/requirements-seg-export.txt` закрепляет Ultralytics 8.4.112, то есть отличается от `.venv`.
- `.venv1/bin/python` сообщает отсутствие модуля `pip`; не исправлялось.
- Системные снимки во время Phase 0/1 менялись: `memory_pressure` показывал 60–78% system-wide free; swap показывал до ~15.6 GiB из 16 GiB занято. Причина не установлена; нужна контролируемая нагрузочная оценка.
- На томе workspace около 50 GiB свободно (95% занято). Размер требуемого официального checkpoint и будущего evidence retention не подтверждён.
- Core ML Instruments trace подтвердил model-labelled ANE inference activity; полный per-op CPU/GPU/ANE partition не измерен. `CPU_AND_NE` policy и compute plan сами по себе не доказывают placement, trace evidence сохранён отдельно.

## Модели и лицензии

- `native/.build/models/` содержит существующие YOLO26n/segmentation/ReID/Qwen artifacts и добавленный в Phase 1 `yolo26s-pose.pt` (24,151,790 bytes; SHA-256 `a083adb42303728ae14c4bd6bd56d80da46f82fb2564dbd6f31dcc92ea321646`). Подробности и результаты в `docs/ai-video/MODEL_VALIDATION.md`.
- `native/README.md` указывает происхождение YOLO26n из `ultralytics/yolo-ios-app` release v8.3.0 и описывает INT8 model artifact. Это не доказательство происхождения или checksum локального файла в текущем аудите.
- `native/Makefile` скачивает дополнительные официальные/указанные в проекте артефакты и создаёт exporter environment; соответствующие targets не запускались.
- README указывает Ultralytics AGPL-3.0 / Enterprise. Пользователь подтвердил завершение licensing review; decision record/deployment scope в workspace не приложены и независимо не проверялись. Официальные Core ML/Pose docs получены через raw GitHub; официальный exporter main endpoint вернул HTTP 403. Release digest и локальный exporter source проверены.

## Конфигурация, безопасность, тестирование

- Swift и Kotlin хранят camera credentials в Keychain; клиентские go2rtc API слушают loopback и используют auth. Kotlin README предупреждает, что локальный RTSP relay доступен другим локальным пользователям.
- Python server имеет LAN pairing/TLS flow для browser camera; default VLM endpoint локальный. Никакой внешний AI endpoint не проверялся и не включался в этом аудите.
- Общая SQLite event database, RBAC для инцидентов, durable outbox, security-center contract, audit trail просмотров evidence и 64-camera worker registry не обнаружены.
- Подтверждённое требование multi-worker меняет scope MVP, но текущий Swift клиент пока является локальным приложением: coordinator/control-plane protocol, worker registration/assignment, remote health и offline event spool в коде не обнаружены.
- Swift tests расположены в `native/Tests/`; Kotlin tests — в `kotlin-client/src/test/kotlin/`. Swift regression run прошёл: `CameraWallTests` 149 (2 skipped), `CameraCoreTests` 113, плюс 5 Swift Testing checks; failures 0. Этот запуск не проверяет физические камеры, Pose в production Swift path или multi-worker cluster. CI/CD workflows не обнаружены.
- Workspace root и `native/` не являются Git repositories. Git status, commit baseline и diff недоступны; неизвестно, какие файлы являются пользовательскими изменениями. Надёжный Git rollback сейчас не подтверждён.
- Корневые `DEPENDENCY_MAP.md`, `COMPATIBILITY_REPORT.md` и `SOURCE_FUNCTIONAL_INVENTORY.md` относятся к старому анализу `giraffai-main` / `Documents/compare`; их нельзя использовать как архитектурную документацию текущего CameraWall без обновления и подтверждения.

## Внешние источники и ограничения аудита

Core ML/Pose docs получены через raw GitHub; exporter main endpoint вернул HTTP 403, license page независимо не проверялась. Выполнены model provisioning, export, offline inference и parity checks. Swift test suite прошёл с 0 failures; физические камеры, cluster tests, evidence recording, production listener и deployment не запускались. Пользовательский Ultralytics settings side effect от первой проверки описан в `MODEL_VALIDATION.md`.
