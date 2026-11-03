# iSideload Windows — cài từ đầu và tự thiết lập file ghép đôi

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

## Dùng dòng lệnh

- `isl-cli.exe iSideload.ipa`: ký/cài và thiết lập ghép đôi.
- `isl-cli.exe --pair-only`: chỉ thiết lập ghép đôi cho app đã có.
- `isl-cli.exe --list-devices`: xem iPhone qua USB.
- `isl-cli.exe --self-test`: kiểm tra ngoại tuyến, không cần iPhone hay tài khoản.

Apple ID miễn phí thường có profile 7 ngày. Xem hạn ký thật trong iSideload; gia hạn trước ngày hết hạn. Quy trình Apple ID mới vẫn có thể cần chấp nhận điều khoản của Apple.
