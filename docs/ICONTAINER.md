# iContainer 0.1 — private device-validation preview

iContainer is an independent iOS variant of Sơn's iSideload. It adds an original
in-process arm64 IPA loader and keeps the existing Apple ID / imported-certificate
signing, device pairing, independent-app installation and self-refresh features.
This is not a renamed LiveContainer IPA or a port of the tvOS ZSign wrapper.

## Familiar sideloader features

The five tabs remain Ứng dụng, Nguồn, Thiết bị, Tài khoản and Cài đặt.
Tài khoản always exposes the add-account action, supports a second Apple ID and
further accounts, and has explicit re-login/main-account controls. A failed login
does not close the form or discard a previously stored password.

Cài cho iPhone khác is available beside the IPA picker in Ứng dụng and at the top
of Thiết bị. The inherited peer flow retains the iOS 27+ same-Wi-Fi requirement,
separate receiver pairing records, explicit signing-account choice and receiver
confirmation. It packs only the iContainer application bundle, never host account
data or guest working data. Hardware validation of this variant's peer flow is
still separate from the earlier iSideload hardware tests.

## State of verification

The CI artifact is unsigned. Build, archive validation, Mach-O transformation and
release-package checks do not establish that an app launches on a real iPhone.
The initial hardware gate is the included, original `iContainer-Demo.ipa`, then a
trusted third-party UIKit IPA, then SwiftUI/scene-based guests. Do not migrate an
existing LiveContainer installation or delete its data for this preview.

## Identity and storage

- Display name: iContainer; root bundle ID `com.hongson117.icontainer`.
- A separate installation and Keychain service from iSideload.
- Original IPA contents: `Library/Application Support/iContainer/<UUID>/Original.app`.
- Prepared copy: `Prepared.app`; guest working data: `Data/`.
- Pairing remains in `Documents/Storage/pairing.plist` for the host.
- Each import creates a new entry and new data; updating/migrating an existing
  LiveContainer guest is not implemented.
- Guest preparation never replaces `Data/` or the original imported bundle.

## First installation and smoke test

1. Sign `iContainer.ipa` and install it with an existing trusted desktop sideloader.
   Use a free slot; testing alongside iSideload + LiveContainer temporarily takes
   a third slot. Existing public iSideload USB installers do not yet deliver pairing
   to the new iContainer bundle ID.
2. Enable Developer Mode/trust as usual. In iContainer → Tài khoản add the signer.
   For self-refresh with Apple ID, import a compatible Remote Pairing record and
   enable LocalDevVPN; verify the device connection. Alternatively import the
   P12/provisioning profiles used to sign the host.
3. Ứng dụng → Mở Container → Nhập IPA → select `iContainer-Demo.ipa`.
4. Chuẩn bị → explicitly choose the host's signing identity. A certificate
   mismatch is rejected. If the desktop sideloader used a different certificate,
   refresh iContainer using the selected Apple ID first, reopen, then prepare the
   demo; or import the exact original P12. Never revoke certificates to fix this.
5. Chạy → acknowledge shared-process access → Đóng → reopen iContainer from the
   home screen within ten minutes. The one-shot ticket is consumed before loading.
6. Expect a demo screen with its original guest bundle ID, a guest Documents path
   under `<UUID>/Data/Documents`, and visit count 1. Return to iContainer, repeat
   launch, and expect visit count 2.
7. Refresh the entire iContainer host and repeat steps 4–6. If the signing
   certificate changes, re-prepare guests using the new matching certificate.

## Boundaries of this preview

- Ordinary arm64 iPhone/iPad binaries only. Reject encrypted FairPlay apps,
  tvOS/macOS/simulator binaries, arm64e-only binaries and unsupported Mach-O layout.
- Extensions and Watch bundles are rejected, not silently removed.
- Framework dependency loading is best effort. CFBundle-based asset lookup,
  SwiftUI scenes, app URL callbacks, app groups, Keychain/preferences routing and
  app-specific private entitlements are not guaranteed for arbitrary guests.
- The host's UIKit/SwiftUI process is not initialized in guest mode. Switching
  between host and guest requires closing and reopening the app.
- Guests share the host process and OS sandbox. Directory routing is not secure
  isolation. Trusted guest code can potentially access host files/credentials;
  do not treat this preview as a sandbox for untrusted IPAs.
- iOS controls background execution. Self-refresh still needs a valid signer and,
  for the Apple ID device-install path, pairing plus reachable loopback VPN.
- This does not remove Apple's signature expiry or device limits.
- Keep preview artifacts private until dependency distribution/relinking
  obligations have been addressed. See `ICONTAINER-PROVENANCE.md`.

## Build

`python3 scripts/configure_icontainer.py`, then `xcodegen generate --spec
project-icontainer.yml`; build scheme `iContainer` with the shared Rust static
library. The `iContainer private preview` workflow builds the IPA and original
demo guest, runs regression/security tests and audits the final package.
