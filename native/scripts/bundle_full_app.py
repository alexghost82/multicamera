#!/usr/bin/env python3
"""
Builds a 100% self-contained native/dist/CameraWall.app bundle containing:
  - Release CameraWall executable + ALL transitive FFmpeg/codec dylibs in Contents/Frameworks
  - Bundled go2rtc helper (Contents/Helpers/go2rtc)
  - Bundled espeak-ng helper + relinked dylibs + espeak-ng-data (offline TTS)
  - Bundled Python 3.12 + vllm-metal 0.30.0 runtime + relocatable launcher (Contents/Helpers/vllm)
  - ALL CoreML / ONNX / MLX Qwen3.5-9B models & SwiftPM resource bundles in Contents/Resources
  - Localizations (EN/RU), icon, Info.plist, and ad-hoc codesign with CameraWall.entitlements
"""
import os
import shutil
import stat
import subprocess
import sys
from collections import deque
from pathlib import Path

NATIVE_DIR = Path(__file__).resolve().parent.parent
BUILD_DIR = NATIVE_DIR / ".build"
RELEASE_DIR = BUILD_DIR / "arm64-apple-macosx" / "release"
APP_DIR = NATIVE_DIR / "dist" / "CameraWall.app"
CONTENTS = APP_DIR / "Contents"
MACOS_DIR = CONTENTS / "MacOS"
FRAMEWORKS_DIR = CONTENTS / "Frameworks"
HELPERS_DIR = CONTENTS / "Helpers"
RESOURCES_DIR = CONTENTS / "Resources"

SYSTEM_PREFIXES = ("/System/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")


def run(cmd, check=True, capture=False, env=None, input_bytes=None):
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=(input_bytes is None and capture),
        env=env,
        input=input_bytes,
    )


def otool_deps(binary_path: Path):
    out = run(["otool", "-L", str(binary_path)], capture=True).stdout
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dep = line.split(" (compatibility version", 1)[0].strip()
        if dep:
            deps.append(dep)
    return deps


def otool_rpaths(binary_path: Path):
    out = run(["otool", "-l", str(binary_path)], capture=True).stdout
    rpaths = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for j in range(i + 1, min(i + 6, len(lines))):
                if "path " in lines[j]:
                    rpath = lines[j].strip().split("path ", 1)[1].split(" (offset", 1)[0].strip()
                    rpaths.append(rpath)
                    break
    return rpaths


def is_external_dylib(path_str: str) -> bool:
    if not path_str or path_str.startswith(SYSTEM_PREFIXES):
        return False
    return path_str.startswith("/")


def resolve_dylib_source(dep_path: str, referrer: Path) -> Path:
    p = Path(dep_path)
    if p.exists():
        return p.resolve()
    # Try @loader_path / homebrew fallback if needed
    candidate = Path("/opt/homebrew/lib") / p.name
    if candidate.exists():
        return candidate.resolve()
    raise FileNotFoundError(f"Cannot resolve dylib '{dep_path}' referenced by {referrer}")


def make_writable(path: Path):
    try:
        mode = path.stat().st_mode
        os.chmod(path, mode | stat.S_IWUSR)
    except OSError:
        pass


def copy_tree_clean(src: Path, dst: Path):
    if dst.exists() or dst.is_symlink():
        if dst.is_dir() and not dst.is_symlink():
            shutil.rmtree(dst)
        else:
            dst.unlink()
    shutil.copytree(src, dst, symlinks=True)


def bundle_dylibs(seed_binaries, frameworks_dir: Path, ref_prefix_for_binary):
    """
    Recursively copies all non-system dylibs referenced by seed_binaries into frameworks_dir
    and rewrites LC_ID_DYLIB + LC_LOAD_DYLIB on every copied dylib and seed binary.
    """
    frameworks_dir.mkdir(parents=True, exist_ok=True)
    # Map canonical realpath -> bundled filename in Contents/Frameworks
    bundled_by_name = {}
    queue = deque()

    # First register any already-present dylibs
    for existing in frameworks_dir.glob("*.dylib"):
        bundled_by_name[existing.name] = existing

    def enqueue_deps(target_bin: Path, is_framework_dylib: bool):
        for dep in otool_deps(target_bin):
            if not is_external_dylib(dep):
                continue
            # Ignore self-ID line if otool -L reports it
            dep_name = Path(dep).name
            if is_framework_dylib and dep_name == target_bin.name:
                continue
            if "/vllm-metal/libexec/" in dep:
                continue
            if not Path(dep).exists() and not (Path("/opt/homebrew/lib") / dep_name).exists():
                continue
            src = resolve_dylib_source(dep, target_bin)
            if dep_name not in bundled_by_name:
                dst = frameworks_dir / dep_name
                shutil.copy2(src, dst)
                make_writable(dst)
                bundled_by_name[dep_name] = dst
                queue.append(dst)
            new_ref = f"@loader_path/{dep_name}" if is_framework_dylib else ref_prefix_for_binary(target_bin, dep_name)
            make_writable(target_bin)
            run(["install_name_tool", "-change", dep, new_ref, str(target_bin)])

    for seed in seed_binaries:
        enqueue_deps(seed, is_framework_dylib=False)

    while queue:
        dylib = queue.popleft()
        make_writable(dylib)
        run(["install_name_tool", "-id", f"@loader_path/{dylib.name}", str(dylib)])
        enqueue_deps(dylib, is_framework_dylib=True)

    return bundled_by_name


def bundle_vllm_runtime(helpers_dir: Path, resources_dir: Path, frameworks_dir: Path):
    """
    Bundles Homebrew Python 3.12 Framework + vllm-metal 0.30.0 site-packages into
    Contents/Resources/vllm-runtime/ (so Apple codesign seals *.dist-info cleanly)
    and creates a relocatable Contents/Helpers/vllm launcher.
    """
    py_cellar = sorted(Path("/opt/homebrew/Cellar/python@3.12").glob("*"))[-1]
    py_fw_src = py_cellar / "Frameworks" / "Python.framework"
    vllm_cellar = sorted(Path("/opt/homebrew/Cellar/vllm-metal").glob("*"))[-1]
    vllm_site_src = vllm_cellar / "libexec" / "lib" / "python3.12" / "site-packages"

    runtime_dir = resources_dir / "vllm-runtime"
    if runtime_dir.exists():
        shutil.rmtree(runtime_dir)
    runtime_dir.mkdir(parents=True, exist_ok=True)

    print(f"[bundle] Copying Python 3.12 framework from {py_fw_src}...")
    py_fw_dst = runtime_dir / "Python.framework"
    copy_tree_clean(py_fw_src, py_fw_dst)

    # Fix internal Python.framework install_names to be 100% relocatable
    py_ver = py_fw_dst / "Versions" / "3.12"
    py_lib = py_ver / "Python"
    make_writable(py_lib)
    run(["install_name_tool", "-id", "@rpath/Python", str(py_lib)])

    py_bin = py_ver / "bin" / "python3.12"
    make_writable(py_bin)
    for dep in otool_deps(py_bin):
        if dep.endswith("/Python.framework/Versions/3.12/Python"):
            run(["install_name_tool", "-change", dep, "@executable_path/../Python", str(py_bin)])

    py_app_bin = py_ver / "Resources" / "Python.app" / "Contents" / "MacOS" / "Python"
    if py_app_bin.exists():
        make_writable(py_app_bin)
        for dep in otool_deps(py_app_bin):
            if dep.endswith("/Python.framework/Versions/3.12/Python"):
                run(["install_name_tool", "-change", dep, "@executable_path/../../../../Python", str(py_app_bin)])

    # Bundle external Homebrew dylibs referenced by Python lib-dynload/*.so into Contents/Frameworks
    # Relative path from Contents/Helpers/vllm-runtime/Python.framework/Versions/3.12/lib/python3.12/lib-dynload/*.so
    # to Contents/Frameworks is 8 levels up: ../../../../../../../../Frameworks
    dynload_dir = py_ver / "lib" / "python3.12" / "lib-dynload"
    dynload_sos = list(dynload_dir.glob("*.so"))
    bundle_dylibs(
        dynload_sos,
        frameworks_dir,
        ref_prefix_for_binary=lambda _b, name: f"@loader_path/../../../../../../../../Frameworks/{name}",
    )

    print(f"[bundle] Copying vllm-metal site-packages from {vllm_site_src} (~1.9 GB)...")
    site_dst = runtime_dir / "site-packages"
    copy_tree_clean(vllm_site_src, site_dst)

    # Repoint Python.framework's site-packages symlink to our bundled vllm-runtime/site-packages
    py_site_link = py_ver / "lib" / "python3.12" / "site-packages"
    if py_site_link.is_symlink() or py_site_link.exists():
        if py_site_link.is_dir() and not py_site_link.is_symlink():
            shutil.rmtree(py_site_link)
        else:
            py_site_link.unlink()
    os.symlink("../../../../../site-packages", py_site_link)

    # Relink any Homebrew dylibs referenced by vllm-metal native extensions (.so / .dylib)
    ext_bins = []
    for root, _, files in os.walk(site_dst):
        for fn in files:
            if fn.endswith(".so") or fn.endswith(".dylib"):
                full = Path(root) / fn
                if not full.is_symlink():
                    ext_bins.append(full)

    def rel_to_frameworks(binary_path: Path, dep_name: str) -> str:
        rel = os.path.relpath(frameworks_dir, binary_path.parent)
        return f"@loader_path/{rel}/{dep_name}"

    ext_relinked = 0
    for ext in ext_bins:
        deps = otool_deps(ext)
        ext_deps = [d for d in deps if is_external_dylib(d) and Path(d).name != ext.name]
        if ext_deps:
            # Skip references internal to vllm-metal/libexec or nonexistent build-time paths
            external_only = [
                d for d in ext_deps
                if ("/opt/homebrew/" in d or "/usr/local/" in d)
                and "/vllm-metal/libexec/" not in d
                and (Path(d).exists() or (Path("/opt/homebrew/lib") / Path(d).name).exists())
            ]
            if external_only:
                bundle_dylibs([ext], frameworks_dir, ref_prefix_for_binary=rel_to_frameworks)
                ext_relinked += 1
    print(f"[bundle] Relinked {ext_relinked} vllm-metal native extension(s) against Contents/Frameworks.")

    # Write self-locating relocatable Contents/Helpers/vllm launcher
    launcher = helpers_dir / "vllm"
    launcher.write_text(
        """#!/bin/sh
set -e
HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTENTS_DIR="$(cd "$HELPER_DIR/.." && pwd)"
RUNTIME_DIR="$CONTENTS_DIR/Resources/vllm-runtime"
PY_VER="$RUNTIME_DIR/Python.framework/Versions/3.12"
export PYTHONHOME="$PY_VER"
export PYTHONPATH="$RUNTIME_DIR/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$CONTENTS_DIR/Frameworks${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export HF_HUB_DISABLE_TELEMETRY=1
export VLLM_NO_USAGE_STATS=1
exec "$PY_VER/bin/python3.12" -m vllm.entrypoints.cli.main "$@"
""",
        encoding="utf-8",
    )
    os.chmod(launcher, 0o755)


def codesign_path(path: Path, entitlements: Path = None):
    cmd = ["codesign", "--force", "--sign", "-"]
    if entitlements is not None:
        cmd += ["--entitlements", str(entitlements)]
    cmd.append(str(path))
    run(cmd)


def main():
    release_bin = RELEASE_DIR / "CameraWall"
    if not release_bin.exists():
        print(f"ERROR: Release binary missing at {release_bin}. Run swift build -c release first.", file=sys.stderr)
        sys.exit(1)

    # Preserve existing mlx-swift_Cmlx.bundle (contains compiled default.metallib) before refreshing Resources
    cmlx_backup = BUILD_DIR / "cmlx-bundle-backup"
    existing_cmlx = RESOURCES_DIR / "mlx-swift_Cmlx.bundle"
    if existing_cmlx.exists():
        copy_tree_clean(existing_cmlx, cmlx_backup)
    elif (BUILD_DIR / "arm64-apple-macosx" / "debug" / "mlx-swift_Cmlx.bundle").exists():
        copy_tree_clean(BUILD_DIR / "arm64-apple-macosx" / "debug" / "mlx-swift_Cmlx.bundle", cmlx_backup)

    # Prepare clean Contents layout (preserving large qwen3.5-9b if already identical? Copy fresh from .build/models!)
    MACOS_DIR.mkdir(parents=True, exist_ok=True)
    HELPERS_DIR.mkdir(parents=True, exist_ok=True)
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    if FRAMEWORKS_DIR.exists():
        shutil.rmtree(FRAMEWORKS_DIR)
    FRAMEWORKS_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Copy Release executable
    app_bin = MACOS_DIR / "CameraWall"
    shutil.copy2(release_bin, app_bin)
    make_writable(app_bin)

    # Strip external /opt/homebrew rpath from CameraWall & add @executable_path/../Frameworks
    for rp in otool_rpaths(app_bin):
        if "/opt/homebrew/" in rp or "/usr/local/" in rp:
            run(["install_name_tool", "-delete_rpath", rp, str(app_bin)])
    if "@executable_path/../Frameworks" not in otool_rpaths(app_bin):
        run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(app_bin)])

    # 2. Copy go2rtc helper
    go2rtc_src = BUILD_DIR / "tools" / "go2rtc"
    go2rtc_dst = HELPERS_DIR / "go2rtc"
    shutil.copy2(go2rtc_src, go2rtc_dst)
    os.chmod(go2rtc_dst, 0o755)

    # 3. Copy espeak-ng helper + espeak-ng-data
    espeak_src = Path("/opt/homebrew/bin/espeak-ng").resolve()
    espeak_dst = HELPERS_DIR / "espeak-ng"
    shutil.copy2(espeak_src, espeak_dst)
    os.chmod(espeak_dst, 0o755)
    espeak_data_src = espeak_src.parent.parent / "share" / "espeak-ng-data"
    copy_tree_clean(espeak_data_src, RESOURCES_DIR / "espeak-ng-data")

    # 4. Bundle ALL transitive dylibs for CameraWall + espeak-ng into Contents/Frameworks
    print("[bundle] Recursively bundling dylibs for CameraWall and espeak-ng...")
    bundled = bundle_dylibs(
        [app_bin, espeak_dst],
        FRAMEWORKS_DIR,
        ref_prefix_for_binary=lambda _b, name: f"@executable_path/../Frameworks/{name}",
    )
    print(f"[bundle] Bundled {len(bundled)} dylibs for CameraWall + espeak-ng.")

    # 5. Bundle vllm-metal 0.30.0 + Python 3.12 runtime
    bundle_vllm_runtime(HELPERS_DIR, RESOURCES_DIR, FRAMEWORKS_DIR)
    total_fw_dylibs = len(list(FRAMEWORKS_DIR.glob("*.dylib")))
    print(f"[bundle] Total self-contained dylibs in Contents/Frameworks: {total_fw_dylibs}")

    # 6. Copy all models, SwiftPM bundles, localizations, icon, Info.plist
    print("[bundle] Copying all AI/Vision models and resources into Contents/Resources...")
    models_dir = BUILD_DIR / "models"
    copy_tree_clean(models_dir / "yolo26n.mlmodelc", RESOURCES_DIR / "yolo26n.mlmodelc")
    copy_tree_clean(models_dir / "yolo26s-pose.mlpackage", RESOURCES_DIR / "yolo26s-pose.mlpackage")
    shutil.copy2(models_dir / "yolo26m-reid.onnx", RESOURCES_DIR / "yolo26m-reid.onnx")
    shutil.copy2(models_dir / "osnet_ain_x1_0_vehicle_reid.onnx", RESOURCES_DIR / "osnet_ain_x1_0_vehicle_reid.onnx")
    shutil.copy2(models_dir / "yolo26n-seg.onnx", RESOURCES_DIR / "yolo26n-seg.onnx")
    copy_tree_clean(models_dir / "qwen3.5-9b", RESOURCES_DIR / "qwen3.5-9b")

    for bundle_name in ["CameraWall_CameraWall.bundle", "swift-crypto_Crypto.bundle", "swift-transformers_Hub.bundle"]:
        src_b = RELEASE_DIR / bundle_name
        if src_b.exists():
            copy_tree_clean(src_b, RESOURCES_DIR / bundle_name)
    if cmlx_backup.exists():
        copy_tree_clean(cmlx_backup, RESOURCES_DIR / "mlx-swift_Cmlx.bundle")
        shutil.rmtree(cmlx_backup)

    shutil.copy2(NATIVE_DIR / "acta-logo.png", RESOURCES_DIR / "acta-logo.png")
    shutil.copy2(NATIVE_DIR / "Resources" / "CameraWall.icns", RESOURCES_DIR / "CameraWall.icns")
    copy_tree_clean(NATIVE_DIR / "Resources" / "en.lproj", RESOURCES_DIR / "en.lproj")
    copy_tree_clean(NATIVE_DIR / "Resources" / "ru.lproj", RESOURCES_DIR / "ru.lproj")
    shutil.copy2(NATIVE_DIR / "Info.plist", CONTENTS / "Info.plist")

    # 7. Verify ZERO /opt/homebrew or /usr/local dependencies on CameraWall, espeak-ng, and Contents/Frameworks/*.dylib
    print("[verify] Checking zero external Homebrew/usr-local dylib dependencies...")
    leaks = []
    for check_bin in [app_bin, espeak_dst] + list(FRAMEWORKS_DIR.glob("*.dylib")):
        for dep in otool_deps(check_bin):
            if "/opt/homebrew/" in dep or "/usr/local/" in dep:
                leaks.append(f"{check_bin.name} -> {dep}")
    if leaks:
        print("ERROR: External dylib references remain:\n  " + "\n  ".join(leaks), file=sys.stderr)
        sys.exit(2)
    print("[verify] PASS: 0 external /opt/homebrew or /usr/local dylib references in CameraWall, espeak-ng, or Contents/Frameworks!")

    # 8. Codesign inside-out cleanly
    print("[codesign] Signing Contents/Frameworks, Contents/Helpers, and CameraWall.app...")
    for dylib in sorted(FRAMEWORKS_DIR.glob("*.dylib")):
        codesign_path(dylib)
    codesign_path(go2rtc_dst)
    codesign_path(espeak_dst)

    # Sign Python framework & vllm native binaries
    vllm_runtime = RESOURCES_DIR / "vllm-runtime"
    for root, _, files in os.walk(vllm_runtime):
        for fn in files:
            p = Path(root) / fn
            if p.is_symlink():
                continue
            if fn.endswith(".so") or fn.endswith(".dylib") or fn in ("Python", "python3.12"):
                make_writable(p)
                codesign_path(p)
    codesign_path(HELPERS_DIR / "vllm")
    codesign_path(APP_DIR, entitlements=NATIVE_DIR / "CameraWall.entitlements")

    print("[verify] Running codesign --verify --deep --strict --verbose=2...")
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP_DIR)])

    # 9. Functional smoke tests of ALL bundled helpers inside CameraWall.app
    print("[smoke] Verifying bundled go2rtc...")
    g_out = run([str(go2rtc_dst), "-version"], capture=True).stdout.strip()
    print(f"  go2rtc: {g_out}")

    print("[smoke] Verifying bundled espeak-ng (offline WAV synthesis with bundled espeak-ng-data)...")
    e_res = run(
        [str(espeak_dst), f"--path={RESOURCES_DIR}", "-v", "en", "--stdin", "--stdout"],
        capture=True,
        input_bytes=b"ACTA self contained bundle ready.",
    )
    assert len(e_res.stdout) > 1000 and e_res.stdout[:4] == b"RIFF", f"Unexpected WAV output: {len(e_res.stdout)} bytes"
    print(f"  espeak-ng: OK ({len(e_res.stdout)} WAV bytes synthesized offline)")

    print("[smoke] Verifying bundled vllm-metal...")
    v_out = run([str(HELPERS_DIR / "vllm"), "--version"], capture=True).stdout.strip()
    print(f"  vllm: {v_out.splitlines()[-1]}")

    size_out = run(["du", "-sh", str(APP_DIR)], capture=True).stdout.strip()
    print(f"[done] Complete self-contained bundle ready: {size_out}")


if __name__ == "__main__":
    main()
