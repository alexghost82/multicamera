#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build-only) ;; *) echo "usage: $0 [run|--verify|--build-only]" >&2; exit 2 ;; esac
cd "$ROOT_DIR/native"
set -- app
for model in "$PWD/.build/models/yolo26n-seg.onnx" "$PWD/.build/models/yolo26s-pose.mlpackage"; do
    # Existing exported models do not require recreating their Python exporters.
    [ ! -e "$model" ] || set -- -o "$model" "$@"
done
make "$@"
APP="$PWD/dist/Camera Vault.app"
STAGE="$PWD/dist/Camera Vault.staging.app"
rm -rf "$STAGE"
ditto dist/CameraWall.app "$STAGE"
BIN_DIR="$(swift build -c release --disable-automatic-resolution --show-bin-path)"
for resource in "$BIN_DIR"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$STAGE/Contents/Resources/$(basename "$resource")"
done
METAL_LIBRARY="$STAGE/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ -f "$METAL_LIBRARY" ]; then
    cp "$METAL_LIBRARY" "$STAGE/Contents/MacOS/mlx.metallib"
fi
mkdir -p "$STAGE/Contents/Frameworks"
for framework in "$BIN_DIR"/*.framework; do
    [ -d "$framework" ] || continue
    ditto "$framework" "$STAGE/Contents/Frameworks/$(basename "$framework")"
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Camera Vault' "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Camera Vault' "$STAGE/Contents/Info.plist"
codesign --force --deep --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
if [ "$MODE" != --build-only ]; then
    pkill -x CameraWall || true
    open -n "$APP"
    if [ "$MODE" = --verify ]; then
        sleep 5
        pgrep -x CameraWall >/dev/null
    fi
fi
