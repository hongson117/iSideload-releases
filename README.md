# iSideload

## Phát hành 1.2.3 RC1

Mã nguồn được giữ trong repository private. Bản IPA công khai và hướng dẫn cài đặt nằm tại https://github.com/hongson117/iSideload-releases/releases/latest . Không đưa Git bundle, source ZIP, pairing file hay thông tin VPS/MCP lên repository phát hành.

## Cài lần đầu từ macOS

Tải `isl-macos-universal.zip` tại trang release, giải nén và mở `Cai-iSideload.command`. Gói có công cụ native Universal cho Apple Silicon + Intel (macOS 11+), kèm IPA 1.2.3 build 36. Dùng dịch vụ USB có sẵn của Apple; không cần Homebrew/Xcode. Cắm cáp dữ liệu, mở Finder và xác nhận Trust trên cả hai máy, rồi nhập Apple ID/2FA trong Terminal.

Hướng dẫn đầy đủ và xử lý Gatekeeper: `macos/README-VI.txt`. Công cụ chưa có Developer ID/notarization; không hướng dẫn tắt Gatekeeper toàn hệ thống. Build kiểm tra CLI/binary/checksum, chưa thay cho cài USB với iPhone thật.

- iSideload tự xuất hiện trong tab Ứng dụng ngay sau lần mở đầu, đọc hạn ký thật từ profile và giữ bản ghi qua các lần mở/làm mới danh sách.
- Thiết lập lần đầu có các nút tới Tài khoản, LocalDevVPN và Ghép nối máy này. Máy hỗ trợ vẫn cài được cho máy mới qua Wi-Fi mà không cần tự ghép nối.
- Làm mới iSideload đóng gói bản đang chạy, giữ nguyên bundle ID để cài đè thay vì nối lặp Team ID. Ký lại tất cả xử lý iSideload cuối cùng; thao tác tiếp tục sau khi bật VPN giữ nguyên phạm vi đã chọn.
- CI chạy Rust tests, Swift lifecycle tests và kiểm tra IPA không chứa source/khóa riêng/DWARF/local symbols trước khi tạo artifact. Các giới hạn bảo vệ được ghi trong `docs/RELEASE-HARDENING.md`.
- Người dùng đã xác nhận cài thành công từ máy hỗ trợ sang máy mới với bản 1.2.0 build 31. Luồng tự gia hạn mới của 1.2.1 cần tiếp tục xác nhận trên thiết bị thật; kết quả CI không thay cho kiểm thử phần cứng.

Clean-room iPhone/iPad sideloader: sign IPAs with a **free Apple ID** and install them on the **same device**, no computer after a one-time pairing file.

- `core/` — Rust core (C ABI `isl_call`): Apple ID + 2FA (isideload, vendored with anisette cookie/headers/failover fixes from TVSideload), free-team signing with bundle-ID team suffix, install via lockdown → AFC → installation_proxy (idevice `TcpProvider` at 10.7.0.1 with the imported pairing file).
- `ios/iSideload` — SwiftUI app (Vietnamese UI).
- `ios/Tunnel` — optional NEPacketTunnelProvider loopback (reflects packets to 10.7.0.1). **Not shipped**: free Apple IDs cannot sign Network Extensions; the app uses the free App Store app **LocalDevVPN** instead (same approach SideStore/AltLoad use).

## Use
1. Install iSideload once (Sideloadly/AltServer/another signer); enable Developer Mode.
2. Prefer the Windows/macOS USB installer to create and deliver Remote Pairing automatically. For an existing install choose mode 2, or import a compatible Remote Pairing export. On iOS 26.4+, do not assume an older Lockdown record works over loopback VPN.
3. Install/enable LocalDevVPN, then use **Thiết bị → Kiểm tra kết nối thiết bị** at the top. A stored pairing file or enabled VPN alone does not prove the device handshake succeeded.
4. **Tài khoản**: sign in (2FA). **Ứng dụng**: pick an IPA → Ký và cài. Refresh before 7 days.

Free-account limits: 3 active sideloaded apps (incl. iSideload), 10 App IDs / 7 days, 7-day profiles, app extensions each consume an App ID.

Build: GitHub Actions (`.github/workflows/build.yml`) → unsigned `iSideload.ipa` artifact.

## No activation code
iSideload is **free and needs no activation code** — the ISL- license gate was removed. The app opens straight to the main screen.

## Features
- Self-refresh (re-signs its own bundle), `isideload://refresh` / `isideload://refresh-apps` links and Shortcuts actions for a daily re-sign automation.
- LiveContainer install/reinstall requires an explicit Apple ID or imported .p12 choice. The immutable install plan preserves that choice across VPN hand-off. Certificate transfer uses the selected signer; the selected LiveContainer identity remains pinned even if an older copy is refreshed. Multiple known copies use a manual certificate-import sheet to avoid an ambiguous shared URL scheme.

## Hardening
- Release: Rust `strip = true`, `panic = "abort"`; Xcode strips all symbols.

## Cài cho iPhone khác (bản thử nghiệm)

Máy hỗ trợ đã cài iSideload có thể ghép nối và cài iSideload cho iPhone/iPad mới chạy iOS/iPadOS 27+ ở cùng mạng Wi-Fi. Máy nhận không cần RC Pair, Tailscale hoặc máy tính cho lượt cài trực tiếp này.

1. Trên máy hỗ trợ, đăng nhập Apple ID tại tab **Tài khoản**.
2. Cả hai máy bật Wi-Fi, cùng mạng không cách ly thiết bị. Máy nhận bật **Chế độ nhà phát triển**, mở khóa. Giữ iSideload trên máy hỗ trợ ở phía trước; tắt VPN nếu nó chặn mạng cục bộ.
3. Máy hỗ trợ: **Thiết bị → Cài cho iPhone khác → Ghép nối iPhone mới**.
4. Máy nhận: **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển → Thiết bị khác**, chọn tên `iSideload - Cai may khac …`, nhập mã 6 số đang hiện trên máy hỗ trợ.
5. Trên máy hỗ trợ, kiểm tra tên/IP/UDID máy nhận, chọn Apple ID ký và xác nhận **Cài iSideload lên máy này**. Hoàn tất 2FA nếu Apple yêu cầu. Giữ cả hai máy mở khóa đến khi báo thành công.
6. Máy nhận: tin cậy nhà phát triển ở **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị**, mở iSideload và đăng nhập Apple ID riêng. Muốn tự ký lại trên máy nhận thì cài LocalDevVPN và ghép nối ngay trong iSideload như thông thường.

Bản ghi máy nhận lưu riêng trong `Storage/peer-pairings/`, với danh tính ghép nối riêng, không ghi đè `Storage/pairing.plist` của máy hỗ trợ. Danh sách app của máy hỗ trợ không ghi nhận các app cài lên máy nhận. Có thể xuất bản ghi của máy nhận qua nút chia sẻ; chỉ gửi cho máy chủ/người quản trị tin cậy. Chưa tích hợp tự động đăng ký bản ghi với VPS.

Đây là bản thử nghiệm cần kiểm tra trên **hai thiết bị thật**. CI kiểm tra biên dịch và các quy tắc tách bản ghi, hủy ghép nối, giới hạn địa chỉ máy nhận, đóng gói IPA; CI không xác nhận việc ghép nối/cài trên phần cứng. Nếu máy nhận đổi IP Wi-Fi, hãy ghép nối lại. Chế độ này chưa hỗ trợ hai máy ở hai mạng khác nhau.


## Cài lần đầu từ Windows / First install from Windows
Tải `isl-windows.zip` ở [Release mới nhất](https://github.com/hongson117/iSideload/releases/latest), giải nén, chạy `Cai-iSideload.bat`. Hướng dẫn từng bước (VI + EN): [windows/README.md](windows/README.md).
Download `isl-windows.zip` from the [latest release](https://github.com/hongson117/iSideload/releases/latest), unzip, run `Cai-iSideload.bat`. Step-by-step guide (VI + EN): [windows/README.md](windows/README.md). *Not yet tested on a real Windows PC.*
