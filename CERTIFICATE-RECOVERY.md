# Thu hồi chứng chỉ và tiếp tục ký

1.2.6 phân loại tương tác theo tác vụ (foreground/background), không dùng snapshot UIApplication.active ở lúc tạo request. Thao tác cài, ký lại, thiết lập tài khoản và cập nhật được người dùng mở trong app vẫn cho phép chọn chứng chỉ khi quay về từ LocalDevVPN, kể cả lúc UIKit đang inactive trong chuyển cảnh.

Tác vụ BGAppRefresh/BGProcessing truyền background xuyên suốt refresh → install → core. Không mở VPN, không chờ hộp thoại 2FA/thu hồi vô hình, không thu hồi chứng chỉ còn hạn mà chưa chọn. Core ưu tiên interaction_mode rõ ràng hơn flag tương thích cũ. Kiểm thử Swift/Rust bao phủ stale false sau VPN và background có stale true.

Khi hết quota: hiện danh sách Apple ID, Team, tên, serial và hạn chứng chỉ; chọn chứng chỉ cũ rồi Thu hồi và ký tiếp. Chứng chỉ trong profile bản app hiện tại cần thêm xác nhận riêng. Hủy giữ nguyên chứng chỉ còn hạn.

Cài đặt → Quản lý chứng chỉ phát triển, hoặc Tài khoản → Quản lý chứng chỉ theo Apple ID. Chọn tài khoản/Team, tải danh sách và thu hồi đúng serial. Backend tải lại danh sách trong Team đã chọn trước khi thu hồi, từ chối serial lạ và chặn chứng chỉ hiện tại nếu chưa có allow_current. Không mặc định dùng tài khoản chính hoặc Team đầu tiên khi người dùng đã chọn Team khác.

Thu hồi thủ công có thể ảnh hưởng app/thiết bị khác dùng cùng chứng chỉ. Sau khi thu hồi thủ công, quay lại ký lại. Thu hồi trong luồng hết quota tự tiếp tục tác vụ ký đang chờ.
