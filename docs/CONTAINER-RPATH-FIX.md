# iContainer 0.1.1: sửa duplicate LC_RPATH và nâng cấp trong app

Lỗi dlopen duplicate LC_RPATH @loader_path/Frameworks xảy ra khi bộ chuẩn bị đổi @executable_path/Frameworks thành @loader_path/Frameworks rồi thêm lại đường dẫn đó. Bản sửa so sánh các đường dẫn sau khi đổi, giữ lần xuất hiện đầu tiên và thứ tự ban đầu, bỏ trùng trong app chính lẫn Mach-O nhúng. Chỉ thêm đường dẫn Frameworks mặc định nếu chưa có.

Không dịch chuyển phần code/VM layout để nới header. Có kiểm thử cho đường dẫn đã có, xung đột sau rewrite, trùng trong thư viện, và load command hỏng. Dữ liệu app trong Data không bị thay; bước Chuẩn bị lại luôn lấy Original.app làm nguồn. Bản chạy đã chuẩn bị cũ được đánh preparation_revision 0 và yêu cầu chuẩn bị lại; bản mới dùng revision 2, runtime kiểm tra cả lúc tạo lệnh chạy lẫn lúc boot.

Sau cập nhật: Container → app đang lỗi → Chuẩn bị lại → chọn đúng nguồn ký của iContainer → Chạy. Không cần xóa hay nhập lại app cũ. Lỗi khác sau bước này cần tiếp tục kiểm tra; sửa rpath không bảo đảm mọi IPA có thể chạy chung tiến trình.

Cập nhật phiên bản: Cài đặt → Cập nhật iContainer, hoặc nút Cập nhật phiên bản ở thẻ gia hạn. App tải IPA public đã kiểm tra SHA-256, giữ bundle ID/Team của bản Cá nhân, ký trên máy và cài đè qua LocalDevVPN. Có thể bật tự cập nhật khi mở app. Khi trở về từ VPN, tác vụ giữ đúng IPA mới; foreground vẫn cho chọn chứng chỉ cần thu hồi, background không chờ hộp thoại ẩn.

Mã nguồn vẫn private. IPA/metadata public theo xác nhận mới của người dùng. Workflow Build iContainer trên repo phát hành cho chạy thủ công bằng GitHub; chỉ xuất IPA đã audit, checksum, notices và metadata, không xuất mã nguồn hoặc log biên dịch private.
