# Архитектура и технический справочник: Распознавание паттернов поведения человека в видеосистемах наблюдения (CCTV / RTSP)

## 1. Введение и системный контекст

Современные системы интеллектуального видеонаблюдения переходят от пассивной записи видеопотоков к проактивному анализу паттернов поведения человека в реальном времени. В условиях распределенных инфраструктур корпоративного и муниципального уровня типовой задачей становится одновременная обработка десятков потоков высокого разрешения (например, кластера из 64 камер формата Full HD 1080p при частоте 25 кадров в секунду, что формирует непрерывную нагрузку в 1600 кадров в секунду).

Ключевая сложность анализа видеоданных с камер наблюдения (CCTV) заключается в специфике ракурсов (высокое угловое или потолочное крепление), оптических искажениях, меняющихся условиях освещенности, частичных и взаимных окклюзиях людей объектами интерьера или городской среды. Для решения этих задач в исследовательском поле и индустриальной практике сформировались различные технологические подходы: от сквозных пространственно-временных нейросетей до каскадных систем на базе детекции скелетов и геометрических правил.

Данный документ представляет собой исчерпывающее техническое руководство, объединяющее систематизацию алгоритмов распознавания поведения, конфигурационные манифесты для высоконагруженных конвейеров и методику оптимизации вычислений на базе аппаратных платформ NVIDIA и Apple Silicon.

## 2. Полная техническая матрица паттернов поведения человека

В таблице ниже сведена информация по наблюдаемым паттернам поведения на основе валидированных репозиториев открытого исходного кода, научных публикаций и профильных бенчмарков. Все характеристики, не подтвержденные в исходных материалах прямыми замерами или явными указаниями спецификаций, строго маркированы как **NOT VERIFIED**.

| Паттерн / Класс поведения | Подтвержденные модели и алгоритмы | Репозитории GitHub | Научные публикации / Источники | Датасеты | Доступные веса | Требуемые входные данные | Поддержка потокового inference (RTSP / Live) | Ограничения | Лицензия | Уровень зрелости | Метрики точности (из источников) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Действия (Actions) — базовые и атомарные** | SlowFast, X3D, MViTv1/v2, VideoMAE (ViT-B/S/H), C3D, I3D, TSN, TSM | facebookresearch/SlowFast, MCG-NJU/VideoMAE, open-mmlab/mmaction2, PaddlePaddle/PaddleVideo | Feichtenhofer et al. (SlowFast); Tong et al. (VideoMAE); Carreira et al. (I3D); Wang et al. (TSN) | Kinetics-400/600/700, AVA 2.1/2.2, UCF101, HMDB51, SPHAR | Доступны в Model Zoo фреймворков (форматы PyTorch `.pth`, `.pdparams`) | Пакеты кадров RGB (клипы размерностью $T \times H \times W \times C$) | Поддерживается в онлайн-демо MMAction2 и SlowFast; для чистого RTSP требует скользящего буфера кадров | Высокая вычислительная сложность 3D-сверток и трансформеров; задержка накопления буфера $T$ кадров | Apache-2.0 (SlowFast, MMAction2, PaddleVideo); VideoMAE: исследовательская | Production-ready (в составе MMAction2 / PaddleVideo) | VideoMAE (ViT-B): Top-1 96.1% (UCF101), 73.3% (HMDB51) |
| **Позы (Poses / Keypoints)** | YOLO26-Pose, YOLOv8-pose, OpenPose (BODY-25), AlphaPose, HRNet, MediaPipe, DensePose | surajkrawat/fall-detection-yolo26-pose, ultralytics/ultralytics, open-mmlab/mmpose | Cao et al. (OpenPose); Sun et al. (HRNet); Ryspekov; Xiao et al. | COCO (17 ключевых точек), BODY-25 | Доступны (`yolo26s-pose.pt`, `yolov8n/s/x-pose.pt`, OpenPose models) | Одиночный кадр RGB ($1 \times H \times W \times 3$) | Поддерживается из коробки (покадровый потоковый инференс) | Деградация детекции при сильных взаимных перекрытиях и мелком масштабе людей в кадре | AGPL-3.0 (Ultralytics); OpenPose: non-commercial; MMPose: Apache-2.0 | Production-ready | Точность оценки поз: HRNet — 95.0%, OpenPose — 93.8%, MediaPipe — 88.8%, AlphaPose — 87.7% |
| **Скелетные действия (Skeleton Dynamics)** | ST-GCN, ST-GCN++, 2s-AGCN, MS-G3D, CTR-GCN, PoseC3D | kennymckormick/pyskl, yysijie/st-gcn, lshiwjx/2s-AGCN, open-mmlab/mmaction2 | Yan et al. (ST-GCN); Shi et al. (2s-AGCN); Liu et al. (MS-G3D); Chen et al. (CTR-GCN); Duan et al. (PoseC3D, PYSKL) | NTU RGB+D (60/120), Kinetics-Skeleton | Доступны в Model Zoo PYSKL, MMAction2, ST-GCN | Временные последовательности координат суставов $(C, T, V, M)$ либо 3D-стеки тепловых карт (PoseC3D) | Поддерживается в двухстадийных конвейерах при наличии потокового детектора поз | Накопление ошибки при шуме в координатах суставов от первичного детектора | Apache-2.0 (PYSKL, MMAction2); BSD-2-Clause (ST-GCN) | Production-ready | Точность NTU RGB+D (X-Sub / X-View): ST-GCN — 81.5% / 88.3%; 2s-AGCN — 88.5% / 95.1%; CTR-GCN — 92.4% / 96.8%; PoseC3D — 94.1% / 97.1% |
| **Траектории и трекинг (MOT / MTMCT)** | ByteTrack, BoT-SORT, StrongSORT, OccluBoost, SimpleIoUTracker, ResNet-50 PCB+rerank | FoundationVision/ByteTrack, mikel-brostrom/boxmot, open-mmlab/mmtracking, SurajDonthi/Multi-Camera-Person-Re-Identification | Zhang et al. (ByteTrack); Brostrom (BoxMOT); Ristani & Tomasi; SurajDonthi (ST-ReID) | MOT17, MOT20, CrowdHuman, Market-1501, DukeMTMTC-reID | Доступны веса YOLOX/ByteTrack, ReID-моделей (`lmbn_n_duke`) | Координаты bounding box от детектора + сырой кадр (для ReID) | Поддерживается полностью в реальном времени (онлайн-ассоциация) | Пересечения траекторий, потеря ID при длительном полном перекрытии объектов | MIT (ByteTrack, ST-ReID); AGPL-3.0 (BoxMOT); Apache-2.0 (MMTracking) | Production-ready | MOT17: ByteTrack — MOTA 80.3, IDF1 77.3, HOTA 63.1 (30 FPS на V100); Market-1501: ResNet50-PCB — mAP 95.5%, Top-1 98.0% |
| **Взаимодействия людей (Interactions / Fights)** | Двухпоточные и графовые модели, 3D Skeleton Point Clouds, YOLOv8-violence | Musawer1214/Fight-Violence-detection-yolov8, niyazed/violence-detection-fbf, idejie/Awesome-Violence-Detection | Aktı et al.; Sultani et al.; Wu et al. (XD-Violence); Melde (SPHAR) | AVA 2.2, NTU RGB+D (класс Mutual Actions), SPHAR, RWF-2000, CCTV-Fights | `Yolo_nano_weights.pt`, `yolo_small_weights.pt` | Кадры RGB, скелетные графы пар людей, опционально аудиодорожка | Поддерживается покадрово для YOLOv8; через скользящее окно для двухпоточных сетей | Ложные срабатывания на объятия и активные спортивные движения; взаимное перекрытие тел | MIT (YOLOv8-Fight); остальные — NOT VERIFIED | Working Prototype / Experimental | YOLOv8-violence: точность на CCTV NOT VERIFIED; RWF-2000 / XD-Violence бейзлайны: AP 78.64% (I3D+Audio) |
| **Падения (Fall Detection)** | YOLO26-Pose + геометрические правила инвариантности, C3D + SVM, Dynamical Haar + SVM | surajkrawat/fall-detection-yolo26-pose, amrn9674/Fall-Detection_Dynamical_haar_Cascade | Khalili, Mohammadzade, Ahmadi; Kwolek & Kepski; Tran et al. (C3D) | UR Fall Detection, FDD, специализированные CCTV-выборки | `yolo26s-pose.pt`; C3D/Haar веса — NOT VERIFIED | Потоковые кадры RGB или координаты суставов поз | Поддерживается в реальном времени (вычисление геометрических инвариантов на кадр) | Сложность детекции при частичной окклюзии мебелью; сходство падения с посадкой на пол | Лицензия репозитория YOLO26-Pose явно NOT VERIFIED | Working Prototype / Pilot | C3D+SVM при окклюзии: Accuracy 99%, Recall 96%, Precision 99%; Haar+SVM: 30 FPS, Accuracy 95%; YOLO26-Pose: 5 дискретных состояний |
| **Длительная неподвижность / Пребывание в зоне (Loitering & Zone Dwell)** | YOLOv8/YOLO11 + ByteTrack + полигональные зоны и таймеры треков | HardikVasava/loitering-detection-cv, saadkhan2003/CCTV_Video_Anomaly_Detection, roboflow/supervision | Vasava; Khan; Roboflow Dwell Time Analysis | Тестовые CCTV-видеозаписи, симуляции RTSP | `yolov8s.pt`, `yolo11s.pt` (стандартные веса COCO) | Поток RGB, координаты полигонов зон $(x_1, y_1, \dots, x_n, y_n)$ | Поддерживается из коробки (RTSP / WebCam / видеофайлы) | Разрыв трека при длительном перекрытии приводит к сбросу таймера без сквозного ReID | Apache-2.0 (CCTV Anomaly Detection); MIT (supervision); loitering-detection-cv — NOT VERIFIED | Production-ready | Скорость детекции: YOLOv8s на RTX 3060 ~60 FPS, на RTX 4090 ~120 FPS; YOLO11 OpenVINO: 15–30 FPS на Intel i5, точность 85–95% |
| **Видеоаномалии (Video Anomaly Detection — VAD)** | DeepMIL (C3D / I3D), RTFM, MSL, CLAWS, Sultani et al. MIL Ranking | Roc-Ng/DeepMIL, seominseok0429/Real-world-Anomaly-Detection-in-Surveillance-Videos-pytorch, fjchange/awesome-video-anomaly-detection, Junxi-Chen/Awesome-Video-Anomaly-Detection | Sultani, Chen, Shah (CVPR 2018); Tian et al. (RTFM, ICCV 2021); Wu et al. (ECCV 2020) | UCF-Crime (13 классов аномалий), ShanghaiTech, CUHK Avenue, XD-Violence | Доступны чекпоинты и предварительно извлеченные фичи I3D/C3D (10-crop `.npy`) | Извлеченные векторы пространственно-временных признаков по сегментам видео | Ограничена: классические MIL-модели требуют 32 сегмента; в онлайне нужен буферизированный экстрактор | Высокая частота ложных тревог при изменении фона; слабая пространственная локализация | Awesome-VAD: AGPL-3.0; DeepMIL: NOT VERIFIED | Research-grade / Benchmark | UCF-Crime (AUC): Sultani et al. — 75.41%; RTFM — 84.03%; Re-implementation I3D — 84.45%; MSL — 85.62%; FAR@0.5 до 0.05%–0.13% |
| **Мультимодальные / Языковые аномалии (VLM-VAD)** | VadCLIP, VERA, LAVAD, AnyAnomaly, SurveillanceVQA-589K | vera-framework/VERA, lucazanella/lavad, vt-le/Video-Anomaly-Detection | Wu et al. (CVPR 2024); Zanella et al. (LAVAD, CVPR 2024); Ye et al. (VERA, CVPR 2025) | VANE-Bench, SurveillanceVQA-589K, CUVA, UCF-Crime | Чекпоинты VERA / VadCLIP выложены в репозиториях авторов | Кадры RGB + текстовые описания аномалий / промпты | Не поддерживается в многопоточном онлайне (NOT VERIFIED для потокового инференса 25 к/с) | Огромное потребление видеопамяти; задержки авторегрессионной генерации текста | Зависит от базовой VLM (NOT VERIFIED для продакшн-лицензий) | Early Research / Prototype (2024–2025) | Способность к Zero-Shot детекции аномалий; точные значения AP/AUC в потоковом CCTV режиме NOT VERIFIED |

## 3. Сравнительный анализ технологических парадигм

Выбор базовой технологии для системы видеонаблюдения определяет требования к вычислительным ресурсам, надежность детекции и устойчивость к внешним помехам. Ниже приведен детальный сравнительный анализ четырех доминирующих подходов.

### 3.1. RGB Video Models (3D-CNN и Spatio-Temporal Transformers)
Модели семейств SlowFast, VideoMAE, C3D и I3D оперируют непосредственно тензорами видеоклипов. Их фундаментальное преимущество — способность извлекать богатый контекст окружения, текстуры и мелкие детали взаимодействия людей с неодушевленными предметами. Однако их применение в многокамерных системах реального времени крайне затруднено:
* Вычислительная сложность растет пропорционально объему $T \times H \times W$, требуя мощных ускорителей даже для единичного потока.
* Необходимость накопления скользящего окна кадров (от 16 до 64 кадров) вносит аппаратную задержку в выдачу тревог (latency от 0.6 до 2.5 секунд).
* Высокая чувствительность к изменению освещенности, теням, бликам и движению листвы или транспорта на заднем плане.

### 3.2. Pose / Skeleton Models (Графовые сверточные сети и скелетные энкодеры)
Подход, представленный моделями ST-GCN, CTR-GCN и PoseC3D, разделяет задачу на два этапа: извлечение координат ключевых точек тела (pose estimation) и классификация динамики графа скелета во времени. 
* Компактность представления данных: скелет описывается небольшим набором координат суставов, что делает инференс пространственно-временных графов чрезвычайно быстрым.
* Полная инвариантность к цвету одежды, текстуре кожи и изменениям освещенности сцены.
* Главное ограничение: критическая зависимость от точности работы детектора поз первой ступени. В условиях сильной скученности людей или перекрытия нижней половины тела мебелью/препятствиями координаты искажаются, что приводит к сбоям в работе графовых сетей.

### 3.3. Tracking + Rules (Детекция, трекинг и геометрическая логика)
Практический стандарт промышленной охранной видеоаналитики (YOLOv8/v11/26 + ByteTrack + Supervision). Основан на непрерывном сопровождении ограничивающих рамок (bounding boxes) и применении детерминированных математических и геометрических правил.
* Высокая масштабируемость: позволяет обрабатывать десятки потоков на одном графическом ускорителе благодаря легковесности алгоритмов ассоциации.
* Полная прозрачность и интерпретируемость: правила нахождения в зоне (dwell time) и пересечения виртуальных линий (tripwire) не подвержены нейросетевым галлюцинациям.
* Ограничение: невозможность распознавания сложных семантических действий (например, незаметное извлечение предмета из кармана или скрытые манипуляции руками).

### 3.4. Video-Language Models (VLM / MLLM)
Новейшая парадигма (VERA, VadCLIP, LAVAD), объединяющая визуальные энкодеры с большими языковыми моделями для детекции аномалий в парадигме открытого словаря (Open-Vocabulary Anomaly Detection).
* Способность обнаруживать нестандартные ситуации, которые не были размечены в обучающей выборке, опираясь на текстовое описание оператора.
* Возможность генерации текстовых объяснений инцидента для оператора ситуационного центра.
* Ограничение: категорическая неприменимость для высокочастотного покадрового анализа десятков RTSP-потоков на современном этапе из-за колоссальных задержек и требований к памяти.

## 4. Модульная архитектура локального конвейера на 64 камеры

Для обеспечения непрерывной обработки 64 потоков 1080p25 без передачи данных во внешние облачные сервисы конвейер строится по 8-уровневой архитектуре, валидированной в спецификациях Scanalitix и фреймворке NVIDIA DeepStream.

### 4.1. Многоуровневая структура конвейера
1. **Camera Ingest Layer**: Прием 64 RTSP/H.264/H.265 потоков, контроль сетевых буферов и сглаживание джиттера.
2. **Hardware Decode & Scaling Layer**: Аппаратная декомпрессия с помощью специализированных блоков GPU/SoC и приведение кадра к аналитическому разрешению.
3. **Batching & Stream Muxing Layer**: Объединение поверхностей кадров от 64 источников в единый составной тензор (батч) для максимальной утилизации вычислительных ядер.
4. **Primary Inference (Primary GIE)**: Запуск легковесного нейросетевого детектора или модели поз на объединенном батче.
5. **Multi-Object Tracking (MOT)**: Ассоциация объектов во времени, ведение уникальных идентификаторов треков и фильтрация траекторий.
6. **Analytics & Rule Engine**: Расчет времени пребывания в полигонах (Loitering), пересечений линий и оценка геометрии поз (падения).
7. **Secondary Triggered Inference**: Вызов тяжелых классификаторов (распознавание драк, вторичная валидация) строго по событию от движка правил.
8. **Event Dispatching & Storage**: Формирование метаданных инцидентов в формате JSON и отправка во внутреннюю шину сообщений (Kafka/RabbitMQ) с локальной записью клипов тревог.

### 4.2. Спецификация аппаратных платформ: NVIDIA против Apple Silicon

Оценка аппаратных платформ для масштабирования на 64 камеры опирается на подтвержденные бенчмарки и технические свойства:

* **NVIDIA Edge / Enterprise Server**:
  * Поддерживаемый стек: DeepStream SDK, CUDA, TensorRT (INT8/FP16), аппаратные декодеры NVDEC.
  * Механизм памяти: Прямая передача декодированных поверхностей через аппаратную память NVMM (`nvbuf-memory-type=0`) исключает накладные расходы на копирование данных между Host и Device.
  * Статус масштабирования: Для 1600 FPS детекции и трекинга требуется серверный ускоритель (или связка карт) уровня RTX 4090 / L40 / A100. Точное количество карт под 64 канала Full HD в источниках **NOT VERIFIED** (в подтвержденных тестах одиночная RTX 4090 выдает около 120 FPS для YOLOv8s, а карта V100 — 30 FPS для полного цикла ByteTrack).
* **Apple Silicon (M-серия)**:
  * Поддерживаемый стек: PyTorch MPS (Metal Performance Shaders), AMX (Apple Matrix Coprocessor).
  * Механизм памяти: Архитектура объединенной памяти (Unified Memory Architecture), устраняющая физическое копирование между CPU и GPU.
  * Статус масштабирования: Непрерывный анализ 64 потоков 1080p25 на одиночном процессоре M-серии **НЕВОЗМОЖЕН**. В исследованиях Ryspekov зафиксировано, что базовые модели на чипе M2 демонстрируют производительность всего 2–3 FPS из-за троттлинга, а легковесная YOLOv8-Nano требует 210 мс на кадр (~4.7 FPS). Кроме того, модели с операцией NMS вызывают тяжелые задержки ($\sigma > 2000$ мс) из-за сброса вычислений на CPU. Применение Core ML для сквозного многопоточного конвейера в источниках **NOT VERIFIED**.

## 5. Полный конфигурационный манифест конвейера GStreamer / DeepStream

Ниже представлены рабочие файлы конфигурации для развертывания конвейера на базе NVIDIA DeepStream SDK.

### 5.1. Главный манифест приложения (`deepstream_app_config.txt`)

Манифест конфигурирует прием RTSP-потока, параметры пакетной буферизации, привязку первичного инференса, трекера и модуля аналитики.

```ini
[application]
enable-perf-measurement=1
perf-measurement-interval-sec=5

[source0]
enable=1
# 4 = RTSP Streaming
type=4
uri=rtsp://admin:password@192.168.1.100:554/stream1
num-sources=1
gpu-id=0
nvbuf-memory-type=0
rtsp-reconnect-interval-sec=10

[streammux]
gpu-id=0
live-source=1
batch-size=1
batched-push-timeout=40000
width=1920
height=1080
enable-padding=0
nvbuf-memory-type=0

# Первичный детектор поз (YOLO26-Pose / YOLOv8-Pose)
[primary-gie]
enable=1
gpu-id=0
batch-size=1
gie-unique-id=1
nvbuf-memory-type=0
config-file=config_infer_primary_yolo_pose.txt

# Модуль трекинга объектов (ByteTrack / NvDCF)
[tracker]
enable=1
tracker-width=640
tracker-height=384
gpu-id=0
ll-lib-file=/opt/nvidia/deepstream/deepstream/lib/libnvds_nvmultiobjecttracker.so
ll-config-file=config_tracker_bytetrack.yml
enable-batch-process=1

# Модуль пространственно-временной аналитики зон
[nvds-analytics]
enable=1
config-file=config_nvdsanalytics.txt

[osd]
enable=1
gpu-id=0
border-width=2
text-size=12
text-color=1;1;1;1
text-bg-color=0.3;0.3;0.3;0.7
font=Arial
```

### 5.2. Конфигурация инференса детектора поз (`config_infer_primary_yolo_pose.txt`)

Файл задает параметры загрузки скомпилированного TensorRT-движка, нормализации входных данных и вызова кастомного парсера для извлечения 17 ключевых точек скелета.

```ini
[property]
gpu-id=0
net-scale-factor=0.003921569793457031
# Файл скомпилированного движка TensorRT
model-engine-file=models/yolo26s_pose_b1_gpu0_fp16.engine
onnx-file=models/yolo26s-pose.onnx
labelfile-path=labels.txt
batch-size=1
# Режим вычислений: 0=FP32, 1=FP16, 2=INT8
network-mode=1
num-detected-classes=1
interval=0
gie-unique-id=1
is-classifier=0
network-type=0
# Библиотека кастомного парсера выходов модели поз
custom-lib-path=/opt/nvidia/deepstream/deepstream/lib/libnvds_custom_yolo_pose_parser.so
parse-bbox-func-name=NvDsInferParseCustomYoloPose

[class-attrs-all]
pre-cluster-threshold=0.40
topk=100
nms-iou-threshold=0.45
```

### 5.3. Конфигурация зон контроля и Loitering (`config_nvdsanalytics.txt`)

Конфигурация определяет параметры запретных зон (ROI), пороговые лимиты скопления людей и таймеры нахождения в зоне до формирования тревожного события.

```ini
[property]
enable=1
osd-mode=2
display-font-size=12

[roi-filtering-stream-0]
enable=1
# Полигональные координаты зоны: x1;y1;x2;y2;...;xn;yn
roi-restricted-zone=450;300;1400;300;1550;950;350;950
inverse-roi=0
class-id=0

[overcrowding-stream-0]
enable=1
roi-restricted-zone=450;300;1400;300;1550;950;350;950
# Максимально допустимое количество людей в зоне
object-threshold=5
class-id=0

[loitering-stream-0]
enable=1
roi-restricted-zone=450;300;1400;300;1550;950;350;950
# Лимит времени нахождения в секундах до генерации тревоги
dwell-time-threshold-sec=10
class-id=0
```

## 6. Алгоритмический модуль правил геометрии поз и состояний человека

Представленный Python-модуль предназначен для встраивания в конвейер обработки метаданных (через GStreamer Probe или вторичный обработчик событий). Он реализует темпоральную фильтрацию состояний человека и детекцию падений, инвариантную к углам наклона камер наблюдения.

```python
"""
Модуль локального анализа поведения человека, детекции падений и контроля зон.
Основан на геометрии 17 ключевых точек скелета COCO-Pose (YOLO-Pose)
и темпоральной фильтрации состояний.
"""

import numpy as np
import time
from collections import deque
from enum import Enum

class HumanState(Enum):
    STANDING = "STANDING"
    WALKING = "WALKING"
    SITTING = "SITTING"
    FALLING = "FALLING"
    FALLEN = "FALLEN"

# Индексы ключевых точек стандарта COCO Keypoints
NOSE = 0
LEFT_SHOULDER, RIGHT_SHOULDER = 5, 6
LEFT_HIP, RIGHT_HIP = 11, 12
LEFT_KNEE, RIGHT_KNEE = 13, 14
LEFT_ANKLE, RIGHT_ANKLE = 15, 16

class TrackedPersonBehavior:
    def __init__(self, track_id: int, fps: float = 25.0):
        self.track_id = track_id
        self.fps = fps
        self.current_state = HumanState.STANDING
        self.state_history = deque(maxlen=int(fps * 3)) # Буфер истории на 3 секунды
        
        # Экспоненциальное скользящее среднее (EMA) высоты стоящего человека
        self.standing_height_ema = None
        self.ema_alpha = 0.05
        
        # Временные метки для фиксации падений и контроля зон
        self.falling_start_time = None
        self.zone_entry_time = None
        self.is_in_restricted_zone = False
        
        # Пороговые коэффициенты (извлечены из подтвержденных исследований)
        self.fall_time_threshold_sec = 0.8   # Время удержания горизонтального положения
        self.height_collapse_thresh = 0.55   # Схлопывание вертикального габарита относительно EMA
        self.aspect_ratio_fall_thresh = 1.15 # Отношение ширины к высоте bounding box
        self.torso_angle_fall_thresh = 55.0  # Угол отклонения вектора торса от вертикали (в градусах)

    def _calculate_torso_angle(self, keypoints: np.ndarray) -> float:
        """
        Вычисляет угол наклона торса относительно вертикали.
        Инвариантно к зеркальному положению тела.
        keypoints: массив координат размерностью (17, 3), где 3-я колонка - confidence.
        """
        shoulder_mid = (keypoints[LEFT_SHOULDER][:2] + keypoints[RIGHT_SHOULDER][:2]) / 2.0
        hip_mid = (keypoints[LEFT_HIP][:2] + keypoints[RIGHT_HIP][:2]) / 2.0
        
        dx = shoulder_mid[0] - hip_mid[0]
        dy = shoulder_mid[1] - hip_mid[1]
        
        # Вычисление угла вектора относительно вертикальной оси Y
        angle_rad = np.arctan2(np.abs(dx), np.abs(dy))
        return float(np.degrees(angle_rad))

    def update(self, bbox: list, keypoints: np.ndarray, timestamp: float, in_zone: bool) -> dict:
        """
        Обновляет статус наблюдаемого объекта на текущем кадре.
        bbox: [x1, y1, x2, y2]
        """
        x1, y1, x2, y2 = bbox
        width = max(1.0, float(x2 - x1))
        height = max(1.0, float(y2 - y1))
        aspect_ratio = width / height

        # 1. Анализ пребывания в зоне (Loitering)
        loitering_alert = False
        if in_zone:
            if not self.is_in_restricted_zone:
                self.is_in_restricted_zone = True
                self.zone_entry_time = timestamp
            elif (timestamp - self.zone_entry_time) >= 10.0:
                loitering_alert = True
        else:
            self.is_in_restricted_zone = False
            self.zone_entry_time = None

        # 2. Обновление базовой высоты (EMA) стоящего человека
        # Обновляется только в вертикальных состояниях, исключая искажение базы лежащим телом
        if self.current_state in [HumanState.STANDING, HumanState.WALKING]:
            if self.standing_height_ema is None:
                self.standing_height_ema = height
            else:
                self.standing_height_ema = (self.ema_alpha * height) + ((1.0 - self.ema_alpha) * self.standing_height_ema)

        # 3. Расчет признаков геометрии позы
        torso_angle = self._calculate_torso_angle(keypoints)
        height_ratio = (height / self.standing_height_ema) if self.standing_height_ema else 1.0

        # 4. Детекция признаков падения
        is_horizontal = (torso_angle >= self.torso_angle_fall_thresh) or (aspect_ratio >= self.aspect_ratio_fall_thresh)
        is_height_collapsed = (height_ratio <= self.height_collapse_thresh)

        new_state = self.current_state

        if is_horizontal or is_height_collapsed:
            if self.current_state not in [HumanState.FALLING, HumanState.FALLEN]:
                new_state = HumanState.FALLING
                self.falling_start_time = timestamp
            elif self.current_state == HumanState.FALLING:
                # Временная персистентность для фильтрации кратковременных наклонов
                if (timestamp - self.falling_start_time) >= self.fall_time_threshold_sec:
                    new_state = HumanState.FALLEN
        else:
            self.falling_start_time = None
            if height_ratio < 0.75:
                new_state = HumanState.SITTING
            else:
                new_state = HumanState.STANDING

        self.current_state = new_state
        self.state_history.append(new_state)

        return {
            "track_id": self.track_id,
            "state": self.current_state.value,
            "is_fallen": (self.current_state == HumanState.FALLEN),
            "loitering_alert": loitering_alert,
            "dwell_time_sec": (timestamp - self.zone_entry_time) if self.is_in_restricted_zone else 0.0,
            "metrics": {
                "aspect_ratio": round(aspect_ratio, 2),
                "torso_angle_deg": round(torso_angle, 1),
                "height_collapse_ratio": round(height_ratio, 2)
            }
        }
```

## 7. Комплексная стратегия оптимизации нагрузки для 64 потоков 1080p25

Масштабирование системы до 1600 кадров в секунду требует применения архитектурных паттернов многоуровневой фильтрации:

### 7.1. Пропуск кадров и компенсация через трекер
Инференс первичного детектора на каждом кадре избыточен. Задание параметра `interval=4` в модуле `nvinfer` сокращает частоту нейросетевых вычислений до 5 FPS на канал. В промежуточных кадрах координаты объектов интерполируются алгоритмом ByteTrack на основе фильтра Калмана, сохраняя непрерывность треков при пятикратном снижении нагрузки на тензорные ядра.

### 7.2. Разделение потоков: Substream для аналитики
Полноразмерный поток 1080p направляется напрямую в архив без распаковки каждого кадра. На вход модуля аналитики подается вторичный субпоток (Substream) с разрешением 640x360 или 720p. Это уменьшает объем декодируемых пикселей в 3–5 раз и устраняет накладные расходы на масштабирование кадров перед подачей в нейросеть.

### 7.3. Каскадирование инференса (GIE Cascading)
Тяжелые модели (оценка поз 17 точек, ST-GCN, классификаторы агрессии) не должны работать непрерывно по всему полю кадра. Они вызываются как вторичные классификаторы (Secondary GIE) строго для фрагментов изображений тех людей, которые вошли в контролируемый полигон или проявили подозрительную кинематику по данным трекера.

### 7.4. Динамическое батчирование и Zero-Copy
Объединение потоков в крупные батчи (размером 16 или 32 кадра) позволяет утилизировать пиковую пропускную способность тензорных ядер графических процессоров. Использование общей видеопамяти NVMM на базе DeepStream обеспечивает передачу декодированных кадров в TensorRT без копирования через оперативную память центрального процессора.

### 7.5. Устранение узкого горлышка NMS
В условиях плотного скопления людей операция Non-Maximum Suppression (NMS) в стандартных моделях (YOLOv8/v11) перегружает CPU, вызывая задержки до нескольких секунд. Переход на end-to-end детекторы без NMS (такие как RT-DETR) обеспечивает фиксированное время инференса независимо от количества людей в кадре.

### 7.6. Квантование весов моделей (INT8 / FP16)
Конвертация моделей в формат TensorRT с квантованием весов до 8-битных целых чисел (INT8) снижает требования к полосе пропускания памяти в 2–4 раза без существенной потери точности детекции поз и объектов.

## 8. Статус верификации и технические ограничения (Реестр NOT VERIFIED)

В соответствии со строгими критериями верификации данных, приведенные ниже технические свойства и утверждения не имеют подтверждения в исследованных источниках и требуют предварительного лабораторного тестирования:

1. **Пропускная способность и задержка мультимодальных моделей (VLM)**: Метрики FPS, времени отклика и аппаратные требования для потокового запуска моделей класса VERA, VadCLIP и AnyAnomaly на RTSP-потоках в источниках **NOT VERIFIED**.
2. **Сквозной конвейер Core ML на 64 потока**: Возможность одновременного аппаратного декодирования и непрерывного инференса 64 потоков Full HD средствами Apple Core ML / Metal на процессорах Apple Silicon (M-серии) в источниках **NOT VERIFIED**.
3. **Готовый парсер YOLO-Pose в DeepStream SDK**: Наличие универсального скомпилированного бинарного парсера для извлечения 17 ключевых точек COCO в стандартной поставке `deepstream_python_apps` в источниках **NOT VERIFIED** (требует индивидуальной сборки под структуру выходного тензора модели).
4. **Точность детекции драк YOLOv8 на CCTV**: Показатели точности (mAP / Recall / F1) специализированных легковесных весов YOLOv8-violence на эталонных датасетах видеонаблюдения в репозитории автора **NOT VERIFIED**.
5. **Точный расчет GPU-сервера под 64 канала 1080p25**: Точное число графических карт NVIDIA (RTX 4090 / A100 / L40) для гарантированной обработки 64 каналов в режиме 25 к/с без пропуска кадров в источниках **NOT VERIFIED**.
