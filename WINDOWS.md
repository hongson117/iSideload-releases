# iSideload Windows — cài từ đầu và tự thiết lập file ghép đôi

**[Tải bộ cài Windows](https://raw.githubusercontent.com/hongson117/iSideload-releases/main/isl-windows.zip)**

Bộ cài Windows 1.2.2 có hai chế độ: cài iSideload kèm Remote Pairing, hoặc chỉ sửa ghép đôi cho app đã cài bằng Sideloadly/công cụ khác. Hỗ trợ Windows 10/11 x64 và iPhone/iPad chạy iOS/iPadOS 17.4 trở lên.

## Chuẩn bị

1. Cài Apple Devices từ Microsoft Store hoặc iTunes từ Apple để có driver và Apple Mobile Device Service.

2. Cắm iPhone bằng cáp dữ liệu, mở khóa, bấm **Tin cậy máy tính này** và nhập mật mã trên iPhone. Mở Apple Devices/iTunes để chắc chắn máy tính đã nhận đúng iPhone.

3. Tải ZIP chính thức, chọn **Extract All / Giải nén tất cả**. Giữ nguyên các file cạnh nhau. Không chạy BAT trực tiếp bên trong cửa sổ ZIP.

## Cách 1 — cài từ đầu, mở app đã có sẵn file ghép đôi

1. Mở **Cai-iSideload.bat**, chọn **1**.

2. Nhập Apple ID sẽ dùng để ký và gia hạn trên iPhone, mật khẩu được ẩn, rồi mã 2FA nếu Apple yêu cầu.

3. Công cụ ký và cài iSideload qua USB. Nếu có nhiều iPhone, phải chọn đúng số thiết bị.

4. Nếu Chế độ nhà phát triển chưa bật, công cụ hướng dẫn mở **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**. Bật, khởi động lại và xác nhận trên iPhone. Giữ cáp; nhấn Enter trên máy tính sau khi hoàn tất. Công cụ tự tìm lại đúng iPhone.

5. Giữ máy mở khóa và đóng hẳn iSideload trong lúc công cụ tạo Remote Pairing. Công cụ chuẩn bị và kiểm tra cấu hình kết nối phát triển qua Wi-Fi, xác minh bản ghi với iPhone, chép vào iSideload, đọc lại và xác minh lần cuối.

6. Chỉ khi hiện **XONG: iSideload đã có file Remote Pairing…** thì bước này mới hoàn tất. Không cần xuất/nhập file ghép đôi bằng tay.

7. Trên iPhone, tin cậy tài khoản nhà phát triển tại **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị** nếu được yêu cầu.

8. Mở iSideload và đăng nhập cùng Apple ID để gia hạn. Kết nối Wi-Fi có Internet, cài **LocalDevVPN** từ App Store, bật VPN, quay lại **Thiết bị → Kiểm tra kết nối thiết bị**, rồi thử **Làm mới iSideload**.

Máy tính xác minh ghép đôi qua USB; bước kiểm tra trong app xác nhận thêm đường LocalDevVPN hoạt động sau khi rút cáp. Tailscale không cần cho cài lần đầu qua cáp hoặc tự gia hạn bằng LocalDevVPN.

## Cách 2 — đã có iSideload, chỉ bổ sung/sửa ghép đôi

1. Cắm iPhone qua USB, mở khóa và đóng hẳn iSideload.

2. Mở **Cai-iSideload.bat**, chọn **2**.

3. Công cụ tìm iSideload đã cài. Nếu có nhiều bản, chọn đúng bundle ID. Chế độ này không yêu cầu Apple ID/mật khẩu, không ký lại hay cài lại app.

4. Làm theo hướng dẫn bật Chế độ nhà phát triển nếu cần; chờ công cụ xác minh và báo XONG.

5. Mở lại iSideload, bật LocalDevVPN và bấm **Kiểm tra kết nối thiết bị**.

Công cụ dùng lại bản ghi Remote Pairing trong app nếu iPhone vẫn chấp nhận. Khi cần thay file, bản cũ được giữ trong lúc chép thử và được khôi phục nếu kiểm tra dữ liệu thất bại. Công cụ chỉ thay file ghép đôi, không xóa danh sách app hay tài khoản trong iSideload.

## Khi chưa hoàn tất

- Không thấy iPhone: kiểm tra cáp dữ liệu, mở khóa và xác nhận Apple Devices/iTunes đã nhận máy.

- App đã cài nhưng ghép đôi lỗi: giữ app, sửa nguyên nhân ghi trong cửa sổ rồi chạy lại **chế độ 2**.

- Nếu đã tự đổi bundle ID sang tên khác trong Sideloadly, chế độ tự tìm chỉ nhận họ bundle ID `com.hongson117.isideload`.

- Mật khẩu Apple ID không được lưu ra file. Bộ đệm chứng chỉ/anisette của công cụ ở `%LOCALAPPDATA%\iSideload-win` là dữ liệu riêng, không chia sẻ. File ghép đôi được tạo khi chạy cho đúng iPhone, không được đóng gói sẵn trong ZIP.

- Bộ cài kiểm tra SHA-256 các file trước khi chạy. Tải ZIP từ release chính thức và đối chiếu checksum ngoài ZIP nếu cần. EXE chưa ký Authenticode nên Windows có thể hiện cảnh báo nhà phát hành chưa xác định.

- CI kiểm tra build Windows, chế độ tự kiểm tra, việc chép file và khôi phục khi USB bị ngắt bằng mô phỏng. Kiểm thử tự động không thay thế xác nhận cài USB từ đầu trên iPhone thật.

## Kiểm chứng trên thiết bị thật

Đã xác nhận trên iPhone thật ngày 03/11/2026: Windows lựa chọn **2**, dùng lại bản ghi Remote Pairing hiện có, đọc lại/xác minh qua USB, sau đó người dùng mở iSideload và kiểm tra LocalDevVPN thành công. Lượt này không ký/cài lại app; nhánh tạo bản ghi mới, cài từ đầu bằng lựa chọn 1 và USB trên Mac vẫn cần xác nhận.

## Dùng dòng lệnh

- `isl-cli.exe iSideload.ipa`: ký/cài và thiết lập ghép đôi.

- `isl-cli.exe --pair-only`: chỉ thiết lập ghép đôi cho app đã có.

- `isl-cli.exe --list-devices`: xem iPhone qua USB.

- `isl-cli.exe --self-test`: kiểm tra ngoại tuyến, không cần iPhone hay tài khoản.

Apple ID miễn phí thường có profile 7 ngày. Xem hạn ký thật trong iSideload; gia hạn trước ngày hết hạn. Quy trình Apple ID mới vẫn có thể cần chấp nhận điều khoản của Apple.


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
