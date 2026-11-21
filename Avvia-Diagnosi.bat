@echo off
title Diagnosi Wi-Fi - Internet-Box
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wifi-diagnosi.ps1" %*
echo.
pause
