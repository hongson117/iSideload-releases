#!/usr/bin/env python3
"""Bounded, dependency-free IPA/Mach-O release checks; not a decompiler or proof of secrecy."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import sys
import unittest
import zipfile

ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_PIE = 0x00200000
MACH_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce")
FAT_MAGICS = (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
SOURCE_EXTENSIONS = {".swift", ".rs", ".py", ".sh", ".ps1", ".c", ".cc", ".cpp", ".h", ".hpp", ".map", ".pdb"}
PRIVATE_EXTENSIONS = {".p12", ".pfx", ".key", ".pem", ".rppair"}
PRIVATE_NAMES = {".env", ".mcp_key", ".agent_secret", ".isl_creds", "credentials.json", "pairing.plist", "rp_pairing_file.plist"}
SECRET_PATTERNS = {
    "private_key_block": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "github_personal_access_token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    "aws_access_key_id": re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}"),
}


def region(data: bytes, offset: int, length: int) -> bytes:
    if offset < 0 or length < 0 or offset + length > len(data):
        raise ValueError("Binary offset is out of bounds")
    return data[offset:offset + length]


def cstr(data: bytes) -> str:
    return data.split(b"\0", 1)[0].decode("utf-8", errors="replace")


def slices(data: bytes) -> list[bytes]:
    magic = data[:4]
    if magic in MACH_MAGICS:
        return [data]
    if magic not in FAT_MAGICS:
        raise ValueError("Executable is not Mach-O")
    endian = ">" if magic in (FAT_MAGICS[0], FAT_MAGICS[2]) else "<"
    wide = magic in FAT_MAGICS[2:]
    count = struct.unpack(endian + "I", region(data, 4, 4))[0]
    if not 1 <= count <= 32:
        raise ValueError("Invalid fat architecture count")
    size = 32 if wide else 20
    result = []
    for index in range(count):
        entry = region(data, 8 + index * size, size)
        if wide:
            _, _, offset, length, _, _ = struct.unpack(endian + "iiQQII", entry)
        else:
            _, _, offset, length, _ = struct.unpack(endian + "iiIII", entry)
        result.append(region(data, offset, length))
    return result


def macho(data: bytes) -> dict:
    magic = data[:4]
    if magic not in MACH_MAGICS:
        raise ValueError("Unsupported Mach-O magic")
    wide = magic in MACH_MAGICS[:2]
    endian = "<" if magic in (MACH_MAGICS[0], MACH_MAGICS[2]) else ">"
    header_size = 32 if wide else 28
    header = struct.unpack(endian + ("IiiIIIII" if wide else "IiiIIII"), region(data, 0, header_size))
    _, cpu, _, filetype, ncmds, sizeofcmds, flags, *_ = header
    if ncmds > 65536:
        raise ValueError("Invalid load command count")
    commands_end = header_size + sizeofcmds
    region(data, header_size, sizeofcmds)
    offset = header_size
    dwarf_sections = []
    swift_metadata = []
    local_defined = 0
    debug_symbols = 0
    undefined_symbols = 0
    external_defined = 0
    symtab = None
    for _ in range(ncmds):
        cmd, size = struct.unpack(endian + "II", region(data, offset, 8))
        if size < 8 or offset + size > commands_end:
            raise ValueError("Malformed load command")
        command = region(data, offset, size)
        if cmd in (0x19, 0x1):
            is64 = cmd == 0x19
            base = 72 if is64 else 56
            section_size = 80 if is64 else 68
            segment = cstr(region(command, 8, 16))
            section_count = struct.unpack(endian + "I", region(command, 64 if is64 else 48, 4))[0]
            if segment == "__DWARF":
                dwarf_sections.append(segment)
            for index in range(section_count):
                name = cstr(region(command, base + index * section_size, 16))
                if name.startswith(("__debug_", "__zdebug_")):
                    dwarf_sections.append(name)
                if name.startswith(("__swift5_", "__constg_swift")):
                    swift_metadata.append(name)
        if cmd == 0x2:
            symtab = struct.unpack(endian + "IIII", region(command, 8, 16))
        offset += size
    if offset != commands_end:
        raise ValueError("Load commands do not match header size")
    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        symbols = region(data, symoff, nsyms * (16 if wide else 12))
        strings = region(data, stroff, strsize)
        fmt = endian + ("IBBHQ" if wide else "IBBHI")
        for index in range(nsyms):
            strx, typ, _, _, _ = struct.unpack_from(fmt, symbols, index * (16 if wide else 12))
            if strx >= len(strings):
                raise ValueError("Symbol string index is out of bounds")
            # Apple's linker may retain this N_OPT marker even in fully stripped releases.
            harmless_linker_marker = typ == 0x3C and strings[strx:].startswith(b"radr://")
            if typ & 0xE0:
                if not harmless_linker_marker:
                    debug_symbols += 1
            elif typ & 0x0E == 0:
                undefined_symbols += 1
            elif typ & 1:
                external_defined += 1
            else:
                local_defined += 1
    return {"architecture": "arm64" if cpu == ARM64 else hex(cpu), "filetype": filetype,
            "pie": bool(flags & MH_PIE), "dwarf_sections": sorted(set(dwarf_sections)),
            "local_defined_symbols": local_defined, "debug_symbols": debug_symbols,
            "external_defined_symbols": external_defined, "undefined_symbols": undefined_symbols,
            "swift_runtime_metadata_sections": sorted(set(swift_metadata))}


def audit(path: Path, expected_sha: str | None = None) -> dict:
    failures = []
    report = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
              "limitations": ["Static package/layout checks only; no decompilation, runtime anti-tamper test or proof of absence of secrets.",
                              "Stripping does not remove Swift/Objective-C runtime metadata, framework imports, literals or machine code.",
                              "Public hashes detect accidental changes only when obtained from a trusted distribution channel."]}
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            failures.append("zip_crc_failed")
        names = archive.namelist()
        if len(names) != len(set(names)):
            failures.append("duplicate_archive_entries")
        infos = [name for name in names if name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(infos) != 1:
            raise ValueError("Expected exactly one Payload/*.app/Info.plist")
        info = plistlib.loads(archive.read(infos[0]))
        report["app"] = {key: info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "ISLGitSHA")}
        if expected_sha and info.get("ISLGitSHA") != expected_sha:
            failures.append("build_sha_mismatch")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or "/" in executable or "\\" in executable:
            raise ValueError("Invalid CFBundleExecutable")
        executable_path = infos[0].removesuffix("Info.plist") + executable
        report["main_executable"] = [macho(part) for part in slices(archive.read(executable_path))]
        for binary in report["main_executable"]:
            if binary["architecture"] != "arm64" or binary["filetype"] != MH_EXECUTE:
                failures.append("main_must_be_arm64_executable")
            if not binary["pie"]:
                failures.append("main_missing_pie")
            if binary["dwarf_sections"] or binary["debug_symbols"] or binary["local_defined_symbols"]:
                failures.append("main_contains_debug_or_local_symbols")
        package_findings = []
        secret_findings = []
        for name in names:
            member = PurePosixPath(name)
            if member.is_absolute() or ".." in member.parts or "\\" in name:
                failures.append("unsafe_archive_path")
            if name.endswith("/"):
                continue
            lower_parts = [part.lower() for part in member.parts]
            if (member.suffix.lower() in SOURCE_EXTENSIONS | PRIVATE_EXTENSIONS or
                    member.name.lower() in PRIVATE_NAMES or member.name.lower().endswith(".rppair.plist") or
                    any(part in {".git", ".ds_store", "__macosx"} or part.endswith(".dsym") for part in lower_parts) or
                    member.name == "embedded.mobileprovision"):
                package_findings.append(name)
            data = archive.read(name)
            for kind, pattern in SECRET_PATTERNS.items():
                if pattern.search(data):
                    secret_findings.append({"entry": name, "kind": kind})
        if package_findings:
            failures.append("source_debug_or_signing_material_in_public_package")
        if secret_findings:
            failures.append("possible_embedded_secret")
        report["package_findings"] = package_findings
        report["secret_findings"] = secret_findings  # Never print matching values.
        report["entry_count"] = len(names)
    report["failures"] = sorted(set(failures))
    report["passed"] = not failures
    return report


class ParserTests(unittest.TestCase):
    @staticmethod
    def executable(flags=MH_PIE, commands=b"", ncmds=0):
        return struct.pack("<IiiIIIII", 0xFEEDFACF, ARM64, 0, MH_EXECUTE, ncmds, len(commands), flags, 0) + commands

    def test_main_flags_and_architecture(self):
        self.assertTrue(macho(self.executable())["pie"])
        self.assertFalse(macho(self.executable(0))["pie"])

    def test_dwarf_segment_is_detected(self):
        command = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__DWARF", 0, 0, 0, 0, 0, 0, 0, 0)
        self.assertEqual(macho(self.executable(commands=command, ncmds=1))["dwarf_sections"], ["__DWARF"])

    def test_truncated_load_command_rejected(self):
        with self.assertRaises(ValueError):
            macho(self.executable(commands=struct.pack("<II", 2, 24), ncmds=1))

    def test_fat_offsets_are_bounded(self):
        broken = struct.pack(">IIiiIII", 0xCAFEBABE, 1, ARM64, 0, 4096, 32, 0)
        with self.assertRaises(ValueError):
            slices(broken)

    def test_private_key_scanner_does_not_match_public_certificate(self):
        self.assertIsNone(SECRET_PATTERNS["private_key_block"].search(b"-----BEGIN CERTIFICATE-----"))
        self.assertIsNotNone(SECRET_PATTERNS["private_key_block"].search(b"-----BEGIN PRIVATE KEY-----"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, nargs="?")
    parser.add_argument("--expected-sha", help="Expected short ISLGitSHA embedded by CI")
    parser.add_argument("--output", type=Path, help="Write the same non-secret JSON report to this file")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ParserTests)).wasSuccessful() else 1
    if args.ipa is None:
        parser.error("ipa is required unless --self-test is used")
    try:
        report = audit(args.ipa, args.expected_sha)
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        report = {"passed": False, "error": str(error)}
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
