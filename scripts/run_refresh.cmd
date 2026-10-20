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

set /p "ACCOUNT=Account id [no last account yet, Enter = single-account mode]: "
goto afterask

:asklast
set /p "ACCOUNT=Account id [Enter = %LASTACC%, - = single-account mode]: "

:afterask
if defined ACCOUNT goto typed
goto runask

:typed
rem strip quotes so the id cannot break out of the argument
set "ACCOUNT=%ACCOUNT:"=%"
if "%ACCOUNT%"=="-" set "ACCOUNT="
if not defined ACCOUNT goto runask
rem Client rotates the token on every start; old one dies instantly
"py" -3 "%~dp0..\refresh_token.py" --gh-repo 1024210879/workbuddy_auto_checkin --account "%ACCOUNT%" --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"
set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh-%ACCOUNT%.log"
goto done

:runask
"py" -3 "%~dp0..\refresh_token.py" --gh-repo 1024210879/workbuddy_auto_checkin --ask-account --min-days 3 --wait 60 --log "%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"
set "LOGPATH=%LOCALAPPDATA%\workbuddy_auto_checkin\refresh.log"

:done
echo.
echo ---- done. log: %LOGPATH%
pause
exit /b 0
