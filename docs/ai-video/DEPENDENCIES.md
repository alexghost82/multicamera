# Зависимости и provisioning

**Статус:** Phase 0 inventory плюс результаты разрешённого Phase 1 provisioning. Новые пакеты установлены только в build-only venv под `native/.build/`.

## Наличие в workspace / системе

| Компонент | Найденная версия / факт | Использование и ограничения |
| --- | --- | --- |
| Swift/Xcode | Xcode 27.2; Swift tools 5.9; macOS target Swift package 27.0 | Нативный CameraWall и XCTest; существующие тестовые targets имеют side effects через Makefile |
| Core ML tools | `coremlcompiler` доступен; `coremltools 9.0` в build-only Pose venv | Pose `.mlpackage` экспортирован/загружен; rect=False matched-preprocessing parity прошёл Phase 1 criteria; Instruments подтвердил ANE activity |
| Python системный | 3.15.0 | Не использовать для глобальной установки |
| `.venv` | Python 3.14.7, Ultralytics 8.4.182, Torch 2.14.1, torchvision 0.29.1; `coremltools` отсутствует | Не совпадает с `native/requirements-seg-export.txt` по Ultralytics 8.4.112; pose/Core ML export compatibility неизвестна |
| `.venv1` | Python запускается, `pip` module отсутствует | Не исправлялось и не рассматривается как provisioning env |
| Pose exporter venvs | `pose-exporter` (Python 3.15) и `pose-exporter-py313` (Python 3.13): Ultralytics 8.4.112, Torch 2.15.0, torchvision 0.29.2, coremltools 9.0, NumPy 2.3.5; approved `pose-exporter-py313-torch27`: Torch 2.7.0, torchvision 0.22.0, остальное то же | Все build-only и `pip check` чистый; существующие `.venv`/seg-exporter не менялись. Corrected matched-preprocessing FP16 parity метрики совпали между Torch 2.15 и 2.7. |
| FFmpeg | 9.0.2, `--enable-videotoolbox`, `ffmpeg -hwaccels` сообщает VideoToolbox | Swift C bridge требует собранных FFmpeg libraries и не делает CPU fallback |
| GStreamer | 1.28.8; `vtdec_hw` обнаружен | Kotlin uses Homebrew runtime/plugin; не смешивать с официальным installer/runtime |
| go2rtc | 1.9.15 указан в Swift/Kotlin документации, локальные helper artifacts присутствуют | RTSP relay; не inference engine |
| Kotlin/JVM | Kotlin 2.1.20, Compose 1.8.2, Gradle 8.12.1, Corretto 21 указаны в manifest/Makefile | Native bridge требует Homebrew GStreamer/JNI/JAWT и доступ к аппаратным Apple frameworks |

## Локальные model artifacts

В `native/.build/models/` находятся исходный `yolo26s-pose.pt`, два FP16 exports (`yolo26s-pose.mlpackage`, `yolo26s-pose-torch27.mlpackage`) и диагностический FP32 export (`yolo26s-pose-fp32.mlpackage`). Checkpoint size/digest/task проверены; manifests с per-file SHA-256 находятся в `yolo26s-pose-export-manifest.json`. Все exports дают image input 640×640 и `var_1570` `[1,300,57]` float32. Подробный parity — `MODEL_VALIDATION.md`.

`native/Makefile` описывает загрузку YOLO26n Core ML из `ultralytics/yolo-ios-app` release v8.3.0, сегментационного checkpoint из `ultralytics/assets` v8.4.0 и go2rtc из официального upstream release. Это описание build flow, а не текущая проверка SHA-256 всех файлов.

## Нужное для будущей Pose-проверки

1. Approved compatibility environment Torch 2.7 / torchvision 0.22 создан и проверен; после унификации preprocessing corrected FP16 parity совпал с Torch 2.15. Не менять exporter dependencies дальше без отдельного согласования.
2. Сохранять `.pt` и `.mlpackage` раздельно; не заменять YOLO26n assets.
3. Для последующей robustness qualification расширить набор сценами/visibility/occlusion/night; Phase 1 Gate B использовал согласованные текущие пороги на bus/blank acceptance set.
4. Фактическая ANE activity подтверждена Core ML Instruments trace; полный per-op CPU/GPU/ANE partition остаётся для отдельной performance phase.

## Лицензия и размер загрузки

В `native/README.md` указаны AGPL-3.0 / Enterprise. Пользователь сообщил, что licensing review выполнен; сам вывод/решение и выбранная модель распространения в workspace не приложены. Completion review принимается как подтверждение пользователя, но не как самостоятельно проверенное legal approval. Лицензии action-classifier checkpoint и dataset оцениваются отдельно.

Размер Pose checkpoint подтверждён как 24,151,790 bytes; FP16 packages около 20 MB каждый, FP32 diagnostic около 40 MB. На системном томе около 50 GiB свободно; этого недостаточно, чтобы без отдельного storage budget объявлять 64-camera evidence retention достаточным.

## Offline/runtime boundary

После утверждённого provisioning inference должен работать из локальных artifacts. RTSP может обращаться только к разрешённой камере/локальной сети. VLM вне этой задачи не подключать к external AI API. До утверждения внешнего receiver не реализовывать внешнюю отправку safety events.
