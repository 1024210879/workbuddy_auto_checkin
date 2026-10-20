@echo off
setlocal
rem Single entry point for the WorkBuddy token sync. Two modes:
rem   no argument  = manual (console): ask the account, push, pause before closing
rem   --auto       = background (logon .vbs): account from setup_task.ps1 -Account
rem The "--auto" block is appended by setup_task.ps1 and stripped on -Uninstall.
rem This file must stay ASCII: it is written with ASCII encoding, non-ASCII -> "?".
if /i "%~1"=="--auto" goto auto

title WorkBuddy token sync
rem last_account.txt is a one-line mirror written by refresh_token.py:
rem   LINJJ           = the account used last time (shown in the prompt below)
rem   -               = last run was single-account mode
rem   (file missing)  = never synced on this machine
set "LASTACC="
if exist "%LOCALAPPDATA%\workbuddy_auto_checkin\last_account.txt" for /f "usebackq delims=" %%L in ("%LOCALAPPDATA%\workbuddy_auto_checkin\last_account.txt") do set "LASTACC=%%L"
if "%LASTACC%"=="-" set "LASTACC="
if defined LASTACC goto asklast

set /p "ACCOUNT=Account id [no last account yet, Enter = single-account mode, Secret WB_ACCESS_TOKEN]: "
goto afterask

:asklast
set /p "ACCOUNT=Account id [Enter = %LASTACC% -> Secret WB_ACCESS_TOKEN_%LASTACC%, - = single-account]: "

:afterask
if defined ACCOUNT goto typed
goto runask

:typed
rem strip quotes so the id cannot break out of the argument
set "ACCOUNT=%ACCOUNT:"=%"
if "%ACCOUNT%"=="-" set "ACCOUNT="
if not defined ACCOUNT goto runask
echo Target Secret: WB_ACCESS_TOKEN_%ACCOUNT%
rem Client rotates the token on every start; old one dies instantly
"py" -3 "%~dp0..\refresh_token.py" --gh-repo 1024210879/workbuddy_auto_checkin --account "%ACCOUNT%" --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"
rem Capture RC on the very next line: any other command (even "set") resets ERRORLEVEL
set "RC=%ERRORLEVEL%"
set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"
goto done

:runask
"py" -3 "%~dp0..\refresh_token.py" --gh-repo 1024210879/workbuddy_auto_checkin --ask-account --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"
set "RC=%ERRORLEVEL%"
set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"

:done
echo.
echo ---- done, exit code %RC%. log: %LOGPATH%
rem refresh_token.py exit codes: 0 ok / 3 not fresher (skipped) / 4 expired /
rem 5 account mismatch on this machine. Ask the script what to do next:
rem   py -3 "%~dp0..\refresh_token.py" --gh-repo 1024210879/workbuddy_auto_checkin --account ID --status
if "%RC%"=="5" echo [next] WRONG ACCOUNT: this PC is not logged in as that account. Log the right one into WorkBuddy, or add --force if you really mean to overwrite.
if "%RC%"=="4" echo [next] TOKEN EXPIRED: open WorkBuddy so it renews the credential, then run this again.
if "%RC%"=="3" echo [next] NOT FRESHER: the Secret already holds an equal-or-newer token. Open WorkBuddy to rotate, then run this again.
if "%RC%"=="0" echo [next] Pushed or unchanged. Trigger the workflow on GitHub to confirm; a still-401 card now names the Secret and the machine that owns it.
pause
exit /b 0
