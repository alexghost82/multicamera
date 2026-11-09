# Валидация YOLO26s Pose

**Итог:** `GATE_B_PASS` для checkpoint/export/runtime/parity набора, offline inference, actual ANE activity и non-regression. Parity прошёл ранее зафиксированные tolerances после исправления comparison setup: для static Core ML нужно принудительно использовать `rect=False` также у PyTorch. Swift runtime не менялся; Phase 2 не начинал.

## Checkpoint provenance

- Asset: `yolo26s-pose.pt`, официальный `ultralytics/assets` release `v8.4.0`.
- Официальный release metadata size: 24,151,790 bytes; локальный размер совпал.
- Официальный GitHub release API digest и локальный SHA-256 совпали: `a083adb42303728ae14c4bd6bd56d80da46f82fb2564dbd6f31dcc92ea321646`.
- Путь: `native/.build/models/yolo26s-pose.pt`; исходный checkpoint сохранён.
- Ultralytics загрузил checkpoint как `PoseModel`, `task=pose`, `kpt_shape=[17,3]`. Экспортёрский trace отобразил output shape `(1,300,57)`.

## PyTorch baseline

Локальный fixture: `native/.build/models/bus.jpg`. Это smoke test, не surveillance evaluation dataset.

| Окружение | Результат |
| --- | --- |
| Python 3.14.7 / Ultralytics 8.4.182 / Torch 2.14.1 / MPS | Один cold/first call: 6,324.52 ms. Последовательные runs: 1,219.25, 18.32, 16.85, 16.91, 16.58 ms; median 16.91 ms. Результат: 4 boxes, keypoints `(4,17,3)`, confidence finite. |
| Python 3.15.0 / Ultralytics 8.4.112 / Torch 2.15.0 / MPS | Первый prediction: 899.13 ms; 4 boxes, `(4,17,3)`. |
| Python 3.13.16 / Ultralytics 8.4.112 / Torch 2.7.0 / CPU | Runs: 86.45, 53.04, 52.36, 52.81, 53.67 ms; warm median 52.93 ms; max RSS 422,412,288 bytes. Результат: task pose, keypoints `(4,17,3)`. |

Эти timings включают отдельные cold/initialization effects и один fixture. Они не являются P95, sustained throughput, камера-to-event latency, model accuracy или доказательством ANE placement.

## Причина предыдущих export failures

Локальный `exporter.py` требует `coremltools>=9.0` и `numpy<=2.3.5`. Ultralytics auto-updated NumPy на диске, но продолжил текущий process с уже импортированной NumPy 2.5.4. После запуска нового process с NumPy 2.3.5 экспорт прошёл. Предыдущий traceback был `aten::Int` → Core ML Torch frontend `_cast` → `dtype(x.val)`, но причиной был устаревший импорт NumPy в том process, а не неподдерживаемая модельная операция.

Traceback первой неудачной попытки (Python 3.15 / exporter venv). Ниже все stack frames и terminal exception; Python 3.15 formatter сворачивал многострочные выражения в call sites, это отмечено как `...`:

```text
Traceback (most recent call last):
    File "<string>", line 1, in <module>
        from ultralytics import YOLO; model = YOLO("native/.build/models/yolo26s-pose.pt"); path = model.export(format="coreml", imgsz=640, half=True, nms=False, project="native/.build/models", name="yolo26s-pose-coreml", exist_ok=True); print("exported:", path)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/ultralytics/engine/model.py", line 769, in export
        return Exporter(overrides=args, _callbacks=self.callbacks)(model=self.model)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/ultralytics/engine/exporter.py", line 945, in __call__
        f = getattr(self, f"export_{fmt}")()
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/ultralytics/engine/exporter.py", line 484, in outer_func
        f = inner_func(*args, **kwargs)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/ultralytics/engine/exporter.py", line 1301, in export_coreml
        ct_model = torch2coreml(...)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/ultralytics/utils/export/coreml.py", line 224, in torch2coreml
        ct_model = ct.convert(ts, **convert_kwargs)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/_converters_entry.py", line 646, in convert
        mlmodel = mil_convert(...)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/converter.py", line 186, in mil_convert
        return _mil_convert(...)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/converter.py", line 218, in _mil_convert
        proto, mil_program = mil_convert_to_proto(...)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/converter.py", line 294, in mil_convert_to_proto
        prog = frontend_converter(model, **kwargs)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/converter.py", line 106, in __call__
        return load(*args, **kwargs)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/load.py", line 87, in load
        return _perform_torch_convert(converter, debug)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/load.py", line 150, in _perform_torch_convert
        prog = converter.convert()
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/converter.py", line 1392, in convert
        convert_nodes(self.context, self.graph, early_exit=not has_states)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/ops.py", line 118, in convert_nodes
        raise e
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/ops.py", line 113, in convert_nodes
        convert_single_node(context, node)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/ops.py", line 174, in convert_single_node
        add_op(context, node)
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/ops.py", line 3066, in _int
        _cast(context, node, int, "int32")
    File "/Users/alexandr.bogdanov/Documents/multicamera/native/.build/pose-exporter/lib/python3.15/site-packages/coremltools/converters/mil/frontend/torch/ops.py", line 3048, in _cast
        res = mb.const(val=dtype(x.val), name=node.name)
TypeError: only 0-dimensional arrays can be converted to Python scalars
```

Вторая неудачная попытка на Python 3.13 дошла до того же `aten::Int`/`_cast` terminal error. В обоих процессах Ultralytics напечатал `Restart runtime or rerun command for updates to take effect` после автообновления NumPy; успешный retry был запущен новым процессом.

## Core ML export

Точный контрольный вызов:

```python
model.export(format="coreml", imgsz=640, quantize=16, batch=1, dynamic=False, device="cpu")
```

`nms` не передавался. Вызов выполнен на Python 3.13.16 / Ultralytics 8.4.112 / Torch 2.15.0 / torchvision 0.29.2 / coremltools 9.0 / NumPy 2.3.5. Экспорт завершился за 3.4 s. Ultralytics вывел input `[1,3,640,640]`, output `[1,300,57]`; предупреждение `overflow encountered in cast` возникло в MIL optimizer, но последующий inference output был конечным.

После разрешения создано отдельное `native/.build/pose-exporter-py313-torch27` окружение с Python 3.13.16 / Ultralytics 8.4.112 / Torch 2.7.0 / torchvision 0.22.0 / coremltools 9.0 / NumPy 2.3.5; `pip check` прошёл. Из byte-identical checkpoint copy выполнен тот же официальный FP16 export в новый artifact `yolo26s-pose-torch27.mlpackage` за 10.6 s. Предыдущий `.mlpackage` не перезаписывался.

Для диагностики создан отдельный FP32 package `yolo26s-pose-fp32.mlpackage` через `quantize=32` (не target artifact и не production candidate). Export завершился за 3.6 s.

Сверка с официальными источниками:

- [CoreML integration](https://github.com/ultralytics/ultralytics/blob/main/docs/en/integrations/coreml.md): рекомендует 640×640 для Pose; перечисляет `quantize=16` как FP16, batch default 1, dynamic default false и NMS/raw output режимы. В первом контрольном экспорте NMS намеренно не задавался.
- [Pose task](https://github.com/ultralytics/ultralytics/blob/main/docs/en/tasks/pose.md): default pretrained pose models имеют 17 COCO keypoints; подтверждает output fields `result.keypoints.data` и shape `(N,K,2/3)`.
- Установленный официальный Ultralytics 8.4.112 `ultralytics/engine/exporter.py` проверен локально: export requires `coremltools>=9.0` и `numpy<=2.3.5`; CoreML `nms=True` ограничен detect models; device `None` resolves to CPU. Текущий main exporter raw endpoint вернул HTTP 403, поэтому его полный текст в этой проверке недоступен.
- Текущая official CoreML docs описывает `nms=None` как raw output, `nms=False` как NMS-free head; установленный 8.4.112 `default.yaml` имеет `nms=False`. В контрольном вызове аргумент `nms` не передавался ни явно, ни как override.

## Artifact, runtime и offline

- Artifact: `native/.build/models/yolo26s-pose.mlpackage`, около 20 MB. File-level SHA-256 manifest: `native/.build/models/yolo26s-pose-export-manifest.json`.
- Approved Torch 2.7 FP16 retry: `native/.build/models/yolo26s-pose-torch27.mlpackage`; отдельный FP32 diagnostic: `native/.build/models/yolo26s-pose-fp32.mlpackage`. Hashes обоих сохранены в recovery manifest.
- Core ML spec: input `image` fixed 640×640; output `var_1570`, shape `[1,300,57]`, float32.
- Direct `coremltools 9.0` / Core ML inference with `ComputeUnit.ALL`: 39.35 ms on one resized local frame; process max RSS 394,870,784 bytes.
- Ultralytics CoreML backend returned four people and `(4,17,3)` keypoints; blank frame returned zero detections. Its loaded `MLModel.compute_unit` was `CPU_AND_NE` (no fallback).
- Core ML compute plan: 1,245 ops; usage known for 322, with 303 preferred Neural Engine and 19 preferred CPU; 307 support CPU+ANE and 15 CPU only. This is a plan estimate, not actual per-op execution telemetry.
- Actual placement trace: `native/.build/yolo26s-pose-coreml-python.trace`, captured on target Python PID 92140 with `sandbox_init` denying network inbound/outbound/bind. Instruments `Core ML` template recorded 10 `AneInference Prediction` hardware intervals labeled `yolo26s-pose-torch27_main`; durations were 2.7389–2.8040 ms. This confirms actual ANE activity during model inference, but is not a full op-by-op CPU/GPU/ANE partition.
- Target artifact trace: `native/.build/yolo26s-pose-coreml-target.trace`; model-labelled `yolo26s-pose_main__Op1_AneInference Prediction` produced 10 actual ANE intervals, 2.7427–2.7690 ms, with network denied inside the traced Python PID.
- Offline sandbox (`deny network-inbound/outbound/bind`) ran Ultralytics/Core ML inference successfully: 4 detections, keypoints `(4,17,3)`.
- Five backend runs: 2,476.76 ms cold/first, then 11.99, 10.67, 10.12, 10.13 ms; warm median 10.4 ms; process peak RSS 464,945,152 bytes. Fixture-only smoke, not sustained throughput.
- Torch 2.7 FP16 backend, five runs: 2,562.12 ms cold/first, then 11.52, 9.62, 9.58, 9.99 ms; warm median 9.81 ms; process peak RSS 445,448,192 bytes; policy `CPU_AND_NE`. Fixture-only smoke, not sustained throughput.

## Preliminary parity run (invalid preprocessing match)

The first comparison used the same `imgsz=640`, `conf=0.25`, `iou=0.7`, and CPU setting, but omitted `rect`. Ultralytics PyTorch defaults to rectangular auto-letterboxing for `.pt`; the static Core ML backend disables it. The resulting input transforms differed. The following earlier IoU/error numbers are diagnostic only and were not used for Gate B.

| Metric | Multi-person | Blank |
| --- | --- | --- |
| Detection count | 4 / 4 | 0 / 0 |
| Matched bbox IoU | 0.98251, 0.97942, 0.96918, 0.74420 | N/A |
| IoU p50 / p95 | 0.97430 / 0.98204 | N/A |
| Bbox max-coordinate error p50 / p95 / max | 4.41 / 94.65 / 110.21 px | N/A |
| Detection-confidence delta p50 / p95 / max | 0.01983 / 0.23440 / 0.27134 | N/A |
| Keypoint Euclidean error p50 / p95 / max | 2.62 / 24.00 / 28.19 px | N/A |
| Keypoint-confidence delta p50 / p95 / max | 0.01623 / 0.19752 / 0.27249 | N/A |
| Keypoints with confidence ≤0 | 0 / 0 | 0 / 0 |
| Keypoints with confidence <0.25 | 21 / 19 | 0 / 0 |

CoreMLTools warned that Torch 2.15.0 was untested. This preliminary mismatch was caused by different letterbox preprocessing, not a valid FP16 parity comparison.

## Corrected acceptance parity

PyTorch `.pt` and the target `yolo26s-pose.mlpackage` used `imgsz=640`, `rect=False`, `conf=0.25`, `iou=0.7`, `device="cpu"`. The actual predictor preprocessing tensors were compared and were bitwise equal (`max_abs_delta=0.0`). Matching used class equality and greedy one-to-one bbox IoU.

| Metric | Multi-person `bus.jpg` | Blank 640×640 |
| --- | --- | --- |
| Detection count / matched | 4 / 4 | 0 / 0 |
| Matched bbox IoU | 0.99558, 0.99526, 0.99436, 0.98950 | N/A |
| Minimum bbox IoU | 0.98950 | N/A |
| Bbox max-coordinate error p50 / p95 / max | 0.65674 / 0.75182 / 0.75745 px | N/A |
| Detection-confidence delta p50 / p95 / max | 0.00063 / 0.01561 / 0.01820 | N/A |
| Keypoint Euclidean error p50 / p95 / max | 0.75557 / 1.96607 / 3.11854 px | N/A |
| Keypoint-confidence delta p50 / p95 / max | 0.00299 / 0.02940 / 0.04189 | N/A |
| Missing keypoints, confidence ≤0 | 0 / 0 | 0 / 0 |
| Non-finite outputs | 0 / 0 | 0 / 0 |

Torch 2.7.0 / torchvision 0.22.0 FP16 artifact produced the same parity metrics. These cases cover one multi-person frame and an empty frame, not general CCTV accuracy.

### Gate B tolerances

Использован набор tolerances, ранее зафиксированный до corrected parity run; пороги не менялись после получения результатов:

- exact detection count/class for empty-frame and labelled cases; exact missing-keypoint-state parity;
- matched bbox IoU ≥0.90 per person;
- detection-confidence absolute delta P95 ≤0.10;
- keypoint Euclidean error P95 ≤1% image diagonal (for 640×640, approximately 9 px);
- keypoint-confidence absolute delta P95 ≤0.10.

Все значения corrected parity проходят эти пороги. Отдельный FP32 diagnostic с `rect=False` также практически совпал с PyTorch (bbox IoU 1.0; max keypoint error <0.001 px), подтверждая, что предыдущий FP32 mismatch тоже был от preprocessing, не от precision.

## Не выполнено

- Full per-op CPU/GPU/ANE runtime partition and thermal/long-duration memory test.
- Held-out parity corpus и предварительно одобренные tolerances.
- Swift integration, RTSP, worker network, restart/offline startup после reboot.
- Licensing review пользователь сообщил как выполненный; документ/заключение не приложены, самостоятельно не проверялось.

## Non-regression

Запущено `CAMERAWALL_GO2RTC="$PWD/native/.build/tools/go2rtc" swift test --package-path native --disable-automatic-resolution`.

- `CameraWallTests`: 149 tests, 2 skipped, 0 failures.
- `CameraCoreTests`: 113 tests, 0 failures.
- Swift Testing suites: 5 tests, 0 failures.

Это подтверждает прохождение существующих локальных Swift tests на текущем workspace. Это не проверка физической камеры, Pose integration в Swift application или multi-worker cluster.

## Решение Gate B

`GATE_B_PASS` по указанному fixed parity set: официальный checkpoint, PyTorch baseline, официальный Core ML export, package load, Core ML inference, 17-keypoint output, identical preprocessing, parity thresholds, offline sandbox, hashes/versions, actual ANE activity trace и Swift regression tests — выполнены. Не переключать модель в приложение и не начинать Phase 2 без отдельного перехода к следующему gate; этот pass не подтверждает CCTV quality, производительность на камерах/64 workers, полное op-level CPU/GPU/ANE распределение или production readiness.
