# iSideload

**IPA và bộ cài Windows/macOS chính thức — iSideload 1.2.5 RC1, build 8.** Repo phân phối binary/tài liệu; mã nguồn app được giữ private.

## Tải bản mới

- [iSideload.ipa 1.2.5](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc1/iSideload.ipa)
- [Bộ cài Windows](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc1/isl-windows.zip) — giải nén và mở `Cai-iSideload.bat`.
- [Bộ cài macOS Universal](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc1/isl-macos-universal.zip) — giải nén và mở `Cai-iSideload.command`.
- [Trang phát hành/checksum](https://github.com/hongson117/iSideload-releases/releases/tag/v1.2.5-rc1) · [INSTALLERS.json](INSTALLERS.json).

Hai ZIP trong repo cũng đã kèm IPA **1.2.5 build 8**. Công cụ desktop vẫn 1.2.2; Windows 10/11 x64, macOS 11+ Apple Silicon/Intel, iPhone/iPad iOS 17.4+. Chọn **1** để cài mới kèm tạo/chép/xác minh Remote Pairing; chọn **2** để chỉ thiết lập/sửa ghép đôi cho app đã có. File ghép đôi được tạo riêng khi chạy, không có bản dùng chung trong ZIP.

[Hướng dẫn Windows](WINDOWS.md) · [Hướng dẫn macOS](MACOS.md) · [Cập nhật ngay trong app](APP-UPDATES.md)

Windows chế độ 2 đã được xác nhận qua USB và LocalDevVPN trên iPhone có bản ghi hợp lệ ở phiên kiểm chứng trước. Gói mới được kiểm tra checksum, binary và IPA; cài mới USB/macOS USB và tự cập nhật phiên bản trên thiết bị thật vẫn cần kiểm chứng. Windows EXE chưa ký Authenticode; macOS có chữ ký ad-hoc, chưa notarize.

## Nhờ AI cài nhanh

Dùng AI có quyền thao tác **Terminal/máy tính Windows hoặc Mac đang cắm iPhone**. Nếu AI chỉ trò chuyện hoặc công cụ chạy trong cloud/sandbox, AI sẽ hướng dẫn bạn chạy trên máy thật; không thể tự cài lên iPhone từ môi trường đó.

Sao chép đoạn này gửi cho AI:

```text
Hãy giúp tôi cài iSideload từ repo chính thức:
https://github.com/hongson117/iSideload-releases

Đọc README.md, AI-INSTALL.md và INSTALLERS.json.
Tôi muốn cài từ đầu (lựa chọn 1).
Kiểm tra hệ điều hành trên máy tính thật của tôi, tải đúng ZIP,
đối chiếu SHA-256 rồi giải nén và mở bộ cài trong Terminal tương tác.
Tôi sẽ tự nhập Apple ID/mật khẩu/2FA trực tiếp trong bộ cài,
bấm Tin cậy và bật Chế độ nhà phát triển trên iPhone khi được yêu cầu.
Theo dõi đến thông báo XONG, rồi hướng dẫn kiểm tra LocalDevVPN trong iSideload.
```

Nếu đã có app, đổi câu “Tôi muốn cài từ đầu” thành **“Tôi đã có iSideload, chỉ thiết lập/sửa ghép đôi bằng lựa chọn 2.”**

[Hướng dẫn chi tiết cho AI và người dùng](AI-INSTALL.md) · [Hướng dẫn agent trong repo](AGENTS.md)

[Bản ổn định trước đó / Releases](https://github.com/hongson117/iSideload-releases/releases/latest)

IPA tải về **chưa được ký**. Tải một file IPA không đồng nghĩa iOS sẽ tự cài được; dùng một trong các cách dưới đây để cài lần đầu. Không cần mã kích hoạt iSideload.

## Cài cho máy mới bằng một iPhone đã có iSideload

Máy hỗ trợ cần iSideload 1.2.1 trở lên và một Apple ID đã đăng nhập trong app. Máy nhận cần iOS/iPadOS 27 trở lên, bật Chế độ nhà phát triển. Cả hai máy cùng Wi-Fi, cho phép Mạng cục bộ và giữ mở khóa. Wi-Fi không được cách ly các thiết bị.

1. Máy hỗ trợ: **Thiết bị → Cài cho iPhone khác → Ghép nối iPhone mới**.
2. Máy nhận: **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển → Thiết bị khác**. Chọn tên `iSideload - Cai may khac …`.
3. Nhập mã 6 số đang hiện trên máy hỗ trợ vào máy nhận.
4. Máy hỗ trợ: kiểm tra tên/IP/UDID máy nhận, chọn Apple ID ký, xác nhận cài và nhập 2FA nếu Apple yêu cầu.
5. Máy nhận: **Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị**, tin cậy nhà phát triển rồi mở iSideload.

Ưu tiên nhập Apple ID người nhận ngay tại bước ký (có lựa chọn dùng một lần, không thêm vào danh sách tài khoản), hoặc chọn tài khoản đã đăng nhập. Có thể dùng bản khởi tạo của người hỗ trợ rồi để người nhận đăng nhập tài khoản riêng → Thiết lập iSideload bằng tài khoản này → Chuẩn bị → Cài bản cá nhân. Đây là một App ID riêng; chỉ xóa bản khởi tạo sau khi bản Cá nhân mở và gia hạn thành công.

Máy nhận không cần RC Pair hay Tailscale cho lượt cài này. Máy hỗ trợ không cần tự ghép nối hoặc bật LocalDevVPN để cài sang máy khác. Giữ iSideload mở trên máy hỗ trợ cho tới khi hoàn tất.

## Cài lần đầu bằng máy tính

**Windows 10/11 x64:** [tải isl-windows.zip (1.2.5 RC1)](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc1/isl-windows.zip), giải nén toàn bộ và mở `Cai-iSideload.bat`. Chọn **1** để cài từ đầu kèm file Remote Pairing; chọn **2** nếu đã có iSideload và chỉ cần thiết lập/sửa ghép đôi. [Hướng dẫn Windows từng bước](WINDOWS.md). Bản thử đã qua kiểm thử phần mềm; lựa chọn 2 đã được xác nhận qua USB và kiểm tra LocalDevVPN trên iPhone có sẵn bản ghi hợp lệ. Cài từ đầu vẫn cần xác nhận.

**macOS (Apple Silicon và Intel, macOS 11+):** tải [isl-macos-universal.zip](https://github.com/hongson117/iSideload-releases/releases/download/v1.2.5-rc1/isl-macos-universal.zip), giải nén, cắm iPhone bằng cáp và mở `Cai-iSideload.command`. Công cụ dùng dịch vụ USB của Apple có sẵn, không yêu cầu Homebrew/Xcode; đã kèm IPA 1.2.5 build 8. Chọn **1** để cài từ đầu kèm Remote Pairing hoặc **2** để chỉ thiết lập/sửa ghép đôi. [Xem hướng dẫn macOS từng bước](MACOS.md).

Tải `iSideload.ipa` từ trang release, dùng công cụ ký/cài iOS mà bạn tin cậy với Apple ID của chính bạn để cài lên thiết bị. Mở khóa iPhone, xác nhận Tin cậy máy tính khi được hỏi; bật Chế độ nhà phát triển và tin cậy nhà phát triển trước khi mở app.

Repository này chỉ phân phối bản cài nhị phân và thông tin kiểm chứng bản phát hành, không yêu cầu bạn gửi mật khẩu Apple ID, bản ghi ghép nối hoặc khóa ký cho người phát hành.

## Thiết lập trên máy vừa cài

Ngay khi mở, iSideload xuất hiện trong tab **Ứng dụng**, kèm phiên bản và hạn ký đọc từ profile đang cài. Nếu không đọc được profile, app báo chưa rõ hạn thay vì đoán số ngày.

Các bước thiết lập ngay trên màn hình:

1. **Chọn tài khoản ký:** đăng nhập Apple ID sẽ dùng để gia hạn, hoặc nhập chứng chỉ/profile của bạn.
2. **Cài LocalDevVPN** từ App Store nếu dùng Apple ID để ký/cài trên chính máy này.
3. **Kiểm tra ghép đôi:** nếu bộ cài Windows/macOS RC2 đã báo XONG, file đã có trong app; bật LocalDevVPN rồi bấm **Thiết bị → Kiểm tra kết nối thiết bị**. Nếu cài bằng Sideloadly/công cụ khác, chạy bộ cài desktop và chọn **2** để bổ sung file. iOS 27+ cũng có thể tự ghép nối trong app. Máy nhận app qua tính năng Cài cho iPhone khác vẫn cần bản ghi riêng cho tự gia hạn.
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

Luồng cài từ iPhone hỗ trợ sang máy mới đã được người dùng xác nhận ở bản 1.2.0 build 31. Bản 1.2.2 bổ sung sửa nhập Remote Pairing; hai bộ cài RC2 tự thiết lập ghép đôi qua USB. Kiểm thử tự động đã qua; kiểm tra CI không thay thế việc thử trên thiết bị thật. Khi báo lỗi, gửi phiên bản/build, bước thao tác và nội dung lỗi đã loại bỏ dữ liệu riêng; không gửi mật khẩu, file ghép nối hay `.p12`.


## Trong iSideload 1.2.3

- **Đã có file ghép đôi:** file còn trong app. Bật LocalDevVPN và bấm **Kiểm tra kết nối thiết bị** ngay ở đầu tab Thiết bị. Mở lại/cập nhật app đặt lại trạng thái kiểm tra, chưa cần tạo hay nhập lại file chỉ vì chưa kiểm tra ở lần mở mới.
- **VPN đã bật:** đây là bước chuẩn bị; nút kiểm tra thiết bị mới xác nhận kết nối tới iPhone.
- **Cài/cài lại LiveContainer:** chọn rõ Apple ID hoặc chứng chỉ .p12 đã nhập. Nguồn được giữ qua bước bật VPN và dùng cho chứng chỉ chuyển sang LiveContainer.
- **Nhiều bản LiveContainer:** dùng hướng dẫn lưu/nhập .p12 vào đúng bản trong app. Đổi nguồn ký có thể tạo bản khác; dữ liệu bản cũ không tự chuyển sang bản mới.

## Cập nhật phiên bản bằng tài khoản của bạn

Gói này kèm iSideload 1.2.5 có chức năng tải IPA mới từ GitHub, kiểm tra checksum rồi ký và cài đè bằng nguồn gia hạn của bản đang cài. Sau khi cài, đăng nhập cùng Apple ID đã dùng ký trên máy tính, chọn Tài khoản gia hạn trong tab Ứng dụng rồi thử Làm mới iSideload.

Vào Cài đặt → Cập nhật iSideload → Kiểm tra phiên bản mới ngay. Có thể bật Tự tải, ký và cập nhật khi mở app (mặc định tắt). Apple ID cần Remote Pairing và LocalDevVPN. Chứng chỉ có sẵn vẫn cần profile phù hợp và xác nhận cài của iOS. Mở lại app để kiểm tra phiên bản sau khi cài đè; iOS không bảo đảm cài âm thầm khi app đóng.

Nếu bản đầu được ký bằng tài khoản người hỗ trợ, vào Tài khoản → Thiết lập iSideload bằng tài khoản này để tạo bản Cá nhân của bạn trước. Cập nhật phiên bản giữ đúng App ID/Team đang cài; đổi chủ sở hữu là luồng riêng.
