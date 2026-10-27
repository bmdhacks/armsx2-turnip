#!/usr/bin/env bash
# Run a command with a staged Turnip as its Vulkan driver, for that process only.
#
# Copy this to the device (or source the two exports it sets) and put it in front of
# whatever the round actually runs. It changes nothing outside the process it starts.
#
#   ./run-with-turnip.sh --driver /storage/turnip/armsx2-001 -- \
#       ./pcsx2-gsrunner -renderer vulkan -perf -loop 10 -stats-json out.json dump.gs
#
# --check runs the environment through vulkaninfo instead, if the image has it.

set -euo pipefail

DRIVER=""
WANT_FALLBACK=0
CHECK=0

usage() {
    cat <<'EOF'
run-with-turnip.sh --driver DIR [--fallback-libs] [--check] -- COMMAND [ARGS...]

  --driver DIR      Staged package directory on the device, e.g.
                    /storage/turnip/armsx2-001.
  --fallback-libs   Prepend DIR/lib-fallback to LD_LIBRARY_PATH. Only do this if
                    `ldd` on the driver actually reported something missing, and
                    never on an ARMv8.0 device without reading README.md first.
  --check           Do not run COMMAND; print what the loader resolves instead.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver)        DRIVER="$2"; shift 2 ;;
        --fallback-libs) WANT_FALLBACK=1; shift ;;
        --check)         CHECK=1; shift ;;
        --)              shift; break ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "run-with-turnip.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$DRIVER" ]] || { echo "run-with-turnip.sh: --driver is required" >&2; exit 2; }

ICD="$DRIVER/freedreno_icd.aarch64.json"
[[ -f "$ICD" ]] || { echo "run-with-turnip.sh: no ICD manifest at $ICD" >&2; exit 1; }
[[ -f "$DRIVER/libvulkan_freedreno.so" ]] || {
    echo "run-with-turnip.sh: no driver at $DRIVER/libvulkan_freedreno.so" >&2; exit 1; }

# VK_DRIVER_FILES is the current spelling and VK_ICD_FILENAMES the older one. A loader
# honours whichever it knows and ignores the other, so setting both costs nothing and
# removes a whole class of "it quietly used the system driver". Both are absolute:
# a relative path here resolves against the process's cwd, which the runner changes.
export VK_DRIVER_FILES="$ICD"
export VK_ICD_FILENAMES="$ICD"

# Belt and braces: make sure no implicit layer or an inherited value from a login
# profile adds the image's own ICD back into the search.
unset VK_ADD_DRIVER_FILES 2>/dev/null || true

if [[ $WANT_FALLBACK -eq 1 ]]; then
    # APPEND to whatever is already there. The runner's own launcher sets
    # LD_LIBRARY_PATH=/storage/pcsx2/lib and it loses libjpeg/liblz4 if that is
    # overwritten rather than extended.
    export LD_LIBRARY_PATH="$DRIVER/lib-fallback${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

if [[ $CHECK -eq 1 ]]; then
    echo "VK_DRIVER_FILES=$VK_DRIVER_FILES"
    echo "VK_ICD_FILENAMES=$VK_ICD_FILENAMES"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
    echo
    echo "--- driverInfo string baked into the staged driver:"
    strings -a "$DRIVER/libvulkan_freedreno.so" 2>/dev/null | grep -E "^Mesa [0-9]" || \
        echo "  (strings unavailable on this image; read it from the runner banner instead)"
    echo
    if command -v vulkaninfo >/dev/null; then
        echo "--- vulkaninfo:"
        vulkaninfo 2>/dev/null | grep -E "driverName|driverInfo|driverVersion|deviceName" | head
    else
        echo "(no vulkaninfo on this image - the runner's own banner is the check that matters)"
    fi
    exit 0
fi

[[ $# -gt 0 ]] || { echo "run-with-turnip.sh: nothing to run after --" >&2; exit 2; }
exec "$@"
