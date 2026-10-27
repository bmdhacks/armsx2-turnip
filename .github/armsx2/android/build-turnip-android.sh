#!/usr/bin/env bash
# Build an Android-loadable Turnip (Mesa freedreno Vulkan driver) and package it as a
# driver pack the ARMSX2 Android app installs through libadrenotools.
#
# This runs ON THE BUILD HOST (x86_64 Linux with the Android NDK). The source comes in
# as a tarball made by export-mesa-ref.sh on the workstation, because the Mesa clone
# lives there and is read-only.
#
# Read README.md in this directory first. In particular: every build gets a
# --build-tag, the tag is baked into the driver's Vulkan driverInfo string, and that
# string is the only way a run on the device can prove which driver it loaded.
#
# Run this script in place -- it resolves its own directory for the gate and the
# device baseline.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- defaults ----

WORK_DIR="$HOME/armsx2-e15"
NDK_DIR="$HOME/Android/Sdk/ndk/28.2.13676358"
VENV_DIR=""                 # defaults to $WORK_DIR/venv
API="29"
BUILD_TAG=""
SRC_TAR=""
PROFILE="release"           # release | symbols
JOBS="8"
PATCHES=()
BASELINE="$SELF_DIR/device-baseline/android13-sphal.json"
PACK_NAME=""                # human name in meta.json; defaults to the tag

usage() {
    cat <<'EOF'
build-turnip-android.sh -- build a Turnip driver pack for the ARMSX2 Android app

  --build-tag TAG     REQUIRED. <=10 chars of [A-Za-z0-9._-]. Baked into the driver's
                      Vulkan driverInfo as "(git-TAG)". Allocate it in README.md's
                      build register before you use it.
  --src-tar FILE      REQUIRED. Mesa source tarball from export-mesa-ref.sh. A
                      <file>.provenance.json beside it is read for ref/commit/version.
  --patch FILE        Apply FILE (-p1) to the exported source. Repeatable, applied in
                      the order given. Recorded in MANIFEST.json by sha256.
  --api N             Android API level to compile against (default 29). This is both
                      the NDK toolchain target and meson -Dplatform-sdk-version, and
                      it becomes meta.json's minApi. See README "Which API level".
  --profile P         release (default) or symbols (debugoptimized + frame pointers).
  --name TEXT         meta.json "name" shown in the app's driver list (default: tag).
  --ndk DIR           NDK root (default ~/Android/Sdk/ndk/28.2.13676358).
  --venv DIR          python venv holding meson/mako (default <work>/venv).
  --work DIR          scratch root for sources, build trees and packages
                      (default ~/armsx2-e15).
  --baseline FILE     Android baseline json for the loadability gate.
  --jobs N            ninja -j N (default 8: this host is shared with other lanes).
  -h, --help          This.

The pack lands in <work>/out/turnip-<tag>-android/ with a .zip beside it. The .zip is
what the app ingests.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-tag)  BUILD_TAG="$2"; shift 2 ;;
        --src-tar)    SRC_TAR="$2"; shift 2 ;;
        --patch)      PATCHES+=("$2"); shift 2 ;;
        --api)        API="$2"; shift 2 ;;
        --profile)    PROFILE="$2"; shift 2 ;;
        --name)       PACK_NAME="$2"; shift 2 ;;
        --ndk)        NDK_DIR="$2"; shift 2 ;;
        --venv)       VENV_DIR="$2"; shift 2 ;;
        --work)       WORK_DIR="$2"; shift 2 ;;
        --baseline)   BASELINE="$2"; shift 2 ;;
        --jobs)       JOBS="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "build-turnip-android.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------- validation ----

die() { echo "build-turnip-android.sh: $*" >&2; exit 1; }

[[ -n "$BUILD_TAG" ]] || die "--build-tag is required (see README.md's build register)"

# bin/git_sha1_gen.py truncates MESA_GIT_SHA1_OVERRIDE to 10 characters WITHOUT
# complaining, so an 11-character tag would bake a token no verification grep would
# ever match. Refuse it here; the gate re-proves the exact string afterwards.
[[ ${#BUILD_TAG} -le 10 ]] || die "--build-tag '$BUILD_TAG' is ${#BUILD_TAG} chars; Mesa truncates to 10"
[[ "$BUILD_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "--build-tag may only contain [A-Za-z0-9._-]"
[[ -n "$SRC_TAR" && -f "$SRC_TAR" ]] || die "--src-tar FILE is required and must exist"
[[ "$PROFILE" == "release" || "$PROFILE" == "symbols" ]] || die "--profile must be release or symbols"
[[ -d "$NDK_DIR" ]] || die "no NDK at $NDK_DIR"
[[ -f "$BASELINE" ]] || die "no device baseline at $BASELINE"
[[ "$API" =~ ^[0-9]+$ ]] || die "--api must be a number"

VENV_DIR="${VENV_DIR:-$WORK_DIR/venv}"
MESON="$VENV_DIR/bin/meson"
PYTHON="$VENV_DIR/bin/python"
[[ -x "$MESON" ]] || die "no meson at $MESON -- see README 'Build host setup'"

# The venv has to be ON PATH, not just invoked by absolute path. Mesa resolves its own
# python with import('python').find_installation(), which searches PATH -- running
# meson out of the venv is not enough, it would pick /usr/bin/python3.12 and stop at
# "mako module >= 0.8.0 required".
PATH="$VENV_DIR/bin:$PATH"
export PATH

NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC_BIN="$NDK_BIN/aarch64-linux-android$API-clang"
[[ -x "$CC_BIN" ]] || die "no NDK compiler for API $API at $CC_BIN"

# glslangValidator is a hard requirement for any Vulkan driver with BVH shaders, and
# turnip is one (meson.build:702 with_bvh). Ubuntu's package is not installed on this
# host and we have no root, so setup-host-tools.sh unpacks the .deb into the work
# directory; put that on PATH ahead of everything else.
HOSTTOOLS_BIN="$WORK_DIR/hosttools/root/usr/bin"
[[ -d "$HOSTTOOLS_BIN" ]] && PATH="$HOSTTOOLS_BIN:$PATH" && export PATH

for t in ninja zstd tar zip readelf objdump python3 glslangValidator; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
done

for p in "${PATCHES[@]:-}"; do
    [[ -z "$p" ]] && continue
    [[ -f "$p" ]] || die "patch not found: $p"
done

SRC_DIR="$WORK_DIR/src/$BUILD_TAG"
BLD_DIR="$WORK_DIR/build/$BUILD_TAG"
OUT_DIR="$WORK_DIR/out"
PKG_DIR="$OUT_DIR/turnip-$BUILD_TAG-android"
LOG_DIR="$WORK_DIR/logs"
CROSS_FILE="$WORK_DIR/cross/android-aarch64-api$API.ini"

mkdir -p "$OUT_DIR" "$LOG_DIR" "$WORK_DIR/cross"

# Provenance of the source, written by export-mesa-ref.sh. Without it the manifest
# would say "some tarball", which is not a reproducible record.
PROV="${SRC_TAR%.tar.zst}.provenance.json"
[[ "$SRC_TAR" == *.tar.zst ]] || PROV="${SRC_TAR%.tar}.provenance.json"
MESA_REF="unknown"; MESA_COMMIT="unknown"
if [[ -f "$PROV" ]]; then
    MESA_REF="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mesa_ref"])' "$PROV")"
    MESA_COMMIT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mesa_commit"])' "$PROV")"
fi

echo "=== turnip android build '$BUILD_TAG' ==="
echo "  source tar     : $SRC_TAR"
echo "  mesa ref       : $MESA_REF ($MESA_COMMIT)"
echo "  profile        : $PROFILE"
echo "  patches        : ${#PATCHES[@]}"
echo "  ndk / api      : $NDK_DIR / android$API"
echo "  work           : $WORK_DIR"

# ---------------------------------------------------------- unpack source ----

echo "--- unpacking source"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
case "$SRC_TAR" in
    *.zst) zstd -dc "$SRC_TAR" | tar -x -C "$SRC_DIR" --strip-components=1 ;;
    *)     tar -xf "$SRC_TAR" -C "$SRC_DIR" --strip-components=1 ;;
esac
[[ -f "$SRC_DIR/VERSION" ]] || die "export produced no VERSION file"
MESA_VERSION="$(tr -d '[:space:]' < "$SRC_DIR/VERSION")"
echo "    mesa version: $MESA_VERSION"

# expat has no aarch64-android .pc anywhere, so meson falls back to its own subproject.
# Seeding the packagecache from the clone keeps the configure offline.
PC_TAR="$(dirname "$SRC_TAR")/packagecache.tar"
if [[ -f "$PC_TAR" ]]; then
    mkdir -p "$SRC_DIR/subprojects"
    tar -xf "$PC_TAR" -C "$SRC_DIR/subprojects"
fi

PATCH_MANIFEST="[]"
if [[ ${#PATCHES[@]} -gt 0 ]]; then
    echo "--- applying ${#PATCHES[@]} patch(es)"
    entries=""
    for p in "${PATCHES[@]}"; do
        [[ -z "$p" ]] && continue
        abs="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
        echo "    $abs"
        ( cd "$SRC_DIR" && patch -p1 --forward --batch --silent < "$abs" ) \
            || die "patch failed to apply cleanly: $abs"
        sum="$(sha256sum "$abs" | cut -d' ' -f1)"
        entries="$entries{\"file\":\"$(basename "$abs")\",\"sha256\":\"$sum\"},"
    done
    PATCH_MANIFEST="[${entries%,}]"
fi

# ------------------------------------------------------------- cross file ----

# Written fresh every build so the recipe cannot drift from a stale file someone
# edited by hand. -static-libstdc++ is upstream's own docs/android.rst line: the NDK's
# libc++_shared.so is not on the device and the linker namespace adrenotools builds
# for the driver cannot see the app's copy, so the C++ runtime has to be inside the
# driver .so.
cat > "$CROSS_FILE" <<EOF
[constants]
ndk_bin = '$NDK_BIN'

[binaries]
c = ndk_bin / 'aarch64-linux-android$API-clang'
cpp = [ndk_bin / 'aarch64-linux-android$API-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
ar = ndk_bin / 'llvm-ar'
strip = ndk_bin / 'llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = '/bin/false'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

# ------------------------------------------------------------- configure -----

# Every option here is argued in README.md "The option set". Short version:
#   platforms=android      pulls in VK_KHR_android_surface WSI and, through
#                          vk_android.c, the HAL_MODULE_INFO_SYM ("HMI") entry point
#                          that Android's libvulkan dlsym()s. Without it the pack
#                          loads and then does nothing.
#   android-stub=true      NDK has no libcutils/liblog/libnativewindow/libsync/
#                          libhardware. Build against stubs, resolve the real ones on
#                          the device out of the sphal linker namespace.
#   android-strict=false   MANDATORY for us. With it on, Mesa hides every KHR
#                          extension newer than the Android CTS list for
#                          platform-sdk-version -- dynamic_rendering needs 33,
#                          synchronization2 31, dynamic_rendering_local_read 35 --
#                          and vk_device.c REFUSES to enable them. The emulator would
#                          lose the very features this campaign is about.
#   freedreno-kmds=kgsl    Android runs the Qualcomm KGSL kernel driver, not msm/DRM.
MESON_OPTS=(
    "--cross-file=$CROSS_FILE"
    "-Dplatforms=android"
    "-Dplatform-sdk-version=$API"
    "-Dandroid-stub=true"
    "-Dandroid-strict=false"
    "-Dandroid-libbacktrace=disabled"
    "-Dvulkan-drivers=freedreno"
    "-Dfreedreno-kmds=kgsl"
    "-Dgallium-drivers="
    "-Dglx=disabled" "-Degl=disabled" "-Dgbm=disabled"
    "-Dopengl=false" "-Dgles1=disabled" "-Dgles2=disabled"
    "-Dllvm=disabled" "-Dvideo-codecs=" "-Dvulkan-layers=" "-Dtools="
    "-Dshader-cache=enabled"
    "-Dglvnd=disabled"
    "-Dbuild-tests=false"
    "-Dvalgrind=disabled" "-Dlibunwind=disabled" "-Dlmsensors=disabled"
    "-Dperfetto=false"
    "-Dstrip=false"
    "-Dsplit-debug=disabled"
)

# -march=armv8-a -moutline-atomics for the same reason the ROCKNIX build carries it:
# one pack should run on an ARMv8.0 Adreno 610 part (Cortex-A53/A73, no LSE HWCAP) as
# well as on the a7xx phones. Outline atomics runtime-check __aarch64_have_lse_atomics
# instead of inlining `casal`, which is a SIGILL there. check-turnip-android.py counts
# any LSE instruction that escaped the helpers.
ARCH_FLAGS="-march=armv8-a -moutline-atomics"
COMMON_FLAGS="-Wno-error $ARCH_FLAGS"

case "$PROFILE" in
    release)
        MESON_OPTS+=( "--buildtype=release" "-Db_ndebug=true" )
        CFLAGS_EXTRA=""
        ;;
    symbols)
        MESON_OPTS+=( "--buildtype=debugoptimized" "-Db_ndebug=true" )
        CFLAGS_EXTRA=" -fno-omit-frame-pointer"
        ;;
esac

MESON_OPTS+=(
    "-Dc_args=${COMMON_FLAGS}${CFLAGS_EXTRA}"
    "-Dcpp_args=${COMMON_FLAGS}${CFLAGS_EXTRA}"
)

# THE VERIFICATION HOOK. bin/git_sha1_gen.py reads this env var, truncates it to 10
# chars and emits `#define MESA_GIT_SHA1 " (git-<tag>)"`. tu_device.cc pastes that onto
# PACKAGE_VERSION to make VkPhysicalDeviceDriverProperties::driverInfo, which ARMSX2
# prints in its GS banner. A community pack carries its own sha there, a stock
# Qualcomm blob carries none, so the token identifies our build uniquely.
export MESA_GIT_SHA1_OVERRIDE="$BUILD_TAG"

# Mesa generates a lot of its tables from Python and several generators iterate
# sets/dicts. Pinning the hash seed removes the run-to-run ordering churn;
# SOURCE_DATE_EPOCH removes embedded timestamps. Neither changes behaviour. Whether
# they are jointly sufficient for a byte-identical rebuild is a claim to measure, not
# to assume -- compare the sha256.
export PYTHONHASHSEED=0
export SOURCE_DATE_EPOCH=1136073600

echo "--- meson setup"
rm -rf "$BLD_DIR"
rc=0
"$MESON" setup "$BLD_DIR" "$SRC_DIR" "${MESON_OPTS[@]}" \
    > "$LOG_DIR/setup-$BUILD_TAG.log" 2>&1 || rc=$?
echo "    meson exit=$rc  (log: $LOG_DIR/setup-$BUILD_TAG.log)"
[[ $rc -eq 0 ]] || die "meson setup failed; see $LOG_DIR/setup-$BUILD_TAG.log"

echo "--- ninja -j$JOBS"
rc=0
ninja -C "$BLD_DIR" -j "$JOBS" > "$LOG_DIR/build-$BUILD_TAG.log" 2>&1 || rc=$?
echo "    ninja exit=$rc  (log: $LOG_DIR/build-$BUILD_TAG.log)"
[[ $rc -eq 0 ]] || die "ninja failed; see $LOG_DIR/build-$BUILD_TAG.log"

# Take the driver out of a staged install, not out of the build tree. The build-tree
# copy carries RUNPATH $ORIGIN/../../android_stub, left over from linking against the
# stub libcutils/liblog/... . On the device that directory does not exist, so it is
# inert rather than dangerous -- but a pack must not ship a search path from the
# machine that built it, and `meson install` is what strips it. Nothing is installed
# on the build host: --destdir puts the whole tree under the work directory.
echo "--- meson install (strips the build-tree RUNPATH)"
STAGE_DIR="$WORK_DIR/stage/$BUILD_TAG"
rm -rf "$STAGE_DIR"
rc=0
"$MESON" install -C "$BLD_DIR" --destdir "$STAGE_DIR" --quiet \
    > "$LOG_DIR/install-$BUILD_TAG.log" 2>&1 || rc=$?
echo "    meson install exit=$rc  (log: $LOG_DIR/install-$BUILD_TAG.log)"
[[ $rc -eq 0 ]] || die "meson install failed; see $LOG_DIR/install-$BUILD_TAG.log"

BUILT_SO="$STAGE_DIR/usr/local/lib/libvulkan_freedreno.so"
[[ -f "$BUILT_SO" ]] || die "no driver at $BUILT_SO"

# ---------------------------------------------------------------- package ----

# The pack layout is dictated by CustomDriver.kt: meta.json plus a library whose name
# meta.json's libraryName gives, both at the ZIP ROOT. The installer flattens nested
# paths, so a zip with a leading directory still works, but a flat zip is what every
# community pack ships and what the importer's error string tells the user to bring.
echo "--- packaging into $PKG_DIR"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cp "$BUILT_SO" "$PKG_DIR/libvulkan_freedreno.so"
chmod 0644 "$PKG_DIR/libvulkan_freedreno.so"

BUILD_ID="$(readelf -n "$PKG_DIR/libvulkan_freedreno.so" 2>/dev/null \
            | awk '/Build ID:/{print $3; exit}')" || true
SO_SHA="$(sha256sum "$PKG_DIR/libvulkan_freedreno.so" | cut -d' ' -f1)"

# meta.json. CustomDriver.kt reads name/description/author/vendor/driverVersion/
# packageVersion/libraryName with optString and has no required field; schemaVersion
# and minApi are written by its own synthesiser and never read back. We fill all of
# them anyway -- the same file has to be legible to a human six weeks later and to
# any other adrenotools host that DOES check.
"$PYTHON" - "$PKG_DIR/meta.json" <<PY
import json
doc = {
    "schemaVersion": 1,
    "name": "${PACK_NAME:-ARMSX2 Turnip $BUILD_TAG}",
    "description": "Mesa $MESA_VERSION Turnip, ARMSX2 build $BUILD_TAG (driverInfo carries '(git-$BUILD_TAG)')",
    "author": "ARMSX2",
    "packageVersion": "$BUILD_TAG",
    "vendor": "Mesa",
    "driverVersion": "$MESA_VERSION",
    "minApi": $API,
    "libraryName": "libvulkan_freedreno.so",
}
with open("$PKG_DIR/meta.json", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

"$PYTHON" - "$PKG_DIR/MANIFEST.json" <<PY
import json, subprocess, datetime
def run(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True).stdout.strip().splitlines()[0]
    except Exception:
        return ""
doc = {
  "build_tag": "$BUILD_TAG",
  "driver_info_token": "(git-$BUILD_TAG)",
  "mesa_version": "$MESA_VERSION",
  "mesa_ref": "$MESA_REF",
  "mesa_commit": "$MESA_COMMIT",
  "profile": "$PROFILE",
  "target": "android-aarch64",
  "android_api": $API,
  "ndk": "$NDK_DIR",
  "patches": $PATCH_MANIFEST,
  "meson_options": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${MESON_OPTS[@]}"),
  "library_name": "libvulkan_freedreno.so",
  "build_id": "$BUILD_ID",
  "sha256": "$SO_SHA",
  "built_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
  "host": {
    "uname": run("uname", "-srm"),
    "os": run("sh", "-c", ". /etc/os-release 2>/dev/null; echo \$PRETTY_NAME"),
    "cc": run("$CC_BIN", "--version"),
    "meson": run("$MESON", "--version"),
    "ninja": run("ninja", "--version"),
    "glslang": run("sh", "-c", "glslangValidator --version | head -1"),
  },
}
with open("$PKG_DIR/MANIFEST.json", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

( cd "$PKG_DIR" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort \
    | xargs -r sha256sum > SHA256SUMS )

# The zip the app ingests. SHA256SUMS stays out of it: it covers the package
# directory, and the installer would drop it next to the driver where it means
# nothing. MANIFEST.json goes in, so an installed pack on a device can still be
# traced back to a source tree.
ZIP="$OUT_DIR/turnip-$BUILD_TAG-android.zip"
rm -f "$ZIP"
( cd "$PKG_DIR" && zip -q -X "$ZIP" meta.json libvulkan_freedreno.so MANIFEST.json )
# File name only, so `sha256sum -c` works wherever the two files are downloaded to.
( cd "$OUT_DIR" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

# ------------------------------------------------------------------ check ----

echo "--- loadability gate"
rc=0
"$PYTHON" "$SELF_DIR/check-turnip-android.py" \
    --package "$PKG_DIR" --zip "$ZIP" --baseline "$BASELINE" || rc=$?
[[ $rc -eq 0 ]] || die "check-turnip-android.py failed (exit $rc) - do NOT ship this pack"

echo
echo "=== done ==="
echo "  package : $PKG_DIR"
echo "  zip     : $ZIP"
echo "  banner  : driverInfo will read 'Mesa $MESA_VERSION (git-$BUILD_TAG)'"
