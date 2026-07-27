@echo off
setlocal EnableExtensions
title Liaison Server Installer

set "LIAISON_SCRIPT=%~dp0scripts\install-server-bundle.ps1"
set "LIAISON_LAUNCH_LOG=%TEMP%\LiaisonServerLauncher.log"

> "%LIAISON_LAUNCH_LOG%" echo [%DATE% %TIME%] CMD launcher started.
>>"%LIAISON_LAUNCH_LOG%" echo Script: %LIAISON_SCRIPT%

echo Liaison Server installer
echo.
echo Launcher log: %LIAISON_LAUNCH_LOG%
echo.

if not exist "%LIAISON_SCRIPT%" (
  echo ERROR: Installer script was not found.
  echo Missing: %LIAISON_SCRIPT%
  >>"%LIAISON_LAUNCH_LOG%" echo ERROR: Installer script was not found.
  goto :failed
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: Windows PowerShell was not found.
  >>"%LIAISON_LAUNCH_LOG%" echo ERROR: powershell.exe was not found.
  goto :failed
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { & $env:LIAISON_SCRIPT } catch { $message = ($_ ^| Out-String); Add-Content -Path $env:LIAISON_LAUNCH_LOG -Value $message -Encoding UTF8; Write-Host $message -ForegroundColor Red; exit 1 }"
set "LIAISON_EXIT_CODE=%ERRORLEVEL%"

echo.
if "%LIAISON_EXIT_CODE%"=="0" (
  echo Liaison Server installer finished successfully.
) else (
  echo Liaison Server installer failed with exit code %LIAISON_EXIT_CODE%.
  echo Open this log and send its contents:
  echo %LIAISON_LAUNCH_LOG%
)
echo.
pause
exit /b %LIAISON_EXIT_CODE%

:failed
echo.
echo Open this log and send its contents:
echo %LIAISON_LAUNCH_LOG%
echo.
pause
exit /b 1
