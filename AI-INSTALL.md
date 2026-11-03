# Cài iSideload với sự hỗ trợ của AI

Tài liệu này dành cho người dùng và AI có công cụ thao tác trên **máy Windows/Mac thực sự đang cắm iPhone**. Bộ cài tự ký/cài app, tạo Remote Pairing, chuyển file vào iSideload và xác minh qua USB.

Nếu AI chỉ trò chuyện hoặc Terminal của AI chạy trong cloud/sandbox, AI cần hướng dẫn bạn làm trên máy thật. Chạy bộ cài trong cloud không làm iPhone xuất hiện qua USB.

## Link chính thức

- Repo: [hongson117/iSideload-releases](https://github.com/hongson117/iSideload-releases).
- [Windows ZIP](https://raw.githubusercontent.com/hongson117/iSideload-releases/main/isl-windows.zip).
- [macOS Universal ZIP](https://raw.githubusercontent.com/hongson117/iSideload-releases/main/isl-macos-universal.zip).
- [INSTALLERS.json](https://raw.githubusercontent.com/hongson117/iSideload-releases/main/INSTALLERS.json): phiên bản, hệ điều hành, tên gói, URL và SHA-256 cho từng gói.
- [SHA256SUMS.txt](https://raw.githubusercontent.com/hongson117/iSideload-releases/main/SHA256SUMS.txt): checksum **hai ZIP trong repo**. File checksum ở từng trang release áp dụng cho các asset của release đó.
- Hướng dẫn: [Windows](WINDOWS.md), [macOS](MACOS.md).

## Chọn đúng cách cài

| Nhu cầu | Chọn trong bộ cài | Apple ID trên máy tính |
|---|---|---|
| Chưa có iSideload, cài từ đầu | **1** | Người dùng nhập trực tiếp vào Terminal của bộ cài |
| Đã có iSideload qua Sideloadly/công cụ khác, chỉ cần ghép đôi | **2** | Không yêu cầu đăng nhập để ký lại app |

Windows: mở `Cai-iSideload.bat` trong thư mục `isl-windows` sau khi giải nén. Mac: mở `Cai-iSideload.command` trong thư mục `iSideload-macOS`. Gói đã kèm IPA 1.2.2 build 35; không cần tải IPA riêng cho hai luồng này.

## Quy trình để AI hỗ trợ

1. Xác nhận công cụ của AI điều khiển đúng máy tính của người dùng, nhận biết Windows hay macOS và kiến trúc. Windows cần Windows 10/11 x64; Mac Universal dành cho Apple Silicon/Intel, macOS 11+. Thiết lập Remote Pairing tự động cần iOS/iPadOS 17.4+.
2. Đọc `INSTALLERS.json`, chọn gói đúng hệ điều hành. Tải từ URL trong manifest; có thể dùng URL GitHub Releases cố định cùng phiên bản nếu đường raw gặp lỗi.
3. Tính SHA-256 của ZIP và so khớp `sha256` trong manifest **trước khi giải nén/chạy**. Nếu không khớp, dừng và tải lại gói đúng phiên bản. Không sửa checksum để bỏ qua lỗi.
4. Giải nén đầy đủ vào một thư mục làm việc mới, giữ các file cạnh nhau. Không chạy launcher trực tiếp trong trình xem ZIP. Trên Mac giữ quyền thực thi của `isl-mac` và `.command`.
5. Windows: kiểm tra Apple Devices/iTunes đã nhận iPhone. Mac: kiểm tra Finder đã nhận iPhone. Người dùng cắm cáp dữ liệu, mở khóa và xác nhận Tin cậy trên iPhone/Mac khi được hỏi.
6. Mở launcher trong **Terminal/cửa sổ console tương tác hiển thị cho người dùng**. Chọn 1 hoặc 2 theo mục tiêu. Không chạy quy trình đăng nhập trong một tiến trình nền không có chỗ nhập liệu. Với AI không mở được Terminal tương tác, để người dùng nhấp đúp launcher và tiếp tục đọc/hướng dẫn theo kết quả họ cung cấp.
7. Người dùng tự nhập Apple ID, mật khẩu, 2FA trong Terminal của bộ cài; không dán các giá trị đó vào chat. Người dùng tự nhập mật mã iPhone, bật Chế độ nhà phát triển, xác nhận khởi động lại và tin cậy tài khoản nhà phát triển khi được yêu cầu.
8. Giữ cáp và chờ thông báo **XONG: iSideload đã có file Remote Pairing…**. Dòng “App đã cài” chưa phải hoàn tất: công cụ còn chuẩn bị kết nối phát triển qua Wi-Fi, tạo/chép/đọc lại/xác minh file ghép đôi.
9. Trên iPhone, mở lại iSideload. Khi cần gia hạn bằng Apple ID, đăng nhập cùng tài khoản đã dùng để ký, bật Wi-Fi/LocalDevVPN rồi bấm **Thiết bị → Kiểm tra kết nối thiết bị**. “Đã nhập file” chỉ là trạng thái có file; kết quả kiểm tra kết nối mới xác nhận đường LocalDevVPN hoạt động.
10. Báo lại phiên bản gói, chế độ đã chạy, bước đã hoàn tất và bước còn cần người dùng thao tác. Chỉ xác nhận cài/ghép đôi thành công khi công cụ trả kết quả tương ứng; chưa được kiểm tra thì ghi rõ.

## Lệnh của công cụ dành cho AI có Terminal local

Sau khi đã xác minh checksum và giải nén, các lệnh sau có thể dùng để kiểm tra ngoại tuyến hoặc đọc danh sách thiết bị. Luồng cài dùng launcher tương tác.

Windows:

```powershell
.\isl-cli.exe --version
.\isl-cli.exe --self-test
.\isl-cli.exe --list-devices
```

macOS:

```bash
./isl-mac --version
./isl-mac --self-test
./isl-mac --list-devices
```

`--self-test` không cần iPhone hay tài khoản; kết quả này không chứng minh đã cài lên iPhone. `--list-devices` chỉ liệt kê thiết bị USB. Lệnh `--pair-only` thực hiện thiết lập ghép đôi cho iSideload đã cài; không coi đây là phép kiểm tra chỉ đọc.

## Khi gặp lỗi

- **App đã cài, chưa ghép đôi xong:** giữ app, xử lý nguyên nhân trong Terminal rồi chọn **2** để tiếp tục. Không mặc định xóa app, dữ liệu hay đặt lại toàn bộ thiết lập tin cậy.
- **Nhiều iPhone hoặc nhiều bản iSideload:** chọn đúng thiết bị/bundle ID. Không tự chọn một máy khác để vượt qua lỗi.
- **Windows chưa nhận iPhone:** hoàn tất Apple Devices/iTunes, cáp và Tin cậy. Xem [Windows](WINDOWS.md).
- **Mac chặn công cụ:** dùng hướng dẫn Gatekeeper trong [macOS](MACOS.md) cho đúng file đã tải. Không tắt Gatekeeper toàn hệ thống. Công cụ không cần `sudo`; nếu hệ thống yêu cầu xác nhận bảo mật, người dùng xử lý trên máy của họ.
- **Hết chỗ chứng chỉ:** để người dùng đọc và quyết định trong bộ cài. Không tự chọn/thu hồi chứng chỉ vì có thể ảnh hưởng app khác.
- **File ghép đôi có nhưng tự gia hạn lỗi:** lấy phiên bản iOS đầy đủ, kết quả Kiểm tra kết nối thiết bị và nguyên văn lỗi. Không yêu cầu gửi mật khẩu, `.p12`, file ghép đôi hay thư mục cache.

## Giới hạn của bản phát hành

1.2.2 RC2 là bản thử. Build Windows/macOS, kiểm thử chép/khôi phục file, launcher và self-test đã qua; USB đầu-cuối trên iPhone thật vẫn cần xác nhận. File ghép đôi được tạo riêng khi chạy, không có bản ghi dùng chung trong ZIP. Hai bộ cài không tự đăng nhập tài khoản vào app iPhone; người dùng đăng nhập trong app sau khi cài để tự gia hạn.
