@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Windows Disk Cleanup (cleanmgr), unattended, safe handlers only"

rem ===========================================================================
rem  cleanmgr has no command line for choosing categories directly. The
rem  supported way is:
rem
rem    1. write StateFlags<NNNN> = 2 under each handler you want, in
rem       HKLM\...\VolumeCaches\<handler>
rem    2. run `cleanmgr /sagerun:NNNN`, which runs every handler flagged 2
rem
rem  This script writes the flags itself, so there is no `cleanmgr /sageset`
rem  dialog to click through. Profile 4242 is used, which nothing else claims.
rem
rem  Handlers are opt-in, listed below. Deliberately excluded:
rem    - "Previous Installations"       (deletes Windows.old = no rollback)
rem    - "Windows ESD installation..."  (needed by Reset This PC)
rem    - "Downloaded Program Files"     (can break old ActiveX-based tooling)
rem    - "Recycle Bin"                  (see 08-recycle-bin.bat instead)
rem ===========================================================================

net session > nul 2>&1
if errorlevel 1 (
    echo This script needs to run elevated. Run it from the app's Cleanup dialog.
    call "%~dp0_common.cmd" end
    exit /b 1
)

set "PROFILE=4242"
set "VC=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"

echo.
echo === flagging handlers for /sagerun:%PROFILE% ===
rem Clear every handler first, so a leftover flag from a previous profile 4242
rem run (or from someone's /sageset) cannot quietly widen what gets deleted.
for /f "tokens=*" %%K in ('reg query "%VC%" 2^> nul') do reg add "%%K" /v StateFlags%PROFILE% /t REG_DWORD /d 0 /f > nul 2> nul

call :enable "Temporary Files"
call :enable "Temporary Setup Files"
call :enable "Thumbnail Cache"
call :enable "Delivery Optimization Files"
call :enable "Update Cleanup"
call :enable "Windows Error Reporting Files"
call :enable "Windows Error Reporting Queue Files"
call :enable "Windows Error Reporting System Archive Files"
call :enable "Windows Error Reporting System Queue Files"
call :enable "Windows Error Reporting Archive Files"
call :enable "System error memory dump files"
call :enable "System error minidump files"
call :enable "Device Driver Packages"
call :enable "Old ChkDsk Files"
call :enable "Setup Log Files"
call :enable "Offline Pages Files"
call :enable "Internet Cache Files"
call :enable "D3D Shader Cache"
call :enable "Diagnostic Data Viewer database files"
call :enable "Feedback Hub Archive log files"
call :enable "Language Pack"

echo.
echo === running cleanmgr /sagerun:%PROFILE% ===
echo This shows a small progress window and can take several minutes.
echo cleanmgr prints nothing of its own, so expect no output until it exits.
rem /d %SystemDrive% keeps it on the system drive; without it cleanmgr does all
rem of them, which is slower and not what this script claims to do.
cleanmgr /sagerun:%PROFILE% /d %SystemDrive%

rem cleanmgr re-launches itself and the first process exits straight away, so
rem without this the script would report "done" while the real work is still
rem going -- and the free-space summary would be meaningless.
rem
rem `ping` rather than `timeout`: timeout refuses to run when stdin is
rem redirected, which it always is when the app captures this output.
echo Waiting for cleanmgr to finish...
:wait_cleanmgr
ping -n 4 127.0.0.1 > nul
tasklist /fi "imagename eq cleanmgr.exe" 2> nul | find /i "cleanmgr.exe" > nul
if not errorlevel 1 goto wait_cleanmgr
echo cleanmgr has exited.

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:enable
rem A handler that does not exist on this Windows build is simply not there;
rem that is normal and not worth shouting about.
reg query "%VC%\%~1" > nul 2>&1
if errorlevel 1 echo   n/a on this build: %~1 & exit /b 0
reg add "%VC%\%~1" /v StateFlags%PROFILE% /t REG_DWORD /d 2 /f > nul
if errorlevel 1 (echo   could not flag: %~1) else (echo   enabled: %~1)
exit /b 0
