#!/usr/bin/env bash
# Build a ROCKNIX-loadable Turnip (Mesa freedreno Vulkan ICD) for the a6xx handhelds.
#
# Produces a self-contained package that is loaded per-process through the Vulkan
# loader's ICD override. Nothing on the device image is touched.
#
# Read README.md in this directory before using this. In particular: every build gets
# a --build-tag, the tag is baked into the driver's Vulkan driverInfo string, and that
# string is how a run proves which driver it actually loaded.
#
# Run this script in place — it resolves its own directory for templates and the
# device baselines.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- defaults ----

MESA_CLONE="/run/media/bmd/dev/ARMSX2-umbrella/references/mesa"
WORK_DIR="/run/media/bmd/dev/claude-scratch/turnip-rocknix"
REF="mesa-26.1.2"
BUILD_TAG=""
PROFILE="release"          # release | symbols
PLATFORMS=""               # meson -Dplatforms= value; empty is right for headless + KHR_display
INSTALL_ROOT="/storage/turnip"
FALLBACK_LIBS="yes"
BASELINE="${SELF_DIR}/device-baseline/sd865.json"
JOBS=""
PATCHES=()

usage() {
    cat <<'EOF'
build-turnip.sh — build a ROCKNIX-loadable Turnip ICD

  --build-tag TAG     REQUIRED. <=10 chars of [A-Za-z0-9._-]. Baked into the driver's
                      Vulkan driverInfo as "(git-TAG)" and used as the package name.
                      Allocate it in README.md's build register before you use it.
  --ref REF           Mesa git ref to build (default: mesa-26.1.2).
  --profile P         release (default) or symbols (debugoptimized + frame pointers).
  --patch FILE        Apply FILE (-p1) to the exported source. Repeatable, applied in
                      the order given. Recorded in MANIFEST.json by sha256.
  --platforms LIST    meson -Dplatforms value (default: empty). See README "WSI".
  --install-root DIR  Device directory the package will live under
                      (default: /storage/turnip). The ICD json's library_path is
                      written as <install-root>/<build-tag>/libvulkan_freedreno.so.
  --baseline FILE     Device baseline json for the ABI gate
                      (default: device-baseline/sd865.json).
  --no-fallback-libs  Do not stage lib-fallback/ into the package.
  --work DIR          Scratch root for sources and build trees
                      (default: /run/media/bmd/dev/claude-scratch/turnip-rocknix).
  --mesa-clone DIR    Mesa git clone to export from (read-only; default:
                      references/mesa in the umbrella).
  --jobs N            ninja -j N.
  -h, --help          This.

The package lands in <work>/out/turnip-<build-tag>/ with a tarball beside it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-tag)        BUILD_TAG="$2"; shift 2 ;;
        --ref)              REF="$2"; shift 2 ;;
        --profile)          PROFILE="$2"; shift 2 ;;
        --patch)            PATCHES+=("$2"); shift 2 ;;
        --platforms)        PLATFORMS="$2"; shift 2 ;;
        --install-root)     INSTALL_ROOT="$2"; shift 2 ;;
        --baseline)         BASELINE="$2"; shift 2 ;;
        --no-fallback-libs) FALLBACK_LIBS="no"; shift ;;
        --work)             WORK_DIR="$2"; shift 2 ;;
        --mesa-clone)       MESA_CLONE="$2"; shift 2 ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "build-turnip.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------- validation ----

die() { echo "build-turnip.sh: $*" >&2; exit 1; }

[[ -n "$BUILD_TAG" ]] || die "--build-tag is required (see README.md's build register)"

# git_sha1_gen.py truncates MESA_GIT_SHA1_OVERRIDE to 10 characters WITHOUT
# complaining, so an 11-character tag would bake a token that no verification grep
# would ever match. Refuse it here; the post-build check re-proves the exact string.
[[ ${#BUILD_TAG} -le 10 ]] || die "--build-tag '$BUILD_TAG' is ${#BUILD_TAG} chars; Mesa truncates to 10"
[[ "$BUILD_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "--build-tag may only contain [A-Za-z0-9._-]"
[[ "$PROFILE" == "release" || "$PROFILE" == "symbols" ]] || die "--profile must be release or symbols"
[[ -d "$MESA_CLONE/.git" || -f "$MESA_CLONE/.git" ]] || die "no git clone at $MESA_CLONE"
[[ -f "$BASELINE" ]] || die "no device baseline at $BASELINE"

for p in "${PATCHES[@]:-}"; do
    [[ -z "$p" ]] && continue
    [[ -f "$p" ]] || die "patch not found: $p"
done

for t in meson ninja readelf objdump python3 tar; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
done

# The clone is a SHARED reference checkout. Everything below reads from it through
# `git archive`, which touches neither its branch nor its working tree.
REF_SHA="$(git -C "$MESA_CLONE" rev-parse "${REF}^{commit}" 2>/dev/null)" \
    || die "ref '$REF' does not resolve in $MESA_CLONE"

SRC_DIR="$WORK_DIR/src/$BUILD_TAG"
BLD_DIR="$WORK_DIR/build/$BUILD_TAG"
OUT_DIR="$WORK_DIR/out"
PKG_DIR="$OUT_DIR/turnip-$BUILD_TAG"
LOG_DIR="$WORK_DIR/logs"
INSTALL_DIR="$INSTALL_ROOT/$BUILD_TAG"

mkdir -p "$SRC_DIR" "$OUT_DIR" "$LOG_DIR"

echo "=== turnip build '$BUILD_TAG' ==="
echo "  mesa ref       : $REF ($REF_SHA)"
echo "  profile        : $PROFILE"
echo "  patches        : ${#PATCHES[@]}"
echo "  platforms      : '${PLATFORMS}'"
echo "  device install : $INSTALL_DIR"
echo "  work           : $WORK_DIR"

# --------------------------------------------------------- export sources ----

echo "--- exporting $REF"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
git -C "$MESA_CLONE" archive --format=tar "$REF_SHA" \
    | tar -x -C "$SRC_DIR"
[[ -f "$SRC_DIR/VERSION" ]] || die "export produced no VERSION file"
MESA_VERSION="$(tr -d '[:space:]' < "$SRC_DIR/VERSION")"
echo "    mesa version: $MESA_VERSION"

# expat and libarchive have no .pc file on Fedora, so meson falls back to its own
# subprojects. Seeding the clone's packagecache makes the configure offline.
if [[ -d "$MESA_CLONE/subprojects/packagecache" ]]; then
    cp -a "$MESA_CLONE/subprojects/packagecache" "$SRC_DIR/subprojects/"
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
        entries="$entries{\"file\":\"$abs\",\"sha256\":\"$sum\"},"
    done
    PATCH_MANIFEST="[${entries%,}]"
fi

# ------------------------------------------------------------- configure -----

# Common options. The intent is a Turnip-only Mesa: no GL stack, no gallium, no LLVM.
# Those all affect other .so files, not this one, but leaving them on costs build time
# and drags in host dependencies that have nothing to do with the ICD.
MESON_OPTS=(
    "-Dvulkan-drivers=freedreno"
    "-Dgallium-drivers="
    "-Dplatforms=${PLATFORMS}"
    "-Dglx=disabled" "-Degl=disabled" "-Dgbm=disabled"
    "-Dopengl=false" "-Dgles1=disabled" "-Dgles2=disabled"
    "-Dllvm=disabled" "-Dvideo-codecs=" "-Dvulkan-layers=" "-Dtools="
    "-Dshader-cache=enabled"     # ROCKNIX ships this enabled; matching it matters
    "-Dglvnd=disabled"
    "-Dbuild-tests=false"
    "-Dvalgrind=disabled" "-Dlibunwind=disabled" "-Dlmsensors=disabled"
    "-Dstrip=false"              # keep .symtab; costs size, buys perf symbol names
    "-Dsplit-debug=disabled"     # keep any DWARF inside the .so, never in .dwo files
)

# -march=armv8-a + -moutline-atomics is the MQ65 (Adreno 610, Cortex-A73, ARMv8.0, no
# LSE HWCAP) safety belt: outline atomics runtime-check __aarch64_have_lse_atomics and
# fall back to ldxr/stxr. Inline LSE would SIGILL there. check-turnip.py proves it.
ARCH_FLAGS="-march=armv8-a -moutline-atomics"

# Mesa 26.1.x does not compile warning-clean under Fedora's GCC 15.
COMMON_FLAGS="-Wno-error $ARCH_FLAGS"

case "$PROFILE" in
    release)
        MESON_OPTS+=( "--buildtype=release" "-Db_ndebug=true" )
        CFLAGS_EXTRA=""
        ;;
    symbols)
        # -O2 -g with frame pointers, so `perf --call-graph fp` can walk the driver.
        # A -O0 driver would move the numbers we are trying to measure.
        MESON_OPTS+=( "--buildtype=debugoptimized" "-Db_ndebug=true" )
        CFLAGS_EXTRA=" -fno-omit-frame-pointer"
        ;;
esac

# Wayland WSI on a ROCKNIX target: the image ships libwayland-client 1.23.1, and Mesa's
# configure probes the BUILD host's library, which on Fedora 42 is 1.24 and has
# wl_display_dispatch_queue_timeout. A driver that references it fails to dlopen on the
# device, the loader silently drops the ICD, and the frontend reports "Missing required
# extension VK_KHR_surface" (seen 2026-09-22, axfl1-008 first build). Both probed entry
# points have in-tree fallbacks, so undefine the HAVE_ macros; check-turnip's undefined
# wl_* symbol check below proves the result.
# The third 1.24-ism, wl_fixes, is gated by the host's protocol header rather than
# by meson, so -U cannot reach it; patches/0004-wsi-wayland-build-without-wl-fixes.patch
# adds the WSI_WL_NO_FIXES switch and the build must carry that patch (pass it with
# --patch) for a wayland pack aimed at a 1.23 device.
if [[ ",$PLATFORMS," == *,wayland,* ]]; then
    CFLAGS_EXTRA+=" -UHAVE_WL_DISPATCH_QUEUE_TIMEOUT -UHAVE_WL_CREATE_QUEUE_WITH_NAME -DWSI_WL_NO_FIXES"
fi

MESON_OPTS+=(
    "-Dc_args=${COMMON_FLAGS}${CFLAGS_EXTRA}"
    "-Dcpp_args=${COMMON_FLAGS}${CFLAGS_EXTRA}"
)

# THE VERIFICATION HOOK. bin/git_sha1_gen.py reads this env var, truncates it to 10
# chars and emits `#define MESA_GIT_SHA1 " (git-<tag>)"`. tu_device.cc pastes that onto
# PACKAGE_VERSION to make VkPhysicalDeviceDriverProperties::driverInfo, which the
# runner prints in its banner and writes into stats.json. A stock ROCKNIX driver is
# built from a release tarball and has no git sha at all, so the parenthetical is
# present if and only if this build loaded.
export MESA_GIT_SHA1_OVERRIDE="$BUILD_TAG"

# Mesa generates a lot of its tables from Python, and several of those generators
# iterate sets/dicts. Pinning the hash seed removes the resulting run-to-run ordering
# churn; SOURCE_DATE_EPOCH removes any embedded timestamp. Neither changes behaviour.
# Whether they are jointly sufficient for a bit-identical rebuild is recorded in
# README.md -- do not assume it, compare the sha256.
export PYTHONHASHSEED=0
export SOURCE_DATE_EPOCH=1136073600

# Never pipe a build whose status you need, and never let `set -e` swallow the exit
# code before it has been printed: both halves of the || are what keeps the code.
echo "--- meson setup"
rm -rf "$BLD_DIR"
rc=0
meson setup "$BLD_DIR" "$SRC_DIR" "${MESON_OPTS[@]}" \
    > "$LOG_DIR/setup-$BUILD_TAG.log" 2>&1 || rc=$?
echo "    meson exit=$rc  (log: $LOG_DIR/setup-$BUILD_TAG.log)"
[[ $rc -eq 0 ]] || die "meson setup failed; see $LOG_DIR/setup-$BUILD_TAG.log"

echo "--- ninja"
NINJA_ARGS=( -C "$BLD_DIR" )
[[ -n "$JOBS" ]] && NINJA_ARGS+=( -j "$JOBS" )
rc=0
ninja "${NINJA_ARGS[@]}" > "$LOG_DIR/build-$BUILD_TAG.log" 2>&1 || rc=$?
echo "    ninja exit=$rc  (log: $LOG_DIR/build-$BUILD_TAG.log)"
[[ $rc -eq 0 ]] || die "ninja failed; see $LOG_DIR/build-$BUILD_TAG.log"

BUILT_SO="$BLD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"
[[ -f "$BUILT_SO" ]] || die "no driver at $BUILT_SO"

# ---------------------------------------------------------------- package ----

echo "--- packaging into $PKG_DIR"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"
cp "$BUILT_SO" "$PKG_DIR/libvulkan_freedreno.so"
chmod 0755 "$PKG_DIR/libvulkan_freedreno.so"

# Ship the launcher inside the package so the device has it without a second copy
# step, and so the launcher on the device can never be a different vintage from the
# driver it launches.
cp "$SELF_DIR/run-with-turnip.sh" "$PKG_DIR/run-with-turnip.sh"
chmod 0755 "$PKG_DIR/run-with-turnip.sh"

# Take api_version from Mesa's own generated manifest so it can never drift from the
# driver; rewrite only library_path, which must be the absolute device path.
# No `| head -1` anywhere below: `set -o pipefail` turns the SIGPIPE that head sends
# to find into a 141 exit and kills the script mid-package.
mapfile -t _gen_icds < <(find "$BLD_DIR/src/freedreno/vulkan" -maxdepth 1 -name 'freedreno_icd*.json' -print)
GEN_ICD="${_gen_icds[0]:-}"
[[ -n "$GEN_ICD" ]] || die "meson generated no freedreno_icd json"
API_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ICD"]["api_version"])' "$GEN_ICD")"
python3 - "$PKG_DIR/freedreno_icd.aarch64.json" "$API_VERSION" "$INSTALL_DIR" <<'PY'
import json, sys
out, api, install_dir = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {
    "ICD": {
        "api_version": api,
        "library_arch": "64",
        "library_path": f"{install_dir}/libvulkan_freedreno.so",
    },
    "file_format_version": "1.0.1",
}
with open(out, "w") as f:
    json.dump(doc, f, indent=4)
    f.write("\n")
PY

if [[ "$FALLBACK_LIBS" == "yes" ]]; then
    # Staged ONLY for the case where the device is missing one of the driver's NEEDED
    # libraries. The device runs its own Turnip with the same NEEDED set, so expect to
    # need none of these. libstdc++/libgcc_s/libm/libc are deliberately absent: forcing
    # host copies of those into the runner's process is a real risk for no benefit.
    mkdir -p "$PKG_DIR/lib-fallback"
    # -not -name '*.symbols' matters: meson leaves libexpat.so.1.8.10.symbols beside
    # the real library inside the .p directory, and it matches the obvious glob.
    mapfile -t _expat < <(find "$BLD_DIR/subprojects" -type f \
        -name 'libexpat.so.1.*' -not -name '*.symbols' -not -path '*.p/*' -print)
    [[ -n "${_expat[0]:-}" ]] && cp "${_expat[0]}" "$PKG_DIR/lib-fallback/libexpat.so.1" || true
    for l in libz.so.1 libzstd.so.1 libdrm.so.2 libudev.so.1 libcap.so.2; do
        # ldconfig prints the arch tag as 'AArch64'; a case-sensitive /aarch64/ match
        # here silently staged nothing at all.
        src="$(/sbin/ldconfig -p 2>/dev/null | awk -v n="$l" '$1==n {print $NF; exit}')" || true
        [[ -n "$src" && -f "$src" ]] && cp -L "$src" "$PKG_DIR/lib-fallback/$l" || true
    done
    # A fallback directory that quietly came out empty is worse than no directory: it
    # looks like a staged safety net and is not one.
    if [[ -z "$(ls -A "$PKG_DIR/lib-fallback")" ]]; then
        die "lib-fallback/ came out empty - the host library lookup found nothing"
    fi
    chmod 0755 "$PKG_DIR"/lib-fallback/* 2>/dev/null || true
fi

# ------------------------------------------------------------- provenance ----

BUILD_ID="$(readelf -n "$PKG_DIR/libvulkan_freedreno.so" 2>/dev/null \
            | awk '/Build ID:/{print $3; exit}')" || true
SO_SHA="$(sha256sum "$PKG_DIR/libvulkan_freedreno.so" | cut -d' ' -f1)"

python3 - "$PKG_DIR/MANIFEST.json" <<PY
import json, subprocess, datetime, platform, os
def run(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True).stdout.strip().splitlines()[0]
    except Exception:
        return ""
doc = {
  "build_tag": "$BUILD_TAG",
  "driver_info_token": "(git-$BUILD_TAG)",
  "mesa_version": "$MESA_VERSION",
  "mesa_ref": "$REF",
  "mesa_commit": "$REF_SHA",
  "profile": "$PROFILE",
  "platforms": "$PLATFORMS",
  "patches": $PATCH_MANIFEST,
  "meson_options": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${MESON_OPTS[@]}"),
  "install_dir": "$INSTALL_DIR",
  "icd_api_version": "$API_VERSION",
  "build_id": "$BUILD_ID",
  "sha256": "$SO_SHA",
  "built_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
  "host": {
    "uname": run("uname", "-srm"),
    "os": run("sh", "-c", ". /etc/os-release 2>/dev/null; echo \$PRETTY_NAME"),
    "cc": run("cc", "--version"),
    "cxx": run("c++", "--version"),
    "meson": run("meson", "--version"),
    "ninja": run("ninja", "--version"),
    "glibc": run("sh", "-c", "ldd --version | head -1"),
  },
}
with open("$PKG_DIR/MANIFEST.json", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

( cd "$PKG_DIR" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort \
    | xargs -r sha256sum > SHA256SUMS )

# ------------------------------------------------------------------ check ----

echo "--- ABI / loadability gate"
rc=0
python3 "$SELF_DIR/check-turnip.py" --package "$PKG_DIR" --baseline "$BASELINE" || rc=$?
[[ $rc -eq 0 ]] || die "check-turnip.py failed (exit $rc) - do NOT stage this package"

# ---------------------------------------------------------------- tarball ----

TARBALL="$OUT_DIR/turnip-$BUILD_TAG-aarch64.tar.gz"
STAGE="$WORK_DIR/.tar-stage-$BUILD_TAG"
rm -rf "$STAGE"
mkdir -p "$STAGE/$(basename "$INSTALL_ROOT")"
cp -a "$PKG_DIR" "$STAGE/$(basename "$INSTALL_ROOT")/$BUILD_TAG"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$STAGE" "$(basename "$INSTALL_ROOT")"
rm -rf "$STAGE"
# File name only, so `sha256sum -c` works wherever the two files are downloaded to.
( cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

echo
echo "=== done ==="
echo "  package : $PKG_DIR"
echo "  tarball : $TARBALL"
echo "            unpacks under the PARENT of $INSTALL_ROOT to give $INSTALL_DIR"
echo "  banner  : driverInfo will read 'Mesa $MESA_VERSION (git-$BUILD_TAG)'"
echo
echo "  Stage it with:  $SELF_DIR/stage-turnip.sh --package $PKG_DIR --host <root@ip>"
echo "  Then prove it loaded — see README.md 'Proving the swap took'."
