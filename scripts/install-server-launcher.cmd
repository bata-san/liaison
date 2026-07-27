@echo off
setlocal EnableExtensions
title Liaison Server Installer

cd /d "%~dp0"
set "LIAISON_LAUNCH_LOG=%TEMP%\LiaisonServerLauncher.log"

>"%LIAISON_LAUNCH_LOG%" echo [%DATE% %TIME%] CMD launcher started.

echo Liaison Server installer
echo.
echo Launcher log: %LIAISON_LAUNCH_LOG%
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-server-bundle.ps1"
set "LIAISON_EXIT_CODE=%ERRORLEVEL%"

>>"%LIAISON_LAUNCH_LOG%" echo [%DATE% %TIME%] PowerShell exited with code %LIAISON_EXIT_CODE%.
echo.
echo PowerShell exit code: %LIAISON_EXIT_CODE%
echo Launcher log: %LIAISON_LAUNCH_LOG%
echo.

if defined LIAISON_LAUNCHER_TEST exit /b %LIAISON_EXIT_CODE%
pause
exit /b %LIAISON_EXIT_CODE%
