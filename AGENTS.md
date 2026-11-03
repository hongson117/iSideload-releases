# Hướng dẫn cho AI hỗ trợ cài iSideload

Áp dụng khi người dùng yêu cầu cài hoặc sửa ghép đôi iSideload từ repo này. Đây là repo phân phối binary và tài liệu; mã nguồn app ở repo private. Nếu chỉ sửa tài liệu, không tự chạy bộ cài.

1. Đọc `README.md`, `AI-INSTALL.md`, `INSTALLERS.json`, rồi `WINDOWS.md` hoặc `MACOS.md` đúng hệ điều hành.
2. Xác minh công cụ đang thao tác trên máy Windows/Mac thật của người dùng. Không coi hệ điều hành của cloud/sandbox là hệ điều hành máy đang cắm iPhone. Nếu không có quyền thao tác local, cung cấp bước cho người dùng làm; không tuyên bố đã cài từ cloud.
3. Gói public được phép tải: `isl-windows.zip`, `isl-macos-universal.zip`, và metadata/checksum trong repo hoặc URL GitHub Releases của đúng phiên bản. Dùng SHA-256 trong `INSTALLERS.json` để kiểm tra ZIP trước khi chạy. Không bỏ qua checksum lỗi.
4. Giải nén toàn bộ vào thư mục mới. Windows dùng `Cai-iSideload.bat`; Mac dùng `Cai-iSideload.command`. Mở Terminal/console tương tác để người dùng thấy và nhập trực tiếp.
5. Người dùng muốn **cài từ đầu**: chọn **1**. Người dùng đã có iSideload, chỉ cần thiết lập/sửa ghép đôi: chọn **2**. Chỉ hỏi chọn chế độ nếu mục tiêu chưa rõ; có thể chuẩn bị tải/xác minh gói trong lúc chờ.
6. Mật khẩu Apple ID, 2FA và mật mã iPhone do người dùng nhập trực tiếp vào đúng giao diện của bộ cài/iPhone. Không yêu cầu dán vào chat, ghi vào script, log hoặc commit. Không đăng tải file ghép đôi, `.p12` hay cache chứng chỉ.
7. Người dùng xử lý Tin cậy, Chế độ nhà phát triển, khởi động lại và xác nhận nhà phát triển trên iPhone. Theo dõi kết quả; không gửi phím tự động để đồng ý hộ các bước chứa mật mã hoặc lựa chọn thu hồi chứng chỉ.
8. Không mặc định gỡ app, xóa dữ liệu, reset trust hay thu hồi chứng chỉ để chữa lỗi. Nếu bước cài đã xong nhưng ghép đôi chưa xong, giữ app và dùng chế độ **2** sau khi xử lý nguyên nhân.
9. Không thêm ngoại lệ antivirus hoặc tắt Gatekeeper/Execution Policy toàn máy. Dùng đúng hướng dẫn mở công cụ cho từng hệ điều hành và để người dùng xử lý thông báo bảo mật thực tế.
10. Dòng “App đã cài” và file ghép đôi tồn tại chưa chứng minh hoàn tất. Chờ thông báo XONG/xác minh USB; sau đó hướng dẫn mở lại iSideload, đăng nhập cùng Apple ID, bật Wi-Fi/LocalDevVPN và chạy Kiểm tra kết nối thiết bị.
11. Khi báo kết quả, nêu phiên bản gói, chế độ, kết quả thực tế và bước còn cần người dùng. Phân biệt self-test ngoại tuyến, xác minh USB và kiểm tra LocalDevVPN trên iPhone. Không khẳng định mọi lỗi socket đã được sửa chỉ vì đã thay file ghép đôi.

Giữ các bản ghi/chứng chỉ người dùng trên thiết bị/máy tính của họ. Repo public chỉ có bộ cài đã được kiểm tra và tài liệu.
