#!/bin/bash
set -uo pipefail
cd -- "$(dirname -- "$0")" || exit 1
printf '\n=== CÀI iSIDELOAD LẦN ĐẦU TRÊN macOS ===\n\n'
printf '1. Cắm iPhone/iPad bằng cáp dữ liệu, mở khóa.\n'
printf '2. Mở Finder, chọn thiết bị; xác nhận Trust/Tin cậy trên cả hai máy.\n'
printf '3. Chuẩn bị Apple ID sẽ dùng để ký/gia hạn và mã 2FA.\n'
printf 'Không cần Homebrew, Xcode, RC Pair hay Tailscale cho lượt cài USB này.\n\n'
read -r -p 'Chuẩn bị xong, nhấn Enter để tiếp tục (Ctrl+C để hủy)… ' _
if [[ ! -x ./isl-mac || ! -f ./iSideload.ipa ]]; then
  printf '\nThiếu công cụ hoặc IPA. Hãy giải nén đầy đủ isl-macos-universal.zip.\n'
  read -r -p 'Nhấn Enter để đóng… ' _
  exit 2
fi
if ! /usr/bin/shasum -a 256 -c SHA256SUMS.txt; then
  printf '\nChecksum không khớp. Chưa chạy công cụ; hãy tải lại gói từ trang phát hành chính thức.\n'
  read -r -p 'Nhấn Enter để đóng… ' _
  exit 2
fi
./isl-mac ./iSideload.ipa
result=$?
if [[ $result -ne 0 ]]; then
  printf '\nCông cụ kết thúc với mã %s. Xem lỗi ở trên và README-VI.txt.\n' "$result"
  printf 'Nếu macOS chặn công cụ chưa notarize: dùng System Settings > Privacy & Security > Open Anyway cho đúng file này.\n'
fi
read -r -p 'Nhấn Enter để đóng cửa sổ… ' _
exit "$result"
