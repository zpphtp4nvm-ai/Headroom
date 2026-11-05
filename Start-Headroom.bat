@echo off
rem Opens Headroom (the Windows 11 gaming settings window) as administrator.
rem Keep this file in the same folder as Headroom_79.ps1.
rem (For the command-line options, open an administrator PowerShell and run the .ps1 with -NoGui instead.)
cd /d "%~dp0"
rem Is this window running as administrator? PowerShell is asked, because the usual "net session" test fails
rem whenever the Server service is off (which is what "File and printer sharing off" does).
powershell -NoProfile -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if %errorlevel% neq 0 (
    if /i "%~1"=="elevated" (
        echo Windows did not give this window administrator rights, so the settings window cannot open.
        echo Run this file again and choose Yes in the permission box, or open an administrator PowerShell and run the .ps1 file.
        pause
        exit /b 1
    )
    echo Asking Windows for administrator permission...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
    exit /b
)
if not exist "%~dp0Headroom_79.ps1" (
    echo Cannot find Headroom_79.ps1 next to this file.
    pause
    exit /b 1
)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Headroom_79.ps1"
