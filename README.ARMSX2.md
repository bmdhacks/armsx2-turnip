# ARMSX2 Turnip

This is Mesa, with the changes [ARMSX2](https://github.com/ARMSX2/ARMSX2) — an
ARM64 PlayStation 2 emulator — makes to **Turnip**, the open Vulkan driver for
Qualcomm Adreno GPUs (`src/freedreno/vulkan/`). Outside Turnip there are four
small changes, each described below: a build switch in the Wayland
window-system code, a faster dynamic-state copy in the shared Vulkan runtime
(`src/vulkan/runtime/`), the Adreno 722 entry in the freedreno device table
(`src/freedreno/common/`), and a gralloc fix for newer Qualcomm buffer handles
(`src/util/u_gralloc/`).

The emulator's GS (graphics) renderer reads the render target it is drawing into,
inside the render pass, on almost every frame of many games. How a driver makes
that read coherent decides how fast those games run. The patches here make it
cheaper on Adreno 6xx without changing the picture. The changes are carried in
our own driver packs and are **not upstreamed**: they trade a coherency guarantee
for speed on the strength of measurements on the devices we own, which is the
kind of change a downstream can make and an upstream should not.

## Branches

| Branch | Base | What |
|---|---|---|
| `armsx2/main` | upstream Mesa `main` of 2026-10-21 (`1fddf34d3cd`, Mesa 27.0.0-devel), rebased from time to time | The release line. Current packs are built from here. |
| `armsx2/26.1.2` | Mesa tag `mesa-26.1.2` | The older line, kept for the records that were measured on it. Mesa before 26.2 hangs on some depth/stencil draws on Adreno 6xx, so ARMSX2 turns its stencil buffer off under it, which costs speed. |

Each branch is the base plus a short series of ARMSX2 commits; `git log
mesa-26.1.2..armsx2/26.1.2` and `git log main..armsx2/main` list exactly what
changed. `main` in this
repository is the unmodified upstream mirror the fork was taken from.

On `armsx2/main` the series sits on a base that moved a lot after the previous
release: the KGSL submit and wait path was reworked (errors that used to be
reported as a plain timeout now surface as device-lost or an error), the
input-attachment lowering in `tu_shader.cc` was rewritten, and upstream dropped
`magic_regs` from the device table. The changes below were re-read against that
code, not only recompiled.

## What the patches do

**Feedback-loop reads on Adreno 6xx (`tu: cheaper coherent in-pass attachment read
on a6xx`).** Stock Turnip makes a declared feedback loop (`VK_EXT_attachment_feedback_loop_layout`)
coherent in sysmem by setting `GRAS_SC_CNTL.single_prim_mode` to
`FLUSH_PER_OVERLAP_AND_OVERWRITE`. On an Adreno 650 that mode is nearly the whole
cost of the read. The patch emits the weaker `FLUSH_PER_OVERLAP` and adds an explicit
per-draw CCU colour clean, UCHE invalidate and wait-for-idle on every draw whose
state declares a feedback loop. 587 captured frames across three rounds were byte-
identical to stock Turnip with application barriers, at 2.0–2.9× the speed on the
scenes where the self-read is what the frame costs. Adreno 7xx and later are
untouched by this commit: they never emitted the prim-mode state.

**Feedback-loop reads on Adreno 7xx (`tu: flush before a declared feedback-loop
draw on a7xx`).** The a7xx half of the change above, and the reason for the
`axfl2` build tag. A draw whose state declares a feedback loop gets the flush a
colour-write-to-fragment-read barrier would have produced (CCU colour clean,
cache invalidate, wait-for-idle), so the application can drop that barrier.
Overlapping primitives inside one draw are still ordered only when the pipeline
asks for rasterization-order attachment access, as in stock a7xx.

**Cheaper pipeline binds (`tu: point at the bound pipeline's program state instead
of copying it`).** Every graphics `vkCmdBindPipeline` copied the pipeline's whole
program state, about 10 KB, into the command buffer, though draws only read a few
hundred bytes of it. The command buffer now points at the pipeline's copy. The GPU
receives exactly the same commands. On an Adreno 650 this cut the emulator's GS
thread time by about 9% in a game that switches pipelines 4,400 times a frame. It
applies to Adreno 6xx and 7xx alike.

**Cheaper dynamic-state copy (`vulkan/runtime: skip the rasterization and stencil
copy …`, `… skip more unchanged groups …`).** Turnip copies a pipeline's dynamic
graphics state into the command buffer on every pipeline bind, comparing every
member of every state. Pipelines an emulator switches between thousands of times
a frame differ in very few of them. The copy now skips a group (rasterization,
stencil, viewport scalars, discard rectangles, fragment shading rate, the
multisample scalars, the input attachment map) when its bytes are already
identical in the destination. The result is the same destination, bit for bit,
including the dirty bits.

**Autotuner default on the Adreno 610 (`tu: default the autotuner to
PREFER_SYSMEM on the Adreno 610`).** On a Snapdragon 662 a PS2 replay took
50.3 ms a frame with the default algorithm and 23.0 ms with
`TU_AUTOTUNE_ALGO=prefer_sysmem`, with identical pixels. Only the 610 changes;
`TU_AUTOTUNE_ALGO` and the drirc option still override it.

**Adreno 722 (Snapdragon 7 Gen 4 / Dragonwing Q-7790, Retroid Pocket Duo).**
Three commits and one follow-up. Upstream's A722 table entry is Qualcomm's
placeholder. Ours copies the A720, because Qualcomm's KGSL source treats the two
as one family (same SP counts, same clusters, same firmware), with two CCUs and
32-row tile alignment. The follow-up writes `RB_RBP_CNTL` and `RB_DBG_ECO_CNTL`
as 0 on the A722: upstream's magic-register cleanup stopped writing them on the
A710 and A720 (apparently unintended), and the A722 pack tested on a Duo wrote
them. The autotuner defaults to `PREFER_SYSMEM` on chip id `0x43020100`, because
community A722 drivers report glitched UI draws in GMEM. And `u_gralloc` reads
the Qualcomm UBWC flag from buffer handles that carry no `gmsm` magic, which is
reported for newer Qualcomm gralloc versions; without it the swapchain image is
laid out differently from the buffer. The commit messages say which numbers come
from other people's reports and not from a device.

**Wayland build switch (`wsi/wayland: let a build opt out of wl_fixes …`).** Lets
the ARM Linux build target an older `libwayland` than the build host has. It changes
nothing unless the build defines `WSI_WL_NO_FIXES`.

## How the emulator knows it is running one of these builds

Every pack is built with `MESA_GIT_SHA1_OVERRIDE=<tag>`, so
`VkPhysicalDeviceDriverProperties::driverInfo` reads, for example,
`Mesa 27.0.0-devel (git-axfl2-003)`. The `axfl<N>-` prefix names the *fix generation*
the build carries: generation 1 is the Adreno 6xx change, generation 2 adds the
Adreno 7xx change. ARMSX2's driver database trusts the barrier-less in-pass read
only when it sees that prefix from a Turnip driver, and falls back to its own
barriers on every other driver. A pack built from this tree without the tag is a
correct driver that the emulator treats as stock.

## Releases

Each GitHub release is one driver build, with up to two assets:

- `turnip-<tag>-android.zip` — an [adrenotools](https://github.com/bylaws/libadrenotools)
  driver pack (`meta.json` + `libvulkan_freedreno.so`, plus our `MANIFEST.json`
  recording the source commit, patches, and build options). The ARMSX2 Android app
  lists these under **Settings → GPU driver → ARMSX2 · turnip** and installs them with
  one tap; any other adrenotools host (Yuzu-family emulators, Winlator…) accepts the
  same zip.
- `turnip-<tag>-aarch64.tar.gz` — the same driver built as a Khronos ICD for ARM
  Linux (ROCKNIX): `libvulkan_freedreno.so`, its ICD JSON
  (`freedreno_icd.aarch64.json`) and a `run-with-turnip.sh` wrapper that points
  `VK_DRIVER_FILES` at it.

The `.sha256` files beside each asset are the checksums the build recorded.

## Building

Android packs are built with the NDK (r28c) against API 29, as a HAL (`HMI`
entry point), with the same options every community Turnip pack uses:

```
-Dplatforms=android -Dplatform-sdk-version=29 -Dandroid-stub=true
-Dandroid-strict=false -Dandroid-libbacktrace=disabled
-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl
-Dgallium-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled
-Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled
-Dvideo-codecs= -Dvulkan-layers= -Dtools= -Dshader-cache=enabled
-Dglvnd=disabled -Dbuild-tests=false -Dvalgrind=disabled
-Dlibunwind=disabled -Dlmsensors=disabled -Dperfetto=false
-Dstrip=false -Dsplit-debug=disabled --buildtype=release -Db_ndebug=true
-Dc_args='-Wno-error -march=armv8-a -moutline-atomics' (and the same for cpp_args)
```

`-Dandroid-strict=false` is load-bearing: with it on, Mesa hides
`VK_KHR_dynamic_rendering`, `VK_KHR_synchronization2` and the local-read
extensions behind an Android-CTS whitelist keyed by API level, and the emulator
needs them. `-moutline-atomics` keeps one pack safe on ARMv8.0 Adreno 610 parts.
`MESA_GIT_SHA1_OVERRIDE` supplies the tag described above. The ARM Linux builds use
the equivalent non-Android option set with the Wayland platform
(`-Dplatforms=wayland`, built with `WSI_WL_NO_FIXES`) and the default (msm) kernel
interface.

## Licence

Mesa's licence applies unchanged; see `docs/license.rst`.
