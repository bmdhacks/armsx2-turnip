#!/usr/bin/env python3
"""Gate a Turnip driver pack before it is allowed near an Android device.

The failure this exists to prevent is not a crash. ARMSX2's VKLoader.cpp falls back
to the system Vulkan loader when adrenotools returns null, and it does so silently
(`if (TryOpenAdrenotoolsDriver(...)) ... else` at VKLoader.cpp:139-154) -- so a broken
pack does not stop a run, it produces a well-formed number taken on the stock
Qualcomm driver. Every check below is either "this cannot load" or "you cannot tell
whether it loaded".

Checks, in order:

  1.  aarch64 ELF shared object (read out of the ELF header, not out of `file`).
  2.  The Android API level the toolchain targeted, from .note.android.ident, is not
      above what meta.json claims as minApi.
  3.  Exports HAL_MODULE_INFO_SYM ("HMI"). Android's libvulkan finds a driver through
      libhardware's hw_get_module, not through an ICD manifest; without HMI the pack
      loads and then provides nothing. Mesa only emits it under -Dplatforms=android.
  4.  Exports NOTHING ELSE. vulkan-android.sym demotes every other symbol to
      local, so a driver that exports vk_icdGetInstanceProcAddr was built for the
      Khronos loader and Android will find no HAL in it.
  5.  The build tag really is in the driverInfo string, un-truncated.
  6.  Every NEEDED library is reachable from the linker namespace adrenotools builds,
      and none is on the forbidden list.
  7.  SONAME equals the library name meta.json declares.
  8.  No RPATH/RUNPATH -- a build-host path must not leak into a pack.
  9.  No versioned GLIBC_ symbol requirements. Bionic has no symbol versioning; a
      GLIBC_x.y requirement means a Linux build wandered in.
  10. No unguarded LSE atomics, where the baseline says an ARMv8.0 part has to work.
  11. meta.json parses and agrees with the binary.
  12. SHA256SUMS matches the package as it stands now.
  13. The zip the app ingests is flat, complete, and cannot escape its directory.

The binutils on an x86_64 build host will not disassemble aarch64, so every external
tool here comes from the NDK's llvm-* set by default.

Exit 0 = safe to hand to the app. Anything else = do not ship.
"""

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import zipfile

FAIL = []
WARN = []
TOOLS = {}


def fail(msg):
    FAIL.append(msg)
    print(f"  FAIL  {msg}")


def warn(msg):
    WARN.append(msg)
    print(f"  WARN  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def run(tool, *args):
    return subprocess.run([TOOLS[tool], *args], capture_output=True, text=True).stdout


# ---------------------------------------------------------------- ELF bits ----

class Elf:
    """Just enough 64-bit little-endian ELF to answer the questions below.

    Shelling out to readelf for the machine type and the Android note means parsing
    a human-readable format that changes between binutils and llvm. The header and
    the section table do not change.
    """

    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        self.valid = d[:4] == b"\x7fELF" and d[4] == 2 and d[5] == 1
        if not self.valid:
            return
        self.etype, self.machine = struct.unpack_from("<HH", d, 16)
        e_shoff, = struct.unpack_from("<Q", d, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
        self.sections = {}
        raw = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            name, stype, flags, addr, offset, size = struct.unpack_from("<IIQQQQ", d, off)
            raw.append((name, offset, size))
        _, stroff, strsize = raw[e_shstrndx]
        strtab = d[stroff:stroff + strsize]
        for name, offset, size in raw:
            end = strtab.find(b"\0", name)
            self.sections[strtab[name:end].decode()] = (offset, size)

    def section(self, name):
        if name not in self.sections:
            return None
        off, size = self.sections[name]
        return self.data[off:off + size]

    def android_api(self):
        """API level out of .note.android.ident.

        The NDK stamps every binary with this note; its descriptor starts with the
        API level the toolchain targeted. That number, not the command line that
        produced it, is what the device's linker was compiled against.
        """
        note = self.section(".note.android.ident")
        if not note or len(note) < 12:
            return None
        namesz, descsz, _ = struct.unpack_from("<III", note, 0)
        off = 12 + ((namesz + 3) & ~3)
        if descsz < 4 or len(note) < off + 4:
            return None
        return struct.unpack_from("<I", note, off)[0]


def scan_lse(path):
    """Count LSE atomic instructions outside the __aarch64_* outline-atomic helpers.

    The helpers runtime-check __aarch64_have_lse_atomics and branch to an ldxr/stxr
    loop on a part without LSE, so LSE inside them is fine. Anywhere else it is a
    SIGILL on ARMv8.0.
    """
    disasm = run("objdump", "-d", path)
    lse = re.compile(r"\b(cas|swp|ldadd|ldclr|ldset|ldeor|ldsmax|ldsmin|ldumax|ldumin)"
                     r"(a|l|al)?(b|h)?\s+[wx]")
    guarded = False
    n = 0
    examples = []
    for line in disasm.splitlines():
        m = re.match(r"^[0-9a-f]+\s+<(.*)>:", line)
        if m:
            guarded = "__aarch64_" in m.group(1)
            continue
        if not guarded and lse.search(line):
            n += 1
            if len(examples) < 4:
                examples.append(line.strip())
    return n, examples


# -------------------------------------------------------------------- main ----

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True, help="package directory from build-turnip-android.sh")
    ap.add_argument("--baseline", required=True, help="android baseline json")
    ap.add_argument("--zip", help="the pack zip the app ingests")
    ap.add_argument("--tools-dir",
                    default=os.path.expanduser(
                        "~/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"),
                    help="directory holding llvm-readelf / llvm-nm / llvm-objdump / llvm-strings")
    args = ap.parse_args()

    for name in ("readelf", "nm", "objdump", "strings"):
        cand = os.path.join(args.tools_dir, "llvm-" + name)
        TOOLS[name] = cand if os.path.exists(cand) else name

    pkg = os.path.abspath(args.package)
    with open(args.baseline) as f:
        base = json.load(f)

    manifest = {}
    mpath = os.path.join(pkg, "MANIFEST.json")
    if os.path.exists(mpath):
        with open(mpath) as f:
            manifest = json.load(f)

    meta = {}
    metapath = os.path.join(pkg, "meta.json")
    if os.path.exists(metapath):
        with open(metapath) as f:
            meta = json.load(f)

    libname = meta.get("libraryName") or "libvulkan_freedreno.so"
    so = os.path.join(pkg, libname)

    print(f"check-turnip-android: package {pkg}")
    print(f"                      baseline {base.get('device','?')} "
          f"({os.path.basename(args.baseline)})")
    print(f"                      tools    {TOOLS['readelf']}")
    print()

    if not os.path.exists(so):
        fail(f"no {libname} in {pkg}")
        return report()

    elf = Elf(so)

    # 1 -- shape --------------------------------------------------------------
    if not elf.valid:
        fail("not a 64-bit little-endian ELF")
    elif elf.machine != 183:      # EM_AARCH64
        fail(f"ELF machine is {elf.machine}, not aarch64 (183)")
    elif elf.etype != 3:          # ET_DYN
        fail(f"ELF type is {elf.etype}, not a shared object (3)")
    else:
        ok(f"aarch64 ELF shared object ({os.path.getsize(so)} bytes)")

    # 2 -- target API ---------------------------------------------------------
    note_api = elf.android_api() if elf.valid else None
    claimed = meta.get("minApi")
    floor = base.get("min_api")
    if note_api is None:
        fail("no .note.android.ident -- this was not built with the Android NDK, "
             "so it is not an Android binary whatever else it looks like")
    elif claimed is None:
        warn(f"meta.json has no minApi; the binary targets android{note_api}")
    elif note_api > claimed:
        fail(f"binary targets android{note_api} but meta.json claims minApi "
             f"{claimed} -- it will not load on the devices meta.json invites")
    else:
        ok(f"binary targets android{note_api}, meta.json minApi {claimed}")
        if floor is not None and note_api < floor:
            warn(f"the loading mechanism itself needs android{floor}, so targeting "
                 f"{note_api} buys nothing; harmless")

    # 3, 4 -- entry points ----------------------------------------------------
    dynsyms = run("nm", "-D", "--defined-only", so)
    if re.search(r"^\S*\s*[A-Za-z]\s+HMI$", dynsyms, re.M):
        ok("exports HMI (HAL_MODULE_INFO_SYM) -- Android's libvulkan can open it")
    else:
        fail("does not export HMI -- built without -Dplatforms=android; Android's "
             "libvulkan loads it and finds no HAL")
    # And nothing else. src/vulkan/vulkan-android.sym demotes every other symbol to
    # local on an Android build, so the whole dynamic export surface is HMI. A driver
    # that exports vk_icdGetInstanceProcAddr was built for the Khronos loader, i.e.
    # for Linux, and Android will not find a HAL in it.
    exported = sorted(m.group(1) for m in
                      re.finditer(r"^\S*\s*[A-Za-z]\s+(\S+)$", dynsyms, re.M))
    if "vk_icdGetInstanceProcAddr" in exported:
        fail("exports vk_icdGetInstanceProcAddr -- this is a Khronos-loader ICD "
             "build, not an Android HAL; -Dplatforms=android was not in effect")
    elif exported == ["HMI"]:
        ok("dynamic export surface is exactly HMI, as vulkan-android.sym intends")
    else:
        warn(f"dynamic exports beyond HMI: {exported[:8]}"
             f"{' ...' if len(exported) > 8 else ''}")

    # 5 -- the verification hook ----------------------------------------------
    tag = manifest.get("build_tag")
    strings = run("strings", "-a", so)
    baked = re.findall(r"^Mesa [0-9][^\n]*$", strings, re.M)
    if tag:
        token = f"(git-{tag})"
        hit = [s for s in baked if token in s]
        if hit:
            ok(f"driverInfo carries {token}  -> {hit[0]!r}")
        else:
            fail(f"driverInfo does NOT carry {token}; found {baked!r}. Without it no "
                 f"run can prove which driver loaded.")
    else:
        warn("no build_tag in MANIFEST.json; cannot check the driverInfo token")
        print(f"        driverInfo strings found: {baked!r}")

    # 6, 7, 8 -- dynamic section ----------------------------------------------
    dyn = run("readelf", "-d", so)
    needed = re.findall(r"NEEDED\).*?\[([^\]]+)\]", dyn)
    provided = set(base.get("provided_libs", []))
    forbidden = set(base.get("forbidden_libs", []))
    bad = [n for n in needed if n in forbidden]
    unknown = [n for n in needed if n not in provided and n not in forbidden]
    if bad:
        fail(f"NEEDED names a library that cannot be in this namespace: {bad}")
    if not unknown and not bad:
        ok(f"all {len(needed)} NEEDED libraries are reachable from the sphal namespace")
    elif unknown:
        fail(f"NEEDED libraries not on the namespace's provided list: {unknown}. "
             f"Either they are unreachable on the device or the baseline is short an "
             f"entry -- decide which before shipping.")
    print(f"        NEEDED: {' '.join(needed)}")

    soname = re.search(r"SONAME\).*?\[([^\]]+)\]", dyn)
    if not soname:
        fail("no SONAME")
    elif soname.group(1) != libname:
        fail(f"SONAME {soname.group(1)!r} != meta.json libraryName {libname!r}")
    else:
        ok(f"SONAME is {libname}")

    rpaths = re.findall(r"(RPATH|RUNPATH)\).*?\[([^\]]+)\]", dyn)
    if not rpaths:
        ok("no RPATH/RUNPATH")
    else:
        fail(f"has RPATH/RUNPATH {rpaths} -- build-host paths must not leak into a pack")

    # 9 -- no glibc symbol versioning -----------------------------------------
    ver = run("readelf", "--version-info", so)
    if re.search(r"GLIBC_[0-9]", ver):
        fail("requires versioned GLIBC_ symbols -- this is a glibc build; Bionic has "
             "no symbol versioning and will not resolve them")
    else:
        ok("no GLIBC_ versioned symbol requirements (Bionic-shaped)")

    # 10 -- ARMv8.0 atomics ---------------------------------------------------
    hard = bool(base.get("requires_outline_atomics"))
    n, examples = scan_lse(so)
    if n == 0:
        ok("no unguarded LSE atomics -- safe on an ARMv8.0 Adreno part too")
    elif hard:
        fail(f"{n} unguarded LSE atomic instruction(s) -- SIGILL on an ARMv8.0 part. "
             f"Rebuild with -march=armv8-a -moutline-atomics. e.g. {examples[:2]}")
    else:
        warn(f"{n} unguarded LSE atomic instruction(s); fine on an ARMv8.2 part, "
             f"SIGILL on ARMv8.0. e.g. {examples[:2]}")

    # 11 -- meta.json agrees with the binary ----------------------------------
    if not meta:
        fail("no meta.json -- CustomDriver.kt synthesises one on import, and then the "
             "pack carries no version, no name and no provenance")
    else:
        mv = manifest.get("mesa_version")
        if mv and meta.get("driverVersion") != mv:
            fail(f"meta.json driverVersion {meta.get('driverVersion')!r} != built Mesa "
                 f"version {mv!r}")
        else:
            ok(f"meta.json: name={meta.get('name')!r} "
               f"driverVersion={meta.get('driverVersion')!r} "
               f"minApi={meta.get('minApi')} libraryName={libname!r}")

    # 12 -- checksums ---------------------------------------------------------
    sums = os.path.join(pkg, "SHA256SUMS")
    if os.path.exists(sums):
        bad_files = []
        with open(sums) as f:
            for line in f:
                digest, _, name = line.strip().partition("  ")
                p = os.path.join(pkg, name)
                if not os.path.exists(p):
                    bad_files.append(f"{name} missing")
                    continue
                h = hashlib.sha256()
                with open(p, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
                if h.hexdigest() != digest:
                    bad_files.append(f"{name} changed")
        if bad_files:
            fail(f"SHA256SUMS mismatch: {bad_files}")
        else:
            ok("SHA256SUMS matches the package contents")
    else:
        warn("no SHA256SUMS in the package")

    # 13 -- the zip -----------------------------------------------------------
    if args.zip:
        if not os.path.exists(args.zip):
            fail(f"no zip at {args.zip}")
        else:
            with zipfile.ZipFile(args.zip) as z:
                names = z.namelist()
            slip = [n for n in names if n.startswith("/") or ".." in n]
            if slip:
                fail(f"zip entries would escape the install directory: {slip}")
            elif libname not in names:
                fail(f"zip does not carry {libname} at its root; the installer aborts "
                     f"the import")
            elif "meta.json" not in names:
                fail("zip does not carry meta.json at its root")
            else:
                ok(f"zip is flat and complete: {names}")

    # provenance reminder -----------------------------------------------------
    prov = base.get("provenance", {})
    if prov:
        print()
        print("  baseline provenance (this gate is only as good as these):")
        for k, v in prov.items():
            print(f"        {k}: {v}")

    unver = base.get("unverified", [])
    if unver:
        print()
        print("  !! STILL UNVERIFIED -- these are assumptions, not checks:")
        for u in unver:
            print(f"        - {u}")

    return report()


def report():
    print()
    if FAIL:
        print(f"check-turnip-android: {len(FAIL)} FAILURE(S), {len(WARN)} warning(s) "
              f"-- DO NOT SHIP")
        return 1
    print(f"check-turnip-android: PASS ({len(WARN)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
