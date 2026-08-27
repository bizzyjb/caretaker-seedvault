@echo off
title Caretaker SeedVault - Status
setlocal
set "PS=%~dp0scripts\Show-Status.ps1"
if not exist "%PS%" set "PS=%LOCALAPPDATA%\CaretakerSeedVault\app\Show-Status.ps1"
if not exist "%PS%" (
  echo Caretaker SeedVault does not appear to be installed. Run Setup.cmd first.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS%" %*
echo.
pause
