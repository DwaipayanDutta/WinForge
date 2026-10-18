@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    rem Pass the path and arguments through environment variables so quotes or
    rem apostrophes in them cannot break out of the PowerShell command string.
    set "WF_SELF=%~f0"
    set "WF_ARGS=%*"
    powershell -NoProfile -Command "if ($env:WF_ARGS) { Start-Process -FilePath $env:WF_SELF -ArgumentList $env:WF_ARGS -Verb RunAs } else { Start-Process -FilePath $env:WF_SELF -Verb RunAs }"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%WinForge.ps1" %*
exit /b %errorlevel%
