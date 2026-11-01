# Third-party notices

TV Sideload is MIT-licensed. It is built on these projects, whose licenses apply to their code:

- **idevice** — https://github.com/jkcoxson/idevice (MIT). Used for RemotePairing (Apple TV PIN pairing), the RSD/CoreDevice tunnel, AFC and installation_proxy. Fetched by Cargo at a pinned git revision.
- **isideload** — https://crates.io/crates/isideload 0.4.6 (MIT), © Nicholas Sharp and contributors. Used for Apple ID sign-in, anisette, developer-portal APIs and app signing. Vendored in `core/vendor/isideload` with its LICENSE; TV Sideload's tvOS changes are listed in `core/vendor/isideload/TVSIDELOAD_PATCHES.md` and `core/patches/isideload-tvos.patch` (MIT).
- Other Rust crates are pulled from crates.io under their own (MIT / Apache-2.0 / BSD) licenses; run `cargo about` or see `core/Cargo.lock` for the full list.

No code or assets from AltStore, SideStore or AltLoad are included.
