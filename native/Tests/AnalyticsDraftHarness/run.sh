#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
WORK="$ROOT/.analytics-draft-harness-$(uuidgen)"
mkdir "$WORK"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/work" "$WORK/Tests.xctest/Contents/MacOS"
export TMPDIR="$WORK/work"
PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path)"
FRAMEWORKS="$PLATFORM/Developer/Library/Frameworks"
XCTEST_LIB="$PLATFORM/Developer/usr/lib"

swiftc -emit-library -emit-module -enable-testing -module-name CameraCore \
    native/Sources/CameraCore/*.swift -lsqlite3 \
    -emit-module-path "$WORK/CameraCore.swiftmodule" -o "$WORK/libCameraCore.dylib"
swiftc -emit-library -emit-module -enable-testing -module-name CameraWall \
    -I "$WORK" -L "$WORK" -lCameraCore \
    native/Sources/CameraWall/ACTAAnalyticsDraftDeletion.swift \
    native/Sources/CameraWall/ACTACameraWriterGate.swift \
    native/Sources/CameraWall/ACTAPreparedAnalyticsSettingsAction.swift \
    -emit-module-path "$WORK/CameraWall.swiftmodule" -o "$WORK/libCameraWall.dylib"
swiftc -emit-library -module-name AnalyticsDraftTests -F "$FRAMEWORKS" -I "$XCTEST_LIB" \
    -I "$WORK" -L "$WORK" -lCameraCore -lCameraWall -L "$XCTEST_LIB" -lXCTestSwiftSupport \
    native/Tests/CameraWallTests/ACTAAnalyticsDraftDeletionTests.swift \
    native/Tests/CameraWallTests/ACTAPreparedCameraAnalyticsActionTests.swift \
    -o "$WORK/Tests.xctest/Contents/MacOS/Tests"
swiftc -typecheck -I "$WORK" \
    native/Sources/CameraWall/ACTAAnalyticsSettingsWriteGate.swift \
    native/Sources/CameraWall/ACTAAnalyticsDraftDeletion.swift \
    native/Sources/CameraWall/SettingsFields.swift \
    native/Sources/CameraWall/AnalyticsSettingsEditor.swift \
    native/Tests/AnalyticsDraftHarness/EditorStubs.swift
plutil -lint native/Resources/en.lproj/Localizable.strings native/Resources/ru.lproj/Localizable.strings
cd "$WORK"
DYLD_LIBRARY_PATH="$WORK:$XCTEST_LIB" xcrun xctest "$WORK/Tests.xctest"
