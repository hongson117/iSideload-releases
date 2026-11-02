# Public IPA release hardening

The intended distribution model is private source and a public download repository containing release binaries only. A previously public revision may already have been cloned or forked; making a repository private cannot recall copies. GitHub documents that existing public forks remain public and are detached from the repository. Keep new development and build logs private. Publish unsigned IPAs, checksums, release notes and required third-party notices; do not publish the source ZIP, Git bundle, VPS backup, pairing files, account cache, signing identities, private CI artifacts or debug bundles. [GitHub visibility documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).

This reduces casual copying and unnecessary disclosure. It cannot make an IPA impossible to disassemble, decompile, instrument, modify or redistribute. Users must re-sign iSideload, so the app deliberately cannot pin the developer Team ID, require the original Apple signature or reject a normal development provisioning profile. Those restrictions would break the product's installation model.

## Existing artifact evidence

The `1.2.0 (31)` IPA at commit `cb9a3e9` was inspected as a ZIP and a Mach-O executable. Its main binary is ARM64 and has the `MH_PIE` flag. No DWARF segments/sections or local defined symbols were present. Its symbol table held 1,384 undefined imports, two external defined symbols and one harmless Apple linker marker. This is consistent with effective release stripping; undefined Apple framework imports remain necessary for dynamic linking.

Swift reflection/type sections, Objective-C runtime names, strings and the machine code remain. Their presence is normal and permits further analysis. The inspection did not decompile functions or observe instrumented runtime behavior.

REA doctor was attempted without changing configuration. No REA tools were connected; the available Node runtime was below the current REA CLI requirement, and no Hopper, Ghidra or IDA engine was configured. No analysis engine was installed. The checks below therefore make bounded package/layout claims, not a claim that REA cannot analyze the app.

## Build measures

- Keep Rust release optimization, LTO, symbol stripping and `panic = "abort"`; set `debug = 0` explicitly. These remove debugging aids and can simplify the shipped artifact but do not encrypt the code. [Cargo profile settings](https://doc.rust-lang.org/cargo/reference/profiles.html).
- Build Swift in Release with whole-module optimization, testability disabled, hidden C/C++ symbols and dead-code stripping. Strip the unsigned final executable before IPA packaging. Retain any useful debug symbols privately, outside the IPA. [Xcode build settings](https://developer.apple.com/documentation/xcode/build-settings-reference).
- Remap Rust build-directory prefixes in CI so panic/error strings do not unnecessarily disclose private workspace paths. Remapping is not string obfuscation.
- Keep protocol implementations, reusable secrets, privileged credentials and signing identities out of the public package. Protocol constants, public URLs and verification public keys are not secrets and need not be disguised.
- Add the artifact audit to CI before uploading/publishing. Release only the exact IPA that passed. Publish its SHA-256 through the official download channel. A checksum is an integrity comparison, not independent publisher authentication if an attacker controls that same channel.
- Keep GitHub access and release permissions narrow. An unsigned IPA should contain neither `embedded.mobileprovision` nor user signing keys. Personal `.p12` files and pairing records are created/imported later into the app sandbox, not shipped with the public build.

Anti-debug `ptrace` calls, jailbreak blockers, certificate/Team-ID pinning and opaque runtime download/execute schemes are intentionally absent. They create compatibility/support problems and are patchable by an analyst. Moving Apple-ID signing or pairing secrets to an online licensing server would also change the current privacy and offline-use model; it is not necessary for this release.

## Verification

From the private source checkout:

```sh
python scripts/audit_release.py --self-test
python scripts/audit_release.py iSideload.ipa --expected-sha SHORT_SHA --output release-audit.json
```

The dependency-free script checks ZIP consistency, app identity, ARM64 executable layout, PIE, absence of DWARF/local/debug symbols in the main binary, and unwanted source/debug/signing files in the public package. It searches for a few recognizable secret formats without printing any matched value. This is not a comprehensive secret scanner or a cryptographic authenticity check. Swift/Objective-C runtime metadata and imported symbols are counted rather than removed.

Before promoting a build, also verify first install on a new phone, same-device re-sign with the same bundle identifier, app data/account persistence, nearby-phone install, and expected behavior when VPN/pairing/account setup is missing. Static protection checks do not replace these device tests.
