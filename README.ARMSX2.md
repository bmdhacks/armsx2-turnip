# ARMSX2 Turnip

This is Mesa, with the changes [ARMSX2](https://github.com/ARMSX2/ARMSX2) — an
ARM64 PlayStation 2 emulator — makes to **Turnip**, the open Vulkan driver for
Qualcomm Adreno GPUs (`src/freedreno/vulkan/`). Nothing outside Turnip is touched.

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
| `armsx2/26.1.2` | Mesa tag `mesa-26.1.2` | The measured line. This is what the ARMSX2 ROCKNIX images and the Android driver pack for Adreno 6xx are built from. |
| `armsx2/main` | upstream `main` at the commit named in the branch's first ARMSX2 commit | The same patches on a newer Mesa, for devices whose community driver is already on a newer series. |

Each branch is the base plus a short series of ARMSX2 commits; `git log
mesa-26.1.2..armsx2/26.1.2` lists exactly what changed. `main` in this
repository is the unmodified upstream mirror the fork was taken from.

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
untouched: they never emitted the prim-mode state and need the application's
barriers, which ARMSX2 keeps.

## How the emulator knows it is running one of these builds

Every pack is built with `MESA_GIT_SHA1_OVERRIDE=<tag>`, so
`VkPhysicalDeviceDriverProperties::driverInfo` reads, for example,
`Mesa 26.1.2 (git-axfl1-a04)`. The `axfl<N>-` prefix names the *fix generation*
the build carries. ARMSX2's driver database trusts the barrier-less in-pass read on
Adreno 6xx only when it sees that prefix from a Turnip driver, and falls back to its
own barriers on every other driver. A pack built from this tree without the tag is a
correct driver that the emulator treats as stock.

## Releases

Each GitHub release is one driver pack:

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
the equivalent non-Android option set: a headless build with no window-system
platforms and the default (msm) kernel interface.

## Licence

Mesa's licence applies unchanged; see `docs/license.rst`.
