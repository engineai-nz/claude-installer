@echo off
setlocal

rem ===========================================================================
rem  Engine AI Claude Installer - Windows double-click wrapper
rem
rem  Downloads and runs installer/install.ps1 from GitHub with administrator
rem  rights. Safe to double-click from Explorer - no PowerShell knowledge
rem  needed. ExecutionPolicy Bypass is applied to the child PowerShell process
rem  only; nothing about the machine's policy is changed.
rem
rem  Usage (optional):
rem    install.bat --industry property --stack google
rem ===========================================================================

set "PS_URL=https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.ps1"
set "PS_LOCAL=%TEMP%\engineai-install.ps1"
set "SELF=%~f0"
set "INDUSTRY=property"
set "STACK=google"
set "ELEVATED=0"

rem PS_SHA256 pins the exact installer script this wrapper is allowed to run.
rem Leave it empty to track the main branch. For a client release, publish the
rem SHA256 of installer/install.ps1 and paste it here: the download is then
rem rejected unless it matches, which stops a tampered or intercepted copy
rem running with administrator rights.
set "PS_SHA256="

rem ---- Read command line ----------------------------------------------------
:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--industry" (
  set "INDUSTRY=%~2"
  shift
  shift
  goto parse
)
if /i "%~1"=="--stack" (
  set "STACK=%~2"
  shift
  shift
  goto parse
)
if /i "%~1"=="--elevated" (
  set "ELEVATED=1"
  shift
  goto parse
)
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
if /i "%~1"=="/?" goto usage
echo Unknown option: %~1
echo.
goto usage

:parsed
if not defined INDUSTRY goto missingvalue
if not defined STACK goto missingvalue

rem ---- Check the values are ones we know about ------------------------------
rem Both values end up on a PowerShell command line that runs as administrator,
rem so only known-good words are allowed through. The check is written as a
rem flag that starts at 0: anything odd in the value leaves the flag at 0 and
rem the install stops, rather than being passed along.
set "OK_INDUSTRY=0"
if /i "%INDUSTRY%"=="property" set "OK_INDUSTRY=1"
if not "%OK_INDUSTRY%"=="1" goto badindustry

set "OK_STACK=0"
if /i "%STACK%"=="google" set "OK_STACK=1"
if /i "%STACK%"=="microsoft" set "OK_STACK=1"
if not "%OK_STACK%"=="1" goto badstack

rem ---- Banner ---------------------------------------------------------------
echo.
echo  ==========================================================
echo    Engine AI - Claude Installer
echo  ==========================================================
echo.
echo    Sets up Claude Desktop and Claude Code on this PC.
echo    Takes about 5 minutes. Leave this window open.
echo.
echo    Industry: %INDUSTRY%
echo    Stack:    %STACK%
echo.
echo    (Change these with: install.bat --industry ^<name^> --stack ^<name^>)
echo.

rem ---- Administrator check --------------------------------------------------
rem IsInRole returns False on a UAC-filtered token, which is exactly the
rem question being asked here: are we running elevated right now.
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if not errorlevel 1 goto isadmin

rem --elevated is a loop guard. If we have already been relaunched and are
rem still not admin, stop rather than prompt for UAC over and over.
if "%ELEVATED%"=="1" (
  echo    [X] Still not running as administrator after elevating.
  echo.
  echo        This account may not be allowed to install software.
  echo        Ask whoever manages this PC for an administrator account.
  goto failed
)

echo    Asking Windows for administrator rights...
echo    Choose Yes on the User Account Control prompt.
echo.
rem The path to this file is handed over in the SELF environment variable
rem rather than pasted into the command text, so folder names containing an
rem apostrophe (C:\Users\Sam O'Brien\...) still work.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SELF -ArgumentList '--industry','%INDUSTRY%','--stack','%STACK%','--elevated' -Verb RunAs"
if errorlevel 1 (
  echo    [X] Could not get administrator rights.
  echo.
  echo        Right-click install.bat and pick "Run as administrator".
  goto failed
)

rem The elevated copy owns the install from here. It has its own window and
rem does its own pause, so this one can close quietly.
endlocal
exit /b 0

:isadmin
rem ---- Connectivity ---------------------------------------------------------
echo    Checking internet connection...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $null = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com' -Method Head -TimeoutSec 10 -UseBasicParsing; exit 0 } catch { exit 1 }"
if errorlevel 1 (
  echo    [X] No internet connection.
  echo.
  echo        This installer downloads Claude from the internet.
  echo        Connect to Wi-Fi or plug in a network cable, then try again.
  echo        On a work network a firewall may be blocking
  echo        raw.githubusercontent.com - ask your IT contact.
  goto failed
)
echo    [OK] Online
echo.

rem ---- Download the real installer ------------------------------------------
rem Saved to a file rather than piped straight into PowerShell, so it can be
rem checked before it runs and so PowerShell binds the options itself. The
rem timeout stops a captive portal leaving this window hanging forever.
echo    Downloading the installer...
if exist "%PS_LOCAL%" del /f /q "%PS_LOCAL%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri $env:PS_URL -OutFile $env:PS_LOCAL -UseBasicParsing -TimeoutSec 60; exit 0 } catch { exit 1 }"
if errorlevel 1 (
  echo    [X] Could not download the installer.
  echo.
  echo        The connection may have dropped, or a firewall may be
  echo        blocking raw.githubusercontent.com. Try again, and ask
  echo        your IT contact if it keeps failing.
  goto failed
)
if not exist "%PS_LOCAL%" (
  echo    [X] Could not download the installer.
  goto failed
)

rem ---- Check the download has not been tampered with ------------------------
if not defined PS_SHA256 goto runinstaller
powershell -NoProfile -ExecutionPolicy Bypass -Command "if ((Get-FileHash -LiteralPath $env:PS_LOCAL -Algorithm SHA256).Hash -eq $env:PS_SHA256) { exit 0 } else { exit 1 }"
if errorlevel 1 goto badhash

:runinstaller
rem ---- Run the real installer -----------------------------------------------
echo    Starting the installer. This can take a few minutes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_LOCAL%" -Industry %INDUSTRY% -Stack %STACK%
if errorlevel 1 goto failed
del /f /q "%PS_LOCAL%" >nul 2>&1

echo.
echo  ==========================================================
echo    Done. Claude Desktop should now be open.
echo  ==========================================================
echo.
echo    Next: sign in, then click the Cowork tab in the sidebar.
echo.
echo    Press any key to close this window.
pause >nul
endlocal
exit /b 0

:failed
del /f /q "%PS_LOCAL%" >nul 2>&1
echo.
echo  ==========================================================
echo    The install did not finish.
echo  ==========================================================
echo.
echo    Logs are in: %USERPROFILE%\.engineai-installer\logs
echo    Send the newest log file to your Engine AI contact.
echo.
echo    Press any key to close this window.
pause >nul
endlocal
exit /b 1

:badhash
del /f /q "%PS_LOCAL%" >nul 2>&1
echo.
echo    [X] The downloaded installer does not match the published version.
echo.
echo        Nothing has been installed. This can happen if the download
echo        was interrupted, or if something on the network changed the
echo        file. Try again on a different network, and tell your Engine
echo        AI contact if it happens twice.
echo.
echo    Press any key to close this window.
pause >nul
endlocal
exit /b 1

:missingvalue
echo.
echo    [X] --industry and --stack each need a value.
echo.
goto usage

:badindustry
echo.
echo    [X] That industry is not one we support.
echo.
echo        Supported: property
echo.
goto usage

:badstack
echo.
echo    [X] That stack is not one we support.
echo.
echo        Supported: google, microsoft
echo.
goto usage

:usage
echo Engine AI Claude Installer - Windows wrapper
echo.
echo Usage: install.bat [--industry ^<name^>] [--stack ^<name^>]
echo.
echo   --industry   Industry bundle: property (default: property)
echo   --stack      Productivity stack: google ^| microsoft (default: google)
echo   --help       Show this message
echo.
echo Double-click install.bat to use the defaults.
echo.
echo Press any key to close this window.
pause >nul
endlocal
exit /b 2
