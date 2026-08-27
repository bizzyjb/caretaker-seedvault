@echo off
title Caretaker SeedVault - Setup
setlocal
set "PS=%~dp0scripts\Install-SeedVault.ps1"
if not exist "%PS%" set "PS=%LOCALAPPDATA%\CaretakerSeedVault\app\Install-SeedVault.ps1"
if not exist "%PS%" (
  echo Could not find the SeedVault scripts.
  echo Make sure you unzipped the whole folder, not just this file.
  echo.
  pause
  exit /b 1
)
REM Files extracted from a downloaded zip are flagged as "from another computer",
REM which can trigger security prompts. Clear that flag first.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0scripts' -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS%" %*
echo.
pause
