@echo off
setlocal EnableExtensions
title Liaison Server Installer

cd /d "%~dp0"
set "LIAISON_LAUNCH_LOG=%TEMP%\LiaisonServerLauncher.log"
set "LIAISON_EXIT_CODE=1"

>"%LIAISON_LAUNCH_LOG%" echo [%DATE% %TIME%] CMD launcher started.

echo Liaison Server installer
echo.
echo Launcher log: %LIAISON_LAUNCH_LOG%
echo.

if exist "scripts\install-server-bundle.ps1" goto :script_ok
echo ERROR: Installer script was not found.
>>"%LIAISON_LAUNCH_LOG%" echo ERROR: Installer script was not found.
goto :finish

:script_ok
where powershell.exe >nul 2>&1
if not errorlevel 1 goto :powershell_ok
echo ERROR: Windows PowerShell was not found.
>>"%LIAISON_LAUNCH_LOG%" echo ERROR: powershell.exe was not found.
goto :finish

:powershell_ok
if "%LIAISON_LAUNCHER_TEST%"=="1" goto :test_ok
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install-server-bundle.ps1"
set "LIAISON_EXIT_CODE=%ERRORLEVEL%"
goto :finish

:test_ok
>>"%LIAISON_LAUNCH_LOG%" echo Launcher path test succeeded.
set "LIAISON_EXIT_CODE=0"
goto :finish

:finish
echo.
if "%LIAISON_EXIT_CODE%"=="0" goto :success
echo Liaison Server installer failed with exit code %LIAISON_EXIT_CODE%.
echo Open this log and send its contents:
echo %LIAISON_LAUNCH_LOG%
goto :pause

:success
echo Liaison Server installer finished successfully.

:pause
echo.
if "%LIAISON_LAUNCHER_TEST%"=="1" exit /b %LIAISON_EXIT_CODE%
pause
exit /b %LIAISON_EXIT_CODE%
