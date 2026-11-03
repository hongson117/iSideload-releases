# Cập nhật phiên bản bằng tài khoản của người dùng

Trong **Cài đặt → Cập nhật**, bấm **Kiểm tra phiên bản mới ngay** rồi **Tải, ký và cập nhật**. Có thể bật **Tự tải, ký và cập nhật khi mở app** (mặc định tắt). Kiểm tra phiên bản khi mở app mặc định bật, tối đa một lần mỗi 6 giờ; nút kiểm tra thủ công bỏ qua thời gian chờ.

Nguồn phát hành: `https://raw.githubusercontent.com/hongson117/iSideload-releases/main/app-updates.json`, schema 1, mỗi sản phẩm có version, build, url, sha256 và bytes. Feed chỉ trỏ tới IPA unsigned trong GitHub Releases của hongson117/iSideload-releases. Thứ tự phiên bản là số từng thành phần rồi tới build; không hạ phiên bản. CI kiểm tra chính sách URL, thứ tự phiên bản và remap chủ sở hữu.

IPA tải về được kiểm tra kích thước, SHA-256, sản phẩm và version/build. Sau đó core đưa bundle ID về **đúng ID đang cài**, giữ tên bản Cá nhân và profile hiện tại làm thông tin Team cho bước ký; signer xác thực Apple ID thuộc Team đó trước khi tạo profile/chứng chỉ mới. Không đổi sang tài khoản đầu tiên hay tạo thêm bản cài. Không cần mật khẩu trong IPA hoặc trên máy chủ phát hành.

Nguồn ký lấy từ tài khoản gia hạn đã chọn của bản đang cài. Bản khởi tạo của A vẫn cần thiết lập bản Cá nhân của B trước nếu B muốn tự ký. Đổi chủ sở hữu và cập nhật phiên bản là hai thao tác riêng.

Apple ID cần file ghép đôi và LocalDevVPN. Khi mở LocalDevVPN, tác vụ nhớ **IPA phiên bản mới**, không đóng gói lại mã phiên bản cũ. Chứng chỉ có sẵn giữ nguyên giới hạn của profile và hộp thoại xác nhận cài OTA của iOS.

Tự cập nhật chạy khi app đang mở. iOS có thể đóng app trong lúc cài đè; mở lại để xác nhận version/build thực tế. Không coi socket ngắt cuối lượt cài là bằng chứng cập nhật thành công. Lần mở tiếp theo kiểm tra version/build mong đợi và thông báo nếu chưa khớp. Gia hạn chữ ký 7 ngày vẫn là mục Tự ký lại riêng. Tính năng không cam kết cài âm thầm khi app đã đóng.

Phát hành mới: tạo tag mới, audit IPA, công bố asset bất biến, kiểm tra tải công khai cùng SHA-256, rồi cập nhật feed sau cùng. Không ghi token, pairing, P12, tài khoản cá nhân hoặc mã nguồn private vào feed/release. Repo/feed GitHub là nguồn tin cậy; SHA-256 kiểm tra tính toàn vẹn, không thay thế chữ ký độc lập của nhà phát hành.
