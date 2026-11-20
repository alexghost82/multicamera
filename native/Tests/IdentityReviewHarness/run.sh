#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../../.."
harness=".identity-review-test-$(uuidgen)"
mkdir "$harness"
trap 'rm -rf "$harness"' EXIT
mkdir -p "$harness/Sources" "$harness/Tests/CoreTests" "$harness/work"
ln -s "../../native/Sources/CameraCore" "$harness/Sources/CameraCore"
ln -s "../../../native/Tests/CameraCoreTests/CrossCameraIdentityReviewServiceTests.swift" "$harness/Tests/CoreTests/CrossCameraIdentityReviewServiceTests.swift"
ln -s "../../../native/Tests/CameraCoreTests/IsolatedStoreTestDirectory.swift" "$harness/Tests/CoreTests/IsolatedStoreTestDirectory.swift"
printf '%s\n' \
    '// swift-tools-version: 5.9' \
    'import PackageDescription' \
    'let package = Package(name: "IdentityReviewHarness", platforms: [.macOS("27.0")], targets: [.target(name: "CameraCore", linkerSettings: [.linkedLibrary("sqlite3")]), .testTarget(name: "CoreTests", dependencies: ["CameraCore"])])' \
    > "$harness/Package.swift"
TMPDIR="$PWD/$harness/work" swift test --package-path "$harness" --filter CrossCameraIdentityReviewServiceTests --jobs 2
