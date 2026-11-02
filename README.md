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

## No activation code
iSideload is **free and needs no activation code** — the ISL- license gate was removed. The app opens straight to the main screen.

## Features
- Self-refresh (re-signs its own bundle), `isideload://refresh` / `isideload://refresh-apps` links and Shortcuts actions for a daily re-sign automation.
- Built-in LiveContainer install + **certificate export/auto-push**: after every successful re-sign, iSideload opens LiveContainer briefly to hand it the new certificate (JIT-less mode keeps working).

## Hardening
- Release: Rust `strip = true`, `panic = "abort"`; Xcode strips all symbols.


## Cài lần đầu từ Windows / First install from Windows
Tải `isl-windows.zip` ở [Release mới nhất](https://github.com/hongson117/iSideload/releases/latest), giải nén, chạy `Cai-iSideload.bat`. Hướng dẫn từng bước (VI + EN): [windows/README.md](windows/README.md).
Download `isl-windows.zip` from the [latest release](https://github.com/hongson117/iSideload/releases/latest), unzip, run `Cai-iSideload.bat`. Step-by-step guide (VI + EN): [windows/README.md](windows/README.md). *Not yet tested on a real Windows PC.*
