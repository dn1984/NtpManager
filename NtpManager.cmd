@echo off
rem ===========================================================================
rem  NtpManager - portable NTP server/client monitoring and management tool
rem  Target OS: Windows Server 2008 R2 (also works on Windows Vista..11)
rem
rem  This launcher is intentionally ASCII-only: cmd.exe renders text using an
rem  OEM code page, so all Russian messages are printed by NtpManager.ps1
rem  (which is stored as UTF-8 with BOM). Do not translate these lines.
rem
rem  No arguments   -> graphical interface (elevation is requested automatically)
rem  With arguments -> passed to NtpManager.ps1, for example:
rem                    NtpManager.cmd -Report
rem                    NtpManager.cmd -Help
rem                    NtpManager.cmd -Apply -ServerList "192.168.1.50,0x9" ^
rem                        -EnableServer -EnableClient -Reliable -PollInterval 300 -OpenFirewall
rem ===========================================================================
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0NtpManager.ps1"

if not exist "%PS%" (
    echo ERROR: PowerShell not found: %PS%
    pause
    exit /b 3
)
if not exist "%SCRIPT%" (
    echo ERROR: NtpManager.ps1 must be placed next to this launcher.
    echo Expected path: %SCRIPT%
    pause
    exit /b 3
)

if "%~1"=="" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
    exit /b %ERRORLEVEL%
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
