@echo off
rem ===========================================================================
rem  NtpManager - quick status report (read-only, no administrator rights needed)
rem  Double-click this file to read the report; the window stays open.
rem  The report is also written to a text file next to the utility.
rem  Non-interactive use (Task Scheduler) is better done directly, for example:
rem    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ^
rem        "C:\NtpManager\NtpManager.ps1" -Report -ReportFile "C:\NtpManager\status.txt"
rem ===========================================================================
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0NtpManager.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: NtpManager.ps1 must be placed next to this launcher.
    echo Expected path: %SCRIPT%
    pause
    exit /b 3
)

title NTP Manager - status report
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Report -ReportFile "%~dp0NtpManager-status.txt"
set "RC=%ERRORLEVEL%"
echo.
echo ===========================================================================
pause
exit /b %RC%
