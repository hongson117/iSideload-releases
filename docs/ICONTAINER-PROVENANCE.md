# iContainer component provenance

New iContainer files were implemented directly in this branch. No LiveContainer
source tree, LiveContainerTV source files or ZSign wrapper were copied into the
runtime. Prior inspection of those projects informed the feasibility discussion;
this is not a claim of an independently audited clean-room process.

| Component | Origin / status |
| --- | --- |
| `ios/iContainer/ICRuntime.*` | New implementation: one-shot boot ticket, Objective-C bundle/directory routing, arm64 entry transfer, return UI. |
| `ios/iContainer/Container*.swift` | New host manager and SwiftUI interface. |
| `core/src/container*.rs` | New bounded archive importer, transactional preparation and Mach-O transformer. |
| `tests/ContainerDemo` | Original UIKit smoke guest, no third-party IPA bundled. |
| Existing SwiftUI host / Rust bridge | Sơn's iSideload source at base commit `d42611d68d571c45c31b0d9fad629f8999867816`, with variant-specific identity changes. |
| Vendored `isideload` 0.4.6 | Existing upstream MIT component and local changes; retain LICENSE and notices. |
| `idevice` | Existing pinned upstream dependency; retain resolved license/notices. |
| `apple-codesign-quick` 0.1.0 | Existing LGPL-2.1-or-later signing dependency, checksum `519defc726db80b8a43836bbd6f69eb606a42783db799716a103436042593f0b`; repository `https://github.com/Dadoum/apple-crates`. |
| Remaining Rust dependencies | Resolve from Cargo.lock; CI bundles dependency license documents in ThirdPartyNotices.txt. |

The use of an original loader does not remove obligations of existing
dependencies. In particular, static linkage of LGPL components needs an
appropriate source/relinking distribution arrangement before a public binary
release. A notices file alone does not establish compliance. This branch creates
private CI artifacts; it does not publish a release or make the private source
repository public. A full transitive dependency/license audit remains a public
release gate. Do not label this artifact "all original" or "no open-source
obligations".

LiveContainerTV was read in its own checkout for context. Its `ZSign/zsigner.h`
retains a LiveContainer header; provenance of that existing TV component has not
been concluded or changed by this work. No files in the TV project were modified.
