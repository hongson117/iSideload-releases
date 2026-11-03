# iSideload macOS — gói 1.2.5 RC2 — CÀI APP VÀ TỰ THIẾT LẬP FILE GHÉP ĐÔI

Gói Universal: Mac Apple Silicon + Intel, macOS 11+. iPhone/iPad cần iOS/iPadOS 17.4+ cho thiết lập Remote Pairing tự động.
**[Tải bộ cài macOS Universal](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc2/isl-macos-universal.zip)**

## TRONG GÓI

Cai-iSideload.command, isl-mac Universal, iSideload.ipa 1.2.5 build 10, README-VI.txt, ThirdPartyNotices.txt và SHA256SUMS.txt.
Không cần Homebrew, Xcode, Python, usbmuxd bên ngoài, RC Pair hay Tailscale cho lượt cài USB.

## CHUẨN BỊ

1. Giải nén toàn bộ ZIP vào một thư mục, giữ các file cạnh nhau.
2. Cắm iPhone bằng cáp dữ liệu, mở khóa, mở Finder và chọn thiết bị trong thanh bên.
3. Bấm Trust/Tin cậy trên Mac và trên iPhone, nhập mật mã iPhone nếu được hỏi. Nếu Mac hỏi cho phép phụ kiện, chọn Allow.
4. Khi cài từ đầu, chuẩn bị Apple ID sẽ dùng để ký/gia hạn và thiết bị nhận mã 2FA.

## CÁCH 1 — CÀI TỪ ĐẦU, APP CÓ SẴN FILE GHÉP ĐÔI

1. Nhấp đúp Cai-iSideload.command để mở Terminal. Công cụ kiểm tra checksum gói.
2. Chọn 1. Nếu có nhiều iPhone, chọn đúng số/UDID.
3. Nhập Apple ID, mật khẩu (ẩn khi gõ), mã 2FA nếu được hỏi. Có thể nhập sms để yêu cầu mã SMS; Enter trống tại bước 2FA để hủy.
4. Công cụ ký và cài app. Nếu Chế độ nhà phát triển chưa bật, làm theo hướng dẫn: Cài đặt > Quyền riêng tư & Bảo mật > Chế độ nhà phát triển > Bật. Giữ cáp, khởi động lại và xác nhận Bật trên iPhone khi được yêu cầu; xong nhấn Enter trên Mac.
5. Giữ iPhone mở khóa, đóng hẳn iSideload trong khi thiết lập. Công cụ chuẩn bị kết nối phát triển qua Wi-Fi, tạo Remote Pairing qua USB, xác minh với iPhone, chép vào app, đọc lại và xác minh lần cuối.
6. Chờ thông báo XONG: iSideload đã có file Remote Pairing… Không cần tự xuất/nhập file bằng idevice_pair hay ứng dụng khác.
7. Trên iPhone, tin cậy tài khoản nhà phát triển tại Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị nếu được yêu cầu.
8. Mở iSideload, đăng nhập cùng Apple ID, kết nối Wi-Fi có Internet. Cài/bật LocalDevVPN, quay lại Thiết bị > Kiểm tra kết nối thiết bị, rồi thử Làm mới iSideload.

## CÁCH 2 — ĐÃ CÓ iSIDELOAD, CHỈ THIẾT LẬP/SỬA GHÉP ĐÔI

1. Cắm iPhone, mở khóa và đóng hẳn iSideload.
2. Mở Cai-iSideload.command, chọn 2. Chế độ này không cần Apple ID/mật khẩu, không ký hay cài lại app.
3. Nếu có nhiều bản iSideload, chọn đúng bundle ID. Công cụ chỉ nhận họ bundle ID com.hongson117.isideload.
4. Làm theo hướng dẫn bật Chế độ nhà phát triển nếu cần, rồi chờ XONG.
5. Mở lại iSideload, bật LocalDevVPN và bấm Kiểm tra kết nối thiết bị.

File ghép đôi được tạo riêng cho đúng iPhone, không phải file dùng chung đóng gói sẵn trong ZIP. Bản ghi hiện có được dùng lại nếu iPhone vẫn chấp nhận; quá trình chép thử có kiểm tra và khôi phục file cũ nếu thất bại. Công cụ không xóa danh sách app hay tài khoản trong iSideload.
Xác minh USB của bộ cài khác với kiểm tra đường LocalDevVPN trong app. Cần bấm Kiểm tra kết nối thiết bị sau khi mở app để xác nhận đường tự gia hạn.

## NẾU CHƯA HOÀN TẤT

- Không thấy iPhone: kiểm tra cáp dữ liệu, mở khóa, mở Finder và bấm Trust/Tin cậy.
- App đã cài nhưng ghép đôi lỗi: giữ app, sửa nguyên nhân ghi trong Terminal, rồi chạy lại lựa chọn 2.
- Nếu Apple báo hết chỗ chứng chỉ, công cụ yêu cầu chọn và xác nhận trước khi thu hồi. Enter để hủy mà không thu hồi. Chứng chỉ bị thu hồi có thể làm các app đã dùng nó ngừng mở.
- Bộ cài không cần sudo hoặc mật khẩu quản trị Mac.

## NẾU GATEKEEPER CHẶN

Binary có chữ ký ad-hoc, chưa có Developer ID/notarization của Apple. Chỉ tải gói chính thức và đối chiếu checksum ZIP trên trang release.
- Mở file, rồi vào System Settings > Privacy & Security > Open Anyway cho đúng file vừa bị chặn. Trên macOS cũ: System Preferences > Security & Privacy > General. Có thể cần xác nhận riêng cho isl-mac.
- Không cần tắt Gatekeeper toàn hệ thống. Nếu Mac thuộc công ty và bị quản lý, làm theo quy định của quản trị viên.
- Nếu phần mềm giải nén làm mất quyền chạy: trong Terminal gõ chmod +x (kèm dấu cách), kéo đúng file Cai-iSideload.command vào rồi Enter; lặp lại cho isl-mac.

## DỮ LIỆU

Mật khẩu được nhập ẩn và không được công cụ ghi ra file; dùng để xác thực Apple. Bộ cài không gửi mật khẩu/file ghép đôi lên VPS của người phát hành. Cache anisette, khóa/chứng chỉ ký ở ~/Library/Application Support/iSideload-Installer, chỉ tài khoản Mac hiện tại truy cập. Giữ bí mật thư mục này.

## KIỂM CHỨNG

CI chạy kiểm thử chép/khôi phục file ghép đôi, launcher hai chế độ, hủy/EOF, checksum sai, binary Universal và CLI self-test trên Apple Silicon và Intel qua Rosetta khi có sẵn. Kiểm tra phần mềm không thay thế xác nhận cài USB đầu-cuối trên Mac với iPhone thật. Khi báo lỗi, gửi phiên bản macOS/iOS và nội dung lỗi, không gửi mật khẩu hoặc khóa riêng.

Tài liệu Apple:
https://support.apple.com/109054
https://support.apple.com/108643
https://support.apple.com/guide/mac-help/mh40617/mac


## Trong iSideload 1.2.3

- **Đã có file ghép đôi:** file còn trong app. Bật LocalDevVPN và bấm **Kiểm tra kết nối thiết bị** ngay ở đầu tab Thiết bị. Mở lại/cập nhật app đặt lại trạng thái kiểm tra, chưa cần tạo hay nhập lại file chỉ vì chưa kiểm tra ở lần mở mới.
- **VPN đã bật:** đây là bước chuẩn bị; nút kiểm tra thiết bị mới xác nhận kết nối tới iPhone.
- **Cài/cài lại LiveContainer:** chọn rõ Apple ID hoặc chứng chỉ .p12 đã nhập. Nguồn được giữ qua bước bật VPN và dùng cho chứng chỉ chuyển sang LiveContainer.
- **Nhiều bản LiveContainer:** dùng hướng dẫn lưu/nhập .p12 vào đúng bản trong app. Đổi nguồn ký có thể tạo bản khác; dữ liệu bản cũ không tự chuyển sang bản mới.

## Cập nhật phiên bản bằng tài khoản của bạn

Gói này kèm iSideload 1.2.5 có chức năng tải IPA mới từ GitHub, kiểm tra checksum rồi ký và cài đè bằng nguồn gia hạn của bản đang cài. Sau khi cài, đăng nhập cùng Apple ID đã dùng ký trên máy tính, chọn Tài khoản gia hạn trong tab Ứng dụng rồi thử Làm mới iSideload.

Vào Cài đặt → Cập nhật iSideload → Kiểm tra phiên bản mới ngay. Có thể bật Tự tải, ký và cập nhật khi mở app (mặc định tắt). Apple ID cần Remote Pairing và LocalDevVPN. Chứng chỉ có sẵn vẫn cần profile phù hợp và xác nhận cài của iOS. Mở lại app để kiểm tra phiên bản sau khi cài đè; iOS không bảo đảm cài âm thầm khi app đóng.

Nếu bản đầu được ký bằng tài khoản người hỗ trợ, vào Tài khoản → Thiết lập iSideload bằng tài khoản này để tạo bản Cá nhân của bạn trước. Cập nhật phiên bản giữ đúng App ID/Team đang cài; đổi chủ sở hữu là luồng riêng.

Từ build 10: bỏ chốt chặn 3 app theo lịch sử cục bộ; Apple/thiết bị quyết định quota. Xem [giải thích giới hạn](INSTALL-LIMITS.md). Chưa kiểm chứng cài đủ 6 app trên iPhone bằng hai tài khoản.
