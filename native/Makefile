GO2RTC_VERSION := 1.9.15
GO2RTC := $(CURDIR)/.build/tools/go2rtc
VLM_MODEL ?= $(CURDIR)/.build/models/qwen3.5-9b
REID_PERSON_MODEL := $(CURDIR)/.build/models/yolo26m-reid.onnx
REID_VEHICLE_MODEL := $(CURDIR)/.build/models/osnet_ain_x1_0_vehicle_reid.onnx
SEG_MODEL_PT := $(CURDIR)/.build/models/yolo26n-seg.pt
SEG_MODEL_ONNX := $(CURDIR)/.build/models/yolo26n-seg.onnx
SEG_EXPORTER_DIR := $(CURDIR)/.build/seg-exporter
SEG_EXPORTER_PYTHON := $(SEG_EXPORTER_DIR)/bin/python
SEG_EXPORTER_READY := $(SEG_EXPORTER_DIR)/.ready
POSE_MODEL_PT := $(CURDIR)/.build/models/yolo26s-pose.pt
POSE_MODEL_PACKAGE := $(CURDIR)/.build/models/yolo26s-pose.mlpackage
POSE_EXPORTER_DIR := $(CURDIR)/.build/pose-exporter-py313-torch27
POSE_EXPORTER_PYTHON := $(POSE_EXPORTER_DIR)/bin/python
POSE_EXPORTER_READY := $(POSE_EXPORTER_DIR)/.ready
ICON_SOURCE ?= $(CURDIR)/../icon.png
APP_ICON := $(CURDIR)/Resources/CameraWall.icns
ICONSET := $(CURDIR)/.build/CameraWall.iconset
SWIFT_HOST := $(dir $(shell xcrun --find swift))../lib/swift/host

.PHONY: setup model icon localization-audit reid-models test-reid seg-models test-seg pose-model test-pose build test stress app run

model: .build/models/yolo26n.mlmodelc/coremldata.bin

localization-audit:
	swift -I "$(SWIFT_HOST)" -L "$(SWIFT_HOST)" -Xlinker -rpath -Xlinker "$(SWIFT_HOST)" scripts/LocalizationAudit.swift --check
	plutil -lint Resources/ru.lproj/Localizable.strings Resources/ru.lproj/InfoPlist.strings

icon: $(APP_ICON)

$(APP_ICON): $(ICON_SOURCE)
	mkdir -p "$(ICONSET)" "$(dir $(APP_ICON))"
	for size in 16 32 128 256 512; do \
		sips -z $$size $$size "$(ICON_SOURCE)" --out "$(ICONSET)/icon_$${size}x$${size}.png" >/dev/null; \
		retina=$$((size * 2)); \
		sips -z $$retina $$retina "$(ICON_SOURCE)" --out "$(ICONSET)/icon_$${size}x$${size}@2x.png" >/dev/null; \
	done
	iconutil -c icns "$(ICONSET)" -o "$@"

reid-models: $(REID_PERSON_MODEL) $(REID_VEHICLE_MODEL)

$(REID_PERSON_MODEL):
	mkdir -p .build/models
	curl --fail --location --show-error https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26m-reid.onnx --output "$@.part"
	mv "$@.part" "$@"

$(REID_VEHICLE_MODEL):
	mkdir -p .build/models
	curl --fail --location --show-error https://storage.openvinotoolkit.org/repositories/open_model_zoo/public/2022.1/vehicle-reid-0001/osnet_ain_x1_0_vehicle_reid.onnx --output "$@.part"
	mv "$@.part" "$@"

test-reid: reid-models
	swift test --filter ONNXReIDEncoderTests

seg-models: $(SEG_MODEL_ONNX)

$(SEG_MODEL_PT):
	mkdir -p .build/models
	curl --fail --location --show-error https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26n-seg.pt --output "$@.part"
	mv "$@.part" "$@"

$(SEG_EXPORTER_READY): requirements-seg-export.txt
	python3 -m venv "$(SEG_EXPORTER_DIR)"
	"$(SEG_EXPORTER_PYTHON)" -m pip install --upgrade pip
	"$(SEG_EXPORTER_PYTHON)" -m pip install -r requirements-seg-export.txt
	touch "$@"

$(SEG_MODEL_ONNX): $(SEG_MODEL_PT) $(SEG_EXPORTER_READY)
	"$(SEG_EXPORTER_PYTHON)" -c 'from ultralytics import YOLO; YOLO("$(SEG_MODEL_PT)").export(format="onnx", imgsz=640, dynamic=False, nms=False, simplify=False)'
	test -s "$@"

test-seg: seg-models
	swift test --filter ONNXSegmentationTests

$(POSE_MODEL_PT):
	mkdir -p "$(dir $@)"
	curl --fail --location --show-error --retry 3 https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26s-pose.pt --output "$@.part"
	printf '%s  %s\n' 'a083adb42303728ae14c4bd6bd56d80da46f82fb2564dbd6f31dcc92ea321646' "$@.part" | shasum -a 256 -c -
	mv "$@.part" "$@"

$(POSE_EXPORTER_READY): requirements-pose-export.txt
	python3.13 -m venv "$(POSE_EXPORTER_DIR)"
	"$(POSE_EXPORTER_PYTHON)" -m pip install --upgrade pip
	"$(POSE_EXPORTER_PYTHON)" -m pip install -r requirements-pose-export.txt
	touch "$@"

$(POSE_MODEL_PACKAGE): $(POSE_MODEL_PT) $(POSE_EXPORTER_READY)
	"$(POSE_EXPORTER_PYTHON)" -c 'from ultralytics import YOLO; YOLO("$(POSE_MODEL_PT)").export(format="coreml", imgsz=640, quantize=16, batch=1, dynamic=False, device="cpu")'
	test -d "$@"

pose-model: $(POSE_MODEL_PACKAGE)

test-pose: pose-model .build/models/bus.jpg
	swift test --filter YOLO26PoseDetectorTests

.build/models/yolo26n.mlmodelc/coremldata.bin:
	mkdir -p .build/models
	curl --fail --location --show-error https://github.com/ultralytics/yolo-ios-app/releases/download/v8.3.0/yolo26n.mlpackage.zip --output .build/models/yolo26n.zip
	unzip -q -o .build/models/yolo26n.zip -d .build/models
	xcrun coremlcompiler compile .build/models/yolo26n.mlpackage .build/models

setup: .build/tools/go2rtc

.build/tools/go2rtc:
	mkdir -p .build/tools
	curl --fail --location --show-error "https://github.com/AlexxIT/go2rtc/releases/download/v$(GO2RTC_VERSION)/go2rtc_mac_arm64.zip" --output .build/go2rtc.zip
	unzip -o .build/go2rtc.zip -d .build/tools
	chmod +x .build/tools/go2rtc
	.build/tools/go2rtc -version

build:
	swift build -c release --disable-automatic-resolution --jobs 1

test: setup model .build/models/bus.jpg
	CAMERAWALL_GO2RTC="$(GO2RTC)" swift test

.build/models/bus.jpg:
	mkdir -p .build/models
	curl --fail --location --show-error https://ultralytics.com/images/bus.jpg --output .build/models/bus.jpg

stress: setup
	CAMERAWALL_GO2RTC="$(GO2RTC)" CAMERAWALL_TEST_STREAMS=60 swift test

app: build setup model reid-models seg-models icon
	test -f "$(VLM_MODEL)/config.json"
	mkdir -p dist/CameraWall.app/Contents/MacOS dist/CameraWall.app/Contents/Helpers
	cp .build/release/CameraWall dist/CameraWall.app/Contents/MacOS/CameraWall
	cp .build/tools/go2rtc dist/CameraWall.app/Contents/Helpers/go2rtc
	mkdir -p dist/CameraWall.app/Contents/Resources
	cp -R .build/models/yolo26n.mlmodelc dist/CameraWall.app/Contents/Resources/
	cp .build/models/yolo26m-reid.onnx .build/models/osnet_ain_x1_0_vehicle_reid.onnx dist/CameraWall.app/Contents/Resources/
	cp .build/models/yolo26n-seg.onnx dist/CameraWall.app/Contents/Resources/
	rm -rf dist/CameraWall.app/Contents/Resources/qwen3.5-9b
	cp -R "$(VLM_MODEL)" dist/CameraWall.app/Contents/Resources/qwen3.5-9b
	cp acta-logo.png dist/CameraWall.app/Contents/Resources/acta-logo.png
	cp "$(APP_ICON)" dist/CameraWall.app/Contents/Resources/CameraWall.icns
	cp -R Resources/en.lproj Resources/ru.lproj dist/CameraWall.app/Contents/Resources/
	cp Info.plist dist/CameraWall.app/Contents/Info.plist
	codesign --force --deep --sign - dist/CameraWall.app

run: app
	open dist/CameraWall.app
