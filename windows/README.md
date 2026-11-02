# iSideload – cài lần đầu từ Windows / First install from Windows

> ⚠️ Chưa được kiểm thử trên máy Windows thật (bản .exe được build chéo từ Linux). / Not yet tested on a real Windows PC (the .exe is cross-compiled from Linux).

## Tiếng Việt
**Chuẩn bị**
1. Cài **Apple Devices** (Microsoft Store, Windows 10/11) hoặc **iTunes** bản tải từ apple.com — để có driver và dịch vụ *Apple Mobile Device Service*.
2. Cáp USB tốt. Cắm iPhone, **mở khóa**, bấm **"Tin cậy máy tính này"**, nhập mật mã. Mở Apple Devices/iTunes 1 lần để chắc máy thấy iPhone.
3. iOS 16 trở lên: bật **Chế độ nhà phát triển** (Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển), khởi động lại và xác nhận. Nếu chưa thấy mục này, làm bước 4 trước rồi quay lại.

**Cài**

4. Tải `isl-windows.zip` từ trang Release, giải nén, bấm đúp **`Cai-iSideload.bat`**.
5. Nhập Apple ID + mật khẩu (ẩn, không lưu ra file), rồi mã **2FA** 6 số (hoặc gõ `sms`). Chờ đến khi báo **XONG**.
6. Trên iPhone: Cài đặt › Cài đặt chung › **VPN & Quản lý thiết bị** › chọn Apple ID › **Tin cậy**.
7. Mở iSideload. Từ đây dùng không dây: bật **LocalDevVPN** (ký lại ngay trên máy) hoặc **Tailscale** (cài/ký lại từ xa). Cài bằng chứng chỉ có sẵn (.p12) không cần VPN.

## English
**Prerequisites**
1. Install **Apple Devices** (Microsoft Store, Windows 10/11) or **iTunes** from apple.com — provides the drivers and *Apple Mobile Device Service*.
2. A good USB cable. Plug in the iPhone, **unlock** it, tap **"Trust This Computer"** and enter the passcode. Open Apple Devices/iTunes once to make sure the iPhone is seen.
3. iOS 16+: turn on **Developer Mode** (Settings › Privacy & Security › Developer Mode), restart and confirm. If the option is missing, do step 4 first, then come back.

**Install**

4. Download `isl-windows.zip` from the Release page, unzip, double-click **`Cai-iSideload.bat`**.
5. Enter your Apple ID + password (hidden, never written to disk), then the 6-digit **2FA** code (or type `sms`). Wait for **XONG** (done).
6. On the iPhone: Settings › General › **VPN & Device Management** › your Apple ID › **Trust**.
7. Open iSideload. From now on go wireless: **LocalDevVPN** (on-device re-signing) or **Tailscale** (remote install/refresh). Imported-certificate (.p12) installs need no VPN.

Free Apple ID limits: 3 apps per device, 10 App IDs / 7 days, apps expire after 7 days (iSideload re-signs them).

## Build
`cargo build --release --target x86_64-pc-windows-gnu` in this folder → `isl-cli.exe`. Put it next to `Cai-iSideload.bat` and `iSideload.ipa`.
