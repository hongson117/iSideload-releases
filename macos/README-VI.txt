iSideload - CÀI LẦN ĐẦU TỪ macOS (USB)
Gói: isl-macos-universal.zip - cho Mac Apple Silicon và Intel, macOS 11 trở lên.
Trang chính thức: https://github.com/hongson117/iSideload-releases/releases/latest

TRONG GÓI
- Cai-iSideload.command: nhấp đúp để mở trình hướng dẫn trong Terminal.
- isl-mac: công cụ native Universal (arm64 + x86_64).
- iSideload.ipa: bản 1.2.1 build 34 chưa ký, đi kèm sẵn.
- SHA256SUMS.txt: checksum các tệp trong gói.
- ThirdPartyNotices.txt: thông tin giấy phép thư viện.

CHUẨN BỊ
1. Giải nén toàn bộ ZIP vào một thư mục. Không chạy công cụ ngay trong cửa sổ xem nội dung ZIP.
2. Cắm iPhone/iPad vào Mac bằng cáp truyền dữ liệu. Giữ iPhone mở khóa, màn hình sáng.
3. Mở Finder, chọn iPhone trong thanh bên. Bấm Trust/Tin cậy trên Mac và trên iPhone; nhập mật mã iPhone nếu được hỏi. Nếu Mac hỏi cho phép phụ kiện, chọn Allow.
4. Chuẩn bị Apple ID sẽ dùng để ký và gia hạn, cùng thiết bị nhận mã 2FA. Dùng tài khoản của người sử dụng iPhone.
5. iPhone cần iOS/iPadOS 17 trở lên để chạy iSideload. Bật Chế độ nhà phát triển khi iOS yêu cầu. Nếu chưa thấy mục này, thử cài trước rồi kiểm tra lại sau.

CÀI
6. Nhấp đúp Cai-iSideload.command. Terminal mở, nhấn Enter sau khi đã chuẩn bị xong.
7. Công cụ kiểm tra checksum, tìm iPhone qua dịch vụ USB có sẵn của macOS. Nếu cắm nhiều máy, chọn đúng số và UDID của máy muốn cài.
8. Nhập Apple ID, mật khẩu (không hiển thị khi gõ), rồi mã 2FA. Có thể nhập sms để yêu cầu mã qua SMS. Nhấn Enter tại bước 2FA để hủy.
9. Chờ ký và cài hoàn tất, không rút cáp hay khóa iPhone. Nếu Apple báo hết chứng chỉ, công cụ hỏi trước khi thu hồi; Enter để hủy mà không thu hồi chứng chỉ nào.
10. Khi thấy XONG: trên iPhone vào Cài đặt > Quyền riêng tư & Bảo mật > Chế độ nhà phát triển, bật và khởi động lại nếu cần. Sau đó Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị > tin cậy tài khoản nhà phát triển, rồi mở iSideload.

KHÔNG CẦN cài Homebrew, Xcode, Python, usbmuxd bên ngoài, RC Pair hay Tailscale cho lượt cài USB này. Công cụ không cần sudo/mật khẩu quản trị Mac. Gatekeeper có thể yêu cầu xác nhận của chủ máy, tùy cấu hình quản lý thiết bị.

NẾU macOS CHẶN CÔNG CỤ
Gói được build bằng GitHub Actions, có chữ ký ad-hoc để chạy trên Mac; chưa có Developer ID/notarization của Apple.
- Chỉ tải từ trang phát hành chính thức ở trên và đối chiếu checksum ZIP tại đó.
- Thử mở Cai-iSideload.command. Nếu thông báo bị chặn, mở System Settings > Privacy & Security, xem phần Security và chọn Open Anyway cho đúng công cụ vừa mở. Xác nhận rồi thử lại.
- Có thể cần xác nhận riêng cho isl-mac. Đọc nội dung cảnh báo để chắc đúng file trong thư mục bộ cài.
- Không cần tắt Gatekeeper toàn hệ thống. Nếu Mac do công ty quản lý không cho phép, liên hệ quản trị viên.
- Nếu Terminal báo permission denied do phần mềm giải nén làm mất quyền chạy: mở Terminal, gõ chmod +x (thêm một dấu cách), kéo file Cai-iSideload.command vào cửa sổ rồi Enter; lặp lại cho isl-mac. Sau đó mở lại .command.

SAU KHI CÀI
- iSideload tự xuất hiện trong tab Ứng dụng kèm hạn ký thật.
- Đăng nhập trong iSideload bằng tài khoản đã dùng để ký. Muốn tự gia hạn: cài LocalDevVPN từ App Store và làm theo mục Ghép nối máy này. iOS 27+ ghép nối ngay trong iSideload; iOS cũ cần file ghép nối tương thích từ máy tính.
- Trước khi hết hạn, dùng Làm mới iSideload hoặc Ký lại tất cả. Có thể thiết lập Phím tắt để tự mở app và LocalDevVPN khi cần.
- Muốn dùng máy này cài iSideload cho máy khác: Thiết bị > Cài cho iPhone khác; máy nhận cần iOS 27+ và cùng Wi-Fi.

KHẮC PHỤC LỖI
- Không thấy iPhone: đổi cáp/cổng USB, mở khóa, chọn thiết bị trong Finder, xác nhận Trust trên cả hai máy. Cáp chỉ sạc không dùng được.
- Không đọc được pairing record: hoàn tất Trust trong Finder trước, rồi mở lại .command.
- Không đăng nhập được Apple: kiểm tra tài khoản/mật khẩu/2FA, kết nối Internet và điều khoản developer.apple.com nếu là tài khoản mới. Không gửi mật khẩu cho người hỗ trợ.
- Hết chỗ app/App ID: gỡ bớt app tự ký hoặc chờ hạn App ID theo quy định của Apple. Đổi Apple ID không bảo đảm tăng số app trên máy.
- Cài xong chưa mở được: kiểm tra Developer Mode và VPN & Quản lý thiết bị trên iPhone.

QUYỀN RIÊNG TƯ
Mật khẩu được nhập trong Terminal và không ghi ra file bởi công cụ; dùng cho quá trình xác thực Apple. Công cụ không gửi mật khẩu lên VPS hoặc máy chủ của người phát hành. Cache anisette, khóa/chứng chỉ ký nằm trong ~/Library/Application Support/iSideload-Installer, thư mục riêng của tài khoản Mac hiện tại. Giữ bí mật thư mục này; xóa cache có thể khiến lần cài sau phải cấp chứng chỉ lại.

KIỂM CHỨNG
Build/test tự động trên macOS kiểm tra binary Universal, tự kiểm tra CLI, cú pháp launcher và checksum IPA/gói. Chưa xác nhận cài USB end-to-end trên Mac cá nhân có iPhone thật; khi báo lỗi, gửi nội dung lỗi đã loại bỏ dữ liệu riêng, phiên bản Mac/iOS, không gửi mật khẩu hoặc file khóa/chứng chỉ.

Tài liệu Apple:
https://support.apple.com/109054
https://support.apple.com/108643
https://support.apple.com/102445
