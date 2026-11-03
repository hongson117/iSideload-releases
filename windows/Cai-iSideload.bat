@echo off
chcp 65001 >nul
setlocal
title Cài iSideload và ghép đôi qua USB
cd /d "%~dp0"
echo =====================================================
echo   iSIDELOAD - CÀI APP VÀ THIẾT LẬP GHÉP ĐÔI QUA USB
echo =====================================================
echo Đang kiểm tra bộ cài...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Kiem-tra-goi.ps1"
if errorlevel 1 (
  echo Bộ cài thiếu file hoặc bị thay đổi. Tải lại và giải nén toàn bộ ZIP.
  pause
  exit /b 2
)
echo.
echo Cắm iPhone bằng cáp dữ liệu, mở khóa và bấm Tin cậy máy tính.
echo Cần cài Apple Devices hoặc iTunes và bật Chế độ nhà phát triển.
echo.
echo [1] Cài từ đầu: ký, cài iSideload và tự thiết lập file ghép đôi
echo [2] Đã có iSideload: chỉ thiết lập hoặc sửa file ghép đôi
echo.
choice /C 12 /N /M "Chọn 1 hoặc 2: "
if errorlevel 2 (
  "%~dp0isl-cli.exe" --pair-only
) else (
  "%~dp0isl-cli.exe" "%~dp0iSideload.ipa"
)
set "ISL_RESULT=%ERRORLEVEL%"
echo.
if not "%ISL_RESULT%"=="0" echo Chưa hoàn tất. Đọc dòng lỗi phía trên; app đã cài có thể tiếp tục bằng chế độ 2.
pause
exit /b %ISL_RESULT%
