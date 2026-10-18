@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\launch-windows.ps1" -Probe -NoDialog
echo.
if errorlevel 1 (
  echo Compatibility check failed.
) else (
  echo Compatibility check passed.
)
pause
