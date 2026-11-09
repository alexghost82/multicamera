# Реестр моделей

**Статус на 2026-11-08:** Phase 1 `GATE_B_PASS` для зафиксированного acceptance set. Это не подтверждает production readiness, detector quality, 64-camera capacity или независимо установленное право на распространение; licensing review пользователь сообщил как завершённый, но письменное решение здесь не приложено.

| Модель / artifact | Источник и идентификатор | Задача / контракт | Статус |
| --- | --- | --- | --- |
| `yolo26s-pose.pt` | Официальный `ultralytics/assets` GitHub release `v8.4.0`; 24,151,790 bytes; SHA-256 `a083adb42303728ae14c4bd6bd56d80da46f82fb2564dbd6f31dcc92ea321646` | Ultralytics сообщает `task=pose`; `kpt_shape=[17,3]`; traced output `(1,300,57)` | PROVISIONED; source digest matched; PYTORCH SMOKE TESTED |
| `yolo26s-pose.mlpackage` | Создан `native/.build/models/yolo26s-pose.mlpackage`; Swift worker загружает его через локальный `poseModelPath` | Core ML FP16 ML Program, image 640×640; output `var_1570` `[1,300,57]`; worker parser возвращает bbox и 17 keypoints | Phase 1 GATE_B_PASS; Swift Core ML bus fixture smoke вернул 4 людей; package не bundled в app |
| `yolo26s-pose-torch27.mlpackage` | Export из отдельной копии официального checkpoint с Torch 2.7.0 | Core ML FP16 ML Program, тот же I/O contract | EXPORTED; matched-preprocessing parity PASS |
| `yolo26s-pose-fp32.mlpackage` | Diagnostic-only export с `quantize=32` | Core ML FP32; не production target | EXPORTED; matched-preprocessing diagnostic parity aligned |
| `yolo26n.mlpackage` / `.mlmodelc` | Существующие локальные Swift artifacts; README указывает `ultralytics/yolo-ios-app` v8.3.0 | COCO object detection, не Pose | EXISTING; запрещено использовать вместо обязательной Pose-модели |
| Fight/action classifier | Не найден | Требуется проверенный fight/non-fight checkpoint и лицензированный dataset | NOT IMPLEMENTED / MODEL_NOT_VALIDATED |

## Provisioning record

- Источник модели: `https://github.com/ultralytics/assets/releases/tag/v8.4.0`; файл получен из официального release asset через TLS-проверяемый GitHub endpoint. Официальный release API публикует тот же SHA-256, что вычислен локально.
- Source artifact хранится в build-only каталоге `native/.build/models/yolo26s-pose.pt`; существующие YOLO26n assets не перезаписывались.
- File-level SHA-256 Core ML package сохранены в `native/.build/models/yolo26s-pose-export-manifest.json`.
- Ultralytics backend запросил `CPU_AND_NE`; Instruments trace подтвердил 10 model-labelled ANE prediction intervals. Полный per-op CPU/GPU/ANE partition не измерен.
- Проверка task выполнена в Ultralytics 8.4.182/Torch 2.14.1 и в exporter series 8.4.112/Torch 2.15.0. Metadata model class — `PoseModel`, `kpt_shape=[17,3]`.
- Ultralytics package metadata указывает AGPL-3.0; пользователь сообщил, что licensing review выполнен. Решение/область распространения в workspace не зафиксированы, поэтому этот реестр не делает самостоятельного вывода о legal approval.
