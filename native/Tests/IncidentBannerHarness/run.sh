#!/bin/bash
# Compiles the production engine and CameraCore with inert inference-only stubs.
# No CameraWall app target, model packages, cameras, or credentials are loaded.
set -eu
cd "$(dirname "$0")/../../.."
root="$PWD"
build="$root/native/Tests/IncidentBannerHarness/.build"
xcode="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
mkdir -p "$build/cache" "$build/Tests.xctest/Contents/MacOS"
export TMPDIR="$build"
cat > "$build/Tests.xctest/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tests</string>
<key>CFBundleIdentifier</key><string>local.incident-banner-tests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
swiftc -parse-as-library -enable-testing -module-name CameraCore \
  -emit-module -emit-module-path "$build/CameraCore.swiftmodule" \
  -emit-object -whole-module-optimization -o "$build/CameraCore.o" \
  -module-cache-path "$build/cache" native/Sources/CameraCore/*.swift
swiftc -parse-as-library -enable-testing -module-name CameraWall \
  -emit-module -emit-module-path "$build/CameraWall.swiftmodule" \
  -emit-object -whole-module-optimization -o "$build/CameraWall.o" \
  -module-cache-path "$build/cache" -I "$build" \
  native/Sources/CameraWall/LocalVideoAnalyticsEngine.swift \
  native/Sources/CameraWall/ACTAAnalyticsSettingsWriteGate.swift \
  native/Sources/CameraWall/AnalyticsWorkTracker.swift \
  native/Sources/CameraWall/CameraRuntimeWorkGroup.swift \
  native/Sources/CameraWall/CameraNetworkLifecycle.swift \
  native/Tests/IncidentBannerHarness/Stubs.swift
swiftc -emit-library -module-name IncidentBannerTests \
  -module-cache-path "$build/cache" -I "$build" -I "$xcode/usr/lib" \
  -F "$xcode/Library/Frameworks" -L "$xcode/usr/lib" \
  -lXCTestSwiftSupport -lsqlite3 -framework XCTest \
  native/Tests/CameraWallTests/IncidentBannerPersistenceTests.swift \
  native/Tests/IncidentBannerHarness/AnalyticsEngineDrainTests.swift \
  "$build/CameraCore.o" "$build/CameraWall.o" -o "$build/Tests.xctest/Contents/MacOS/Tests"
if [ "$#" -gt 0 ]; then
  xcrun xctest -XCTest "$1" "$build/Tests.xctest"
else
  xcrun xctest "$build/Tests.xctest"
fi
