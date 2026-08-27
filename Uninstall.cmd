@echo off
title Caretaker SeedVault - Uninstall
setlocal
set "PS=%~dp0scripts\Uninstall-SeedVault.ps1"
if not exist "%PS%" set "PS=%LOCALAPPDATA%\CaretakerSeedVault\app\Uninstall-SeedVault.ps1"
if not exist "%PS%" (
  echo Caretaker SeedVault does not appear to be installed.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS%" %*
echo.
pause
