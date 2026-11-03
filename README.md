# iSideload

**Bản IPA, bộ cài Windows/macOS và hướng dẫn cài đặt chính thức.** Repository này không chứa mã nguồn ứng dụng, Git bundle, bản ghi ghép nối hay thông tin máy chủ.

[**Tải bản phát hành mới nhất**](https://github.com/hongson117/iSideload-releases/releases/latest)

IPA tải về **chưa được ký**. Tải một file IPA không đồng nghĩa iOS sẽ tự cài được; dùng một trong các cách dưới đây để cài lần đầu. Không cần mã kích hoạt iSideload.

## Cài cho máy mới bằng một iPhone đã có iSideload

Máy hỗ trợ cần iSideload 1.2.1 trở lên và một Apple ID đã đăng nhập trong app. Máy nhận cần iOS/iPadOS 27 trở lên, bật Chế độ nhà phát triển. Cả hai máy cùng Wi-Fi, cho phép Mạng cục bộ và giữ mở khóa. Wi-Fi không được cách ly các thiết bị.

1. Máy hỗ trợ: **Thiết bị → Cài cho iPhone khác → Ghép nối iPhone mới**.
2. Máy nhận: **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển → Thiết bị khác**. Chọn tên `iSideload - Cai may khac …`.
3. Nhập mã 6 số đang hiện trên máy hỗ trợ vào máy nhận.
4. Máy hỗ trợ: kiểm tra tên/IP/UDID máy nhận, chọn Apple ID ký, xác nhận cài và nhập 2FA nếu Apple yêu cầu.
5. Máy nhận: **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị**, tin cậy nhà phát triển rồi mở iSideload.

Chọn tài khoản sẽ dùng lâu dài trên máy nhận để ký lượt cài đầu tiên. Nếu người nhận dùng Apple ID riêng, hãy thêm tài khoản đó trên máy hỗ trợ và chọn nó trước khi cài. iOS có thể từ chối gia hạn tại chỗ khi đổi tài khoản/Team ký; dùng lại tài khoản đã ký hoặc nhờ máy hỗ trợ cài lại bằng tài khoản mong muốn.

Máy nhận không cần RC Pair hay Tailscale cho lượt cài này. Máy hỗ trợ không cần tự ghép nối hoặc bật LocalDevVPN để cài sang máy khác. Giữ iSideload mở trên máy hỗ trợ cho tới khi hoàn tất.

## Cài lần đầu bằng máy tính

**Windows 10/11 x64:** [tải isl-windows.zip (1.2.2 RC2)](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.2-rc2/isl-windows.zip), giải nén toàn bộ và mở `Cai-iSideload.bat`. Chọn **1** để cài từ đầu kèm file Remote Pairing; chọn **2** nếu đã có iSideload và chỉ cần thiết lập/sửa ghép đôi. [Hướng dẫn Windows từng bước](WINDOWS.md). Bản thử đã qua kiểm thử phần mềm; cần xác nhận USB trên iPhone thật.

**macOS (Apple Silicon và Intel, macOS 11+):** tải [isl-macos-universal.zip](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.2-rc2/isl-macos-universal.zip), giải nén, cắm iPhone bằng cáp và mở `Cai-iSideload.command`. Công cụ dùng dịch vụ USB của Apple có sẵn, không yêu cầu Homebrew/Xcode; đã kèm IPA 1.2.2 build 35. Chọn **1** để cài từ đầu kèm Remote Pairing hoặc **2** để chỉ thiết lập/sửa ghép đôi. [Xem hướng dẫn macOS từng bước](MACOS.md).

Tải `iSideload.ipa` từ trang release, dùng công cụ ký/cài iOS mà bạn tin cậy với Apple ID của chính bạn để cài lên thiết bị. Mở khóa iPhone, xác nhận Tin cậy máy tính khi được hỏi; bật Chế độ nhà phát triển và tin cậy nhà phát triển trước khi mở app.

Repository này chỉ phân phối bản cài nhị phân và thông tin kiểm chứng bản phát hành, không yêu cầu bạn gửi mật khẩu Apple ID, bản ghi ghép nối hoặc khóa ký cho người phát hành.

## Thiết lập trên máy vừa cài

Ngay khi mở, iSideload xuất hiện trong tab **Ứng dụng**, kèm phiên bản và hạn ký đọc từ profile đang cài. Nếu không đọc được profile, app báo chưa rõ hạn thay vì đoán số ngày.

Các bước thiết lập ngay trên màn hình:

1. **Chọn tài khoản ký:** đăng nhập Apple ID sẽ dùng để gia hạn, hoặc nhập chứng chỉ/profile của bạn.
2. **Cài LocalDevVPN** từ App Store nếu dùng Apple ID để ký/cài trên chính máy này.
3. **Ghép nối máy này:** iOS 27+ ghép nối trong app rồi nhập mã ở Cài đặt. Ghép nối lúc nhận app thuộc máy hỗ trợ; máy mới cần bản ghi riêng để tự gia hạn. Trên iOS cũ, cần bản ghi tương thích đã tạo từ máy tính.
4. Bấm **Làm mới iSideload** để thử. App sẽ mở LocalDevVPN nếu cần kết nối. Sau khi cài đè, app có thể tự đóng; mở lại để kiểm tra hạn ký.

## Cài thêm ứng dụng và gia hạn

- **Ứng dụng → Cài LiveContainer:** tải bản chính thức, ký và cài. iSideload hỗ trợ chuyển chứng chỉ sang LiveContainer.
- **Chọn file IPA để cài:** cài IPA bạn đã tải vào Files.
- **Nguồn:** thêm nguồn định dạng AltStore/SideStore; không có kho app bên thứ ba được tự động thêm sẵn.
- **Làm mới iSideload:** dùng chính bundle đang chạy, không cần giữ IPA gốc.
- **Ký lại tất cả:** gia hạn các app khác trước và iSideload sau cùng. Sau khi bật VPN, thao tác tiếp tục đúng phạm vi đã chọn.

Apple ID miễn phí thường có profile 7 ngày; xem ngày hết hạn thật trong app và gia hạn trước ngày đó. Tác vụ nền do iOS quyết định và không tự thay chính app đang chạy. Muốn gia hạn cả iSideload, dùng nút trong app hoặc Phím tắt mở app để ký lại tất cả.

## Kiểm chứng và quyền riêng tư

- Đối chiếu SHA-256 trong `SHA256SUMS.txt` của release **trước khi tự ký lại IPA**. Sau khi ký bằng tài khoản của bạn, checksum thay đổi là bình thường.
- Bản phát hành được kiểm tra không kèm source/debug files, khóa riêng hoặc bản ghi ghép nối. Thông tin tài khoản, bản ghi thiết bị và chứng chỉ của người dùng được tạo sau khi cài; không nằm trong IPA công khai.
- Build đã loại bỏ symbol/debug thừa. Điều này tăng chi phí phân tích, không làm IPA miễn nhiễm với dịch ngược hoặc ngăn người khác tải lại một file công khai.
- Các thư viện nguồn mở giữ giấy phép/ghi công tương ứng; xem **Cài đặt → Giấy phép phần mềm nguồn mở** trong app.

Luồng cài từ iPhone hỗ trợ sang máy mới đã được người dùng xác nhận ở bản 1.2.0 build 31. Bản 1.2.1 bổ sung tự nhận diện/gia hạn và kiểm thử tự động; kiểm tra CI không thay thế việc thử trên thiết bị thật. Khi báo lỗi, gửi phiên bản/build, bước thao tác và nội dung lỗi đã loại bỏ dữ liệu riêng; không gửi mật khẩu, file ghép nối hay `.p12`.
