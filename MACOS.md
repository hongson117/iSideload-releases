# Cài iSideload lần đầu từ macOS

**[Tải bộ cài macOS Universal](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.1/isl-macos-universal.zip)** — dùng chung cho Mac Apple Silicon và Intel, macOS 11 trở lên.

Gói đã có công cụ native, IPA 1.2.1, launcher `Cai-iSideload.command`, hướng dẫn tiếng Việt, thông tin giấy phép và checksum. Không cần cài Homebrew, Xcode, Python hay một dịch vụ usbmuxd bên ngoài.

## 1. Kết nối iPhone

1. Tải ZIP từ link trên và **giải nén toàn bộ**.
2. Cắm iPhone/iPad bằng **cáp truyền dữ liệu**, giữ mở khóa và màn hình sáng.
3. Mở **Finder**, chọn iPhone trong thanh bên. Bấm **Trust/Tin cậy trên Mac và trên iPhone**, nhập mật mã iPhone nếu được hỏi. Nếu Mac hỏi cho phép phụ kiện, chọn Allow. [Hướng dẫn Trust của Apple](https://support.apple.com/109054).
4. Nếu Finder yêu cầu cập nhật phần mềm hỗ trợ iPhone, hoàn tất cập nhật chính thức của Apple trước. Nếu không thấy thiết bị, kiểm tra cáp/cổng USB và mở khóa máy. [Apple: Mac không nhận iPhone](https://support.apple.com/108643).

iPhone/iPad cần iOS/iPadOS 17+ để chạy iSideload. Chế độ nhà phát triển phải được bật trước khi mở app. Nếu chưa thấy mục đó, thử hoàn tất cài lần đầu rồi kiểm tra lại.

## 2. Chạy bộ cài

1. Trong thư mục vừa giải nén, nhấp đúp **`Cai-iSideload.command`**. Terminal mở.
2. Nhấn Enter sau khi đã cắm cáp và tin cậy thiết bị.
3. Launcher kiểm tra checksum rồi tìm thiết bị USB. Nếu có nhiều máy, chọn đúng số/UDID; có thể rút các máy không dùng để tránh nhầm.
4. Nhập **Apple ID sẽ dùng để ký/gia hạn**, mật khẩu và mã **2FA**. Mật khẩu không hiện khi gõ. Nhập `sms` để yêu cầu mã SMS nếu cần; Enter trống ở bước 2FA để hủy.
5. Chờ ký và cài đến khi thấy **XONG**; không rút cáp hoặc khóa iPhone giữa chừng.

Nếu hết chỗ cấp chứng chỉ, công cụ hiển thị danh sách và hỏi trước khi thu hồi. Chỉ chọn khi bạn hiểu app đã ký bằng chứng chỉ đó có thể ngừng mở. Enter để hủy mà không thu hồi.

## 3. Mở iSideload trên iPhone

1. **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**: bật, khởi động lại và xác nhận nếu iOS yêu cầu.
2. **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị**: chọn tài khoản nhà phát triển và tin cậy.
3. Mở iSideload. App tự xuất hiện trong tab **Ứng dụng**, kèm hạn ký thật.
4. Để tự gia hạn: đăng nhập cùng tài khoản ký trong iSideload, cài LocalDevVPN và làm theo **Ghép nối máy này**. iOS 27+ ghép nối ngay trong app; iOS cũ cần bản ghi tương thích tạo từ máy tính.

Có thể rút cáp sau khi hoàn tất. Lượt cài USB không cần RC Pair, Tailscale hay LocalDevVPN; LocalDevVPN phục vụ ký/cài trên chính iPhone sau đó.

## Nếu Gatekeeper chặn công cụ

Bộ cài được build trên GitHub Actions, có chữ ký ad-hoc cho binary Universal; **chưa có Developer ID/notarization của Apple**. macOS có thể yêu cầu xác nhận.

- Đối chiếu checksum ZIP từ `SHA256SUMS.txt` trên trang release và chỉ dùng gói chính thức.
- Thử mở launcher. Nếu bị chặn, vào **System Settings → Privacy & Security**, tìm thông báo cho đúng file vừa mở, chọn **Open Anyway** và xác nhận. Có thể cần chấp thuận riêng cho `isl-mac`.
- Trên macOS cũ, mục này mang tên **System Preferences → Security & Privacy**.
- Không cần tắt Gatekeeper toàn hệ thống. Nếu máy thuộc công ty và không cho mở, liên hệ quản trị viên. [Apple: mở ứng dụng bằng ngoại lệ bảo mật](https://support.apple.com/guide/mac-help/mh40617/mac).
- Nếu phần mềm giải nén làm mất quyền chạy: trong Terminal, gõ `chmod +x ` rồi kéo đúng file `Cai-iSideload.command` vào và Enter; lặp lại cho `isl-mac`.

## Dữ liệu và giới hạn kiểm tra

Mật khẩu được nhập trong Terminal, không được công cụ ghi ra file hoặc gửi lên VPS/máy chủ của người phát hành. Cache anisette và khóa/chứng chỉ ký lưu trong `~/Library/Application Support/iSideload-Installer`; giữ bí mật thư mục này. Không gửi mật khẩu, `.p12` hoặc cache cho người hỗ trợ.

Build tự động kiểm tra hai kiến trúc, tự kiểm tra CLI, cú pháp launcher, chữ ký ad-hoc và checksum. **Chưa có xác nhận cài USB end-to-end trên Mac cá nhân với iPhone thật.** Nếu gặp lỗi, gửi phiên bản macOS/iOS và nội dung lỗi đã loại bỏ dữ liệu riêng.
