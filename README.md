# iSideload

Clean-room iPhone/iPad sideloader: sign IPAs with a **free Apple ID** and install them on the **same device**, no computer after a one-time pairing file.

- `core/` — Rust core (C ABI `isl_call`): Apple ID + 2FA (isideload, vendored with anisette cookie/headers/failover fixes from TVSideload), free-team signing with bundle-ID team suffix, install via lockdown → AFC → installation_proxy (idevice `TcpProvider` at 10.7.0.1 with the imported pairing file).
- `ios/iSideload` — SwiftUI app (Vietnamese UI).
- `ios/Tunnel` — optional NEPacketTunnelProvider loopback (reflects packets to 10.7.0.1). **Not shipped**: free Apple IDs cannot sign Network Extensions; the app uses the free App Store app **LocalDevVPN** instead (same approach SideStore/AltLoad use).

## Use
1. Install iSideload once (Sideloadly/AltServer/another signer); enable Developer Mode.
2. Make a pairing file on a computer (`idevice_pair`, iloader, or Jitterbug pair) → AirDrop → **Thiết bị → Nhập file ghép nối**.
3. Install LocalDevVPN from the App Store, turn it on.
4. **Tài khoản**: sign in (2FA). **Ứng dụng**: pick an IPA → Ký và cài. Refresh before 7 days.

Free-account limits: 3 active sideloaded apps (incl. iSideload), 10 App IDs / 7 days, 7-day profiles, app extensions each consume an App ID.

Build: GitHub Actions (`.github/workflows/build.yml`) → unsigned `iSideload.ipa` artifact.

## Activation & hardening
- `ios/iSideload/License/` = shared LicenseKit (app id `isideload`, codes `ISL-…`, server tvsideload-license worker). `LicenseGate` wraps the whole UI; `requireValid()` before every sensitive op.
- The Rust core re-verifies the signed license (Ed25519, device_id, app, exp, 7-day offline grace) on every sensitive op (`sign_in`, `device`, `apps`, `install`, `certs`, `revoke_cert`). Public key is XOR-masked; no secrets in the IPA.
- Integrity: core is built with the commit SHA and refuses to run if the app's `ISLGitSHA` differs (detects swapped core/app). Code-signature pinning is impossible because every user re-signs the IPA.
- Release: Rust `strip = true`, `panic = "abort"`; Xcode strips all symbols.
