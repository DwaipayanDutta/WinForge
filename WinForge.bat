@echo off
setlocal
rem WinForge launcher.
rem   Double-click (no arguments): opens the GUI.
rem   WinForge.bat <Command> [options]: runs the CLI, e.g. WinForge.bat Preview -Profile Minimal
rem goto is used instead of ( ) blocks so arguments containing ")" cannot break parsing.
set "WF_PS1=%~dp0WinForge.ps1"
set "WF_ARGS=%*"

rem fltmc needs administrator rights but, unlike "net session", does not depend on the
rem Server service, so it cannot report "not elevated" inside an elevated window.
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :elevated

echo Requesting administrator privileges...
rem Elevate powershell.exe -File WinForge.ps1 directly, never this .bat again: there is no
rem relaunch loop, and no cmd.exe parses the arguments, so "&", "|" or ")" in them stay
rem plain text. After -File, powershell.exe hands every argument to the script as a string.
rem Paths and arguments reach PowerShell through environment variables, not the command.
powershell -NoProfile -Command "$q = [char]34; $argList = '-NoProfile -ExecutionPolicy Bypass '; if ($env:WF_ARGS) { $argList += '-NoExit -File ' + $q + $env:WF_PS1 + $q + ' ' + $env:WF_ARGS } else { $argList += '-File ' + $q + $env:WF_PS1 + $q + ' Gui' }; try { Start-Process -FilePath powershell.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Elevation was cancelled or failed:' $_.Exception.Message; exit 1 }"
if errorlevel 1 pause
exit /b

:elevated
if not "%~1"=="" goto :cli
powershell -NoProfile -ExecutionPolicy Bypass -File "%WF_PS1%" Gui
if errorlevel 1 (
    echo.
    echo WinForge exited with an error. See the message above.
    pause
)
exit /b %errorlevel%

:cli
powershell -NoProfile -ExecutionPolicy Bypass -File "%WF_PS1%" %*
exit /b %errorlevel%
