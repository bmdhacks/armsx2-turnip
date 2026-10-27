#!/usr/bin/env python3
"""Gate a built Turnip package before it is allowed near a device.

The failure this exists to prevent is not a crash. It is a package that stages
cleanly, loads nothing, and lets the run fall back to the image's own driver -- so
the round produces a well-formed number about a driver nobody changed. Everything
below is either "this cannot load" or "you cannot tell whether it loaded".

Checks, in order:

  1. The file is an aarch64 ELF shared object exporting the ICD entry point.
  2. The build tag really is baked into the driverInfo string, un-truncated.
     (Mesa silently truncates MESA_GIT_SHA1_OVERRIDE to 10 characters.)
  3. Every NEEDED library is one the device is known to provide.
  4. No RPATH/RUNPATH -- the device must resolve dependencies itself, or a path
     that exists only on the build host quietly wins.
  5. Every versioned symbol requirement is within what the device's libc and
     libstdc++ provide.
  6. No unguarded LSE atomic instructions, when the baseline says the device is
     ARMv8.0 (Cortex-A73 has no LSE; an inline `casal` there is a SIGILL).
  7. The ICD manifest parses, names the absolute device path, and that path's
     basename is the driver actually in the package.
  8. SHA256SUMS matches the package contents.

Exit 0 = safe to stage. Anything else = do not stage.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

FAIL = []
WARN = []


def fail(msg):
    FAIL.append(msg)
    print(f"  FAIL  {msg}")


def warn(msg):
    WARN.append(msg)
    print(f"  WARN  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def vkey(v):
    """Version sort key that tolerates the odd shapes in symbol version names."""
    parts = []
    for chunk in re.split(r"[._]", v):
        parts.append((0, int(chunk)) if chunk.isdigit() else (1, 0))
    return parts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True, help="package directory from build-turnip.sh")
    ap.add_argument("--baseline", required=True, help="device baseline json")
    args = ap.parse_args()

    pkg = os.path.abspath(args.package)
    so = os.path.join(pkg, "libvulkan_freedreno.so")
    icd_files = [f for f in os.listdir(pkg) if f.startswith("freedreno_icd") and f.endswith(".json")]

    with open(args.baseline) as f:
        base = json.load(f)
    manifest_path = os.path.join(pkg, "MANIFEST.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)

    print(f"check-turnip: package {pkg}")
    print(f"              baseline {base.get('device', '?')} "
          f"({os.path.basename(args.baseline)})")
    print()

    if not os.path.exists(so):
        fail(f"no libvulkan_freedreno.so in {pkg}")
        return report()

    # 1 -- shape -------------------------------------------------------------
    ftype = run("file", "-b", so)
    if "ELF 64-bit LSB shared object" in ftype and "ARM aarch64" in ftype:
        ok(f"ELF aarch64 shared object ({os.path.getsize(so)} bytes)")
    else:
        fail(f"not an aarch64 ELF shared object: {ftype.strip()}")

    dynsyms = run("nm", "-D", "--defined-only", so)
    if "vk_icdGetInstanceProcAddr" in dynsyms:
        ok("exports vk_icdGetInstanceProcAddr")
    else:
        fail("does not export vk_icdGetInstanceProcAddr -- the loader will reject it")

    # 2 -- the verification hook ---------------------------------------------
    tag = manifest.get("build_tag")
    strings = run("strings", "-a", so)
    baked = re.findall(r"^Mesa [0-9][^\n]*$", strings, re.M)
    if tag:
        token = f"(git-{tag})"
        if any(token in s for s in baked):
            ok(f"driverInfo carries {token}  -> {[s for s in baked if token in s][0]!r}")
        else:
            fail(f"driverInfo does NOT carry {token}; found {baked!r}. "
                 f"Without it no run can prove which driver loaded.")
    else:
        warn("no build_tag in MANIFEST.json; cannot check the driverInfo token")
        print(f"        driverInfo strings found: {baked!r}")

    # 3, 4 -- dynamic section -------------------------------------------------
    dyn = run("readelf", "-d", so)
    needed = re.findall(r"NEEDED\).*\[([^\]]+)\]", dyn)
    provided = set(base.get("provided_libs", []))
    unknown = [n for n in needed if n not in provided]
    if not unknown:
        ok(f"all {len(needed)} NEEDED libraries are on the device's provided list")
    else:
        fail(f"NEEDED libraries not on the device's provided list: {unknown}. "
             f"Either stage them in lib-fallback/ or rebuild without them.")
    print(f"        NEEDED: {' '.join(needed)}")

    rpaths = re.findall(r"(RPATH|RUNPATH)\).*\[([^\]]+)\]", dyn)
    if not rpaths:
        ok("no RPATH/RUNPATH")
    else:
        fail(f"has RPATH/RUNPATH {rpaths} -- build-host paths must not leak into the package")

    # 5 -- versioned symbol requirements --------------------------------------
    ver = run("readelf", "-V", so)
    section = re.search(r"Version needs section.*?(?=\n\n|\Z)", ver, re.S)
    reqs = {}
    if section:
        for name in re.findall(r"Name:\s*([A-Za-z_]+_[0-9][0-9A-Za-z._]*)", section.group(0)):
            prefix, _, v = name.rpartition("_")
            reqs.setdefault(prefix, []).append(v)
    caps = base.get("max_symbol_versions", {})
    for prefix, versions in sorted(reqs.items()):
        worst = max(versions, key=vkey)
        cap = caps.get(prefix)
        if cap is None:
            warn(f"{prefix}: requires up to {prefix}_{worst}; baseline records no ceiling")
        elif vkey(worst) <= vkey(cap):
            ok(f"{prefix}: requires <= {prefix}_{worst}, device provides {prefix}_{cap}")
        else:
            fail(f"{prefix}: requires {prefix}_{worst} but the device only provides "
                 f"{prefix}_{cap} -- the driver will not load")

    # 6 -- ARMv8.0 atomics ----------------------------------------------------
    # Always scan, whichever device this baseline names: one package is meant to run
    # on both a6xx handhelds, so the SD865 run is the cheap place to notice that the
    # artifact has stopped being portable to the MQ65. Only the ARMv8.0 baseline
    # turns the finding into a failure.
    hard = bool(base.get("requires_outline_atomics"))
    n, examples = scan_lse(so)
    if n == 0:
        ok("no unguarded LSE atomics -- runs on an ARMv8.0 part as well as the SD865")
    elif hard:
        fail(f"{n} unguarded LSE atomic instruction(s) -- SIGILL on an ARMv8.0 part. "
             f"Rebuild with -march=armv8-a -moutline-atomics. e.g. {examples[:2]}")
    else:
        warn(f"{n} unguarded LSE atomic instruction(s). Fine on this "
             f"{base.get('arch_baseline', '?')} device, but this package will SIGILL on "
             f"the MQ65. e.g. {examples[:2]}")
    fb = os.path.join(pkg, "lib-fallback")
    if os.path.isdir(fb):
        for lib in sorted(os.listdir(fb)):
            k, _ = scan_lse(os.path.join(fb, lib))
            if k and hard:
                warn(f"lib-fallback/{lib} has {k} unguarded LSE atomic(s); it is NOT safe "
                     f"to put on LD_LIBRARY_PATH on an ARMv8.0 part")
            elif k:
                print(f"        (note: lib-fallback/{lib} inlines LSE -- SD865 only)")

    # 7 -- ICD manifest -------------------------------------------------------
    if len(icd_files) != 1:
        fail(f"expected exactly one freedreno_icd*.json in the package, found {icd_files}")
    else:
        with open(os.path.join(pkg, icd_files[0])) as f:
            icd = json.load(f)
        lp = icd.get("ICD", {}).get("library_path", "")
        if not lp.startswith("/"):
            fail(f"ICD library_path {lp!r} is not absolute; the loader resolves relative "
                 f"paths against the manifest's directory, which is fragile here")
        elif os.path.basename(lp) != "libvulkan_freedreno.so":
            fail(f"ICD library_path {lp!r} does not name libvulkan_freedreno.so")
        else:
            want = manifest.get("install_dir")
            if want and os.path.dirname(lp) != want:
                fail(f"ICD library_path directory {os.path.dirname(lp)!r} != "
                     f"MANIFEST install_dir {want!r}")
            else:
                ok(f"ICD manifest points at {lp}")
                print(f"        ** the package MUST be unpacked to exactly "
                      f"{os.path.dirname(lp)} on the device **")

    # 8 -- checksums ----------------------------------------------------------
    sums = os.path.join(pkg, "SHA256SUMS")
    if os.path.exists(sums):
        bad = []
        with open(sums) as f:
            for line in f:
                digest, _, name = line.strip().partition("  ")
                p = os.path.join(pkg, name)
                if not os.path.exists(p):
                    bad.append(f"{name} missing")
                    continue
                h = hashlib.sha256()
                with open(p, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
                if h.hexdigest() != digest:
                    bad.append(f"{name} changed")
        if bad:
            fail(f"SHA256SUMS mismatch: {bad}")
        else:
            ok("SHA256SUMS matches the package contents")
    else:
        warn("no SHA256SUMS in the package")

    # provenance reminder -----------------------------------------------------
    prov = base.get("provenance", {})
    if prov:
        print()
        print("  baseline provenance (this gate is only as good as these):")
        for k, v in prov.items():
            print(f"        {k}: {v}")

    # Every check above compares the binary against a recorded belief about the
    # device. Where that belief was never probed, say so here rather than letting a
    # green line imply a measurement.
    unver = base.get("unverified", [])
    if unver:
        print()
        print(f"  !! STILL UNVERIFIED ON {base.get('device', '?').upper()} -- "
              f"these are assumptions, not checks:")
        for u in unver:
            print(f"        - {u}")
    assumed = [k for k, v in prov.items() if v.startswith("ASSUMED")]
    if assumed:
        print(f"  !! baseline entries carried over rather than measured: {', '.join(assumed)}")

    return report()


def scan_lse(path):
    """Count LSE atomic instructions outside the __aarch64_* outline-atomic helpers.

    The helpers runtime-check __aarch64_have_lse_atomics and branch to an ldxr/stxr
    loop on a part without LSE, so LSE inside them is fine. Anywhere else it is a
    SIGILL on ARMv8.0.
    """
    disasm = run("objdump", "-d", path)
    lse = re.compile(r"\t(cas|swp|ldadd|ldclr|ldset|ldeor|ldsmax|ldsmin|ldumax|ldumin)"
                     r"(a|l|al)?(b|h)?\s")
    guarded = False
    n = 0
    examples = []
    for line in disasm.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.*)>:", line)
        if m:
            guarded = "__aarch64_" in m.group(1)
            continue
        if not guarded and lse.search(line):
            n += 1
            if len(examples) < 4:
                examples.append(line.strip())
    return n, examples


def report():
    print()
    if FAIL:
        print(f"check-turnip: {len(FAIL)} FAILURE(S), {len(WARN)} warning(s) -- DO NOT STAGE")
        return 1
    print(f"check-turnip: PASS ({len(WARN)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
