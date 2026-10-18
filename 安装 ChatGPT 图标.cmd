@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install-windows-shortcut.ps1"
if errorlevel 1 pause
