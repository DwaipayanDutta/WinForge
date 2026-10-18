@echo off
setlocal
rem WinForge launcher.
rem   Double-click (no arguments): opens the GUI.
rem   WinForge.bat <Command> [options]: runs the CLI, e.g. WinForge.bat Preview -Profile Minimal
rem goto is used instead of ( ) blocks so arguments containing ")" cannot break parsing.
set "SCRIPT_DIR=%~dp0"
net session >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo Requesting administrator privileges...
rem Path and arguments go through environment variables so quotes or apostrophes in
rem them cannot break out of the PowerShell command string.
set "WF_SELF=%~f0"
set "WF_ARGS=%*"
rem CLI commands run under "cmd /k" so the elevated window stays open to show results.
powershell -NoProfile -Command "$q = [char]34; if ($env:WF_ARGS) { Start-Process -FilePath cmd.exe -ArgumentList ('/k ' + $q + $q + $env:WF_SELF + $q + ' ' + $env:WF_ARGS + $q) -Verb RunAs } else { Start-Process -FilePath $env:WF_SELF -Verb RunAs }"
exit /b

:elevated
if not "%~1"=="" goto :cli
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%WinForge.ps1" Gui
if errorlevel 1 (
    echo.
    echo WinForge exited with an error. See the message above.
    pause
)
exit /b %errorlevel%

:cli
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%WinForge.ps1" %*
exit /b %errorlevel%
