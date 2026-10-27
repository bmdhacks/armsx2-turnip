# ARMSX2 release builds

The scripts `.github/workflows/armsx2-release.yml` runs to build the two driver packs
of a release. Releases are built only by that workflow.

| File | What |
|---|---|
| `linux/build-turnip.sh` | Builds `turnip-<tag>-aarch64.tar.gz`, the ARM Linux (ROCKNIX) ICD, with X11 and Wayland presentation. Native aarch64. |
| `linux/check-turnip.py` | Load check for that package against a device baseline: NEEDED libraries, symbol versions, no RPATH, no unguarded LSE atomics, the build tag in driverInfo. |
| `linux/device-baseline/*.json` | What two ROCKNIX handhelds provide: `sd865` (Retroid Pocket Flip 2) and `mq65` (MANGMI Air X, ARMv8.0). |
| `linux/run-with-turnip.sh` | Launcher shipped inside the tarball. |
| `android/build-turnip-android.sh` | Builds `turnip-<tag>-android.zip`, the adrenotools pack, with NDK r28c against API 29. |
| `android/check-turnip-android.py` | The same kind of load check for the Android pack. |
| `android/device-baseline/android13-sphal.json` | What Android's sphal linker namespace provides. |

## Cutting a release

1. Pick the tag. It is baked into the driver as `(git-<tag>)` and must be at most 10
   characters. The `axfl<N>-` prefix is the fix generation ARMSX2 reads (see
   `README.ARMSX2.md`), so a release that carries generation 3 is `axfl3-<n>`.
2. Make sure the commit to release is on `armsx2/main` (the workflow file must be in
   the tagged commit, or the tag push builds nothing), then tag it and push the tag:

   ```
   git tag axfl3-002 <commit>
   git push origin axfl3-002
   ```

3. Watch the run under Actions → "ARMSX2 release". Both builds must pass their load
   checks; a failure stops the release.
4. The run creates a draft release with both packs and a "Technical details" table.
   Write the notes above it and publish. ARMSX2 lists the release once it is
   published.

To build without releasing (to test a branch), run the workflow by hand with a ref
and a build tag; the packs are kept as the run's artifacts.

## The build machines

GitHub's `ubuntu-24.04-arm` (Linux pack) and `ubuntu-24.04` (Android pack). Their
libraries are older than or equal to what the devices provide (glibc 2.39,
libwayland 1.22), which is the direction that loads. The device baselines are what
the load check holds the package to; a new NEEDED library has to be confirmed on the
devices and added there before it can ship.
