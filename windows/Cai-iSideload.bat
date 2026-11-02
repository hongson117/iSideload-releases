@echo off
chcp 65001 >nul
title Cài iSideload qua cáp USB
cd /d "%~dp0"
echo ==============================================
echo   CÀI iSIDELOAD LẦN ĐẦU QUA CÁP USB (miễn phí)
echo ==============================================
echo Cắm iPhone bằng cáp, mở khóa màn hình, bấm "Tin cậy" nếu được hỏi.
echo Cần cài sẵn Apple Devices (Microsoft Store) hoặc iTunes.
echo.
pause
"%~dp0isl-cli.exe" "%~dp0iSideload.ipa"
