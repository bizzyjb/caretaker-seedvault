@echo off
title Caretaker SeedVault - Restore a Save
setlocal
set "PS=%~dp0scripts\Restore-Save.ps1"
if not exist "%PS%" set "PS=%LOCALAPPDATA%\CaretakerSeedVault\app\Restore-Save.ps1"
if not exist "%PS%" (
  echo Caretaker SeedVault does not appear to be installed. Run Setup.cmd first.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS%" %*
echo.
pause
