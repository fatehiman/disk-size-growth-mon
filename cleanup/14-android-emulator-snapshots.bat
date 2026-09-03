@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Android emulator Quick Boot snapshots (keeps your apps and data)"

rem ===========================================================================
rem  An AVD directory is mostly saved state, not emulator:
rem
rem    snapshots\              Quick Boot memory image, one per snapshot. Often
rem                            the single biggest file on a dev machine.
rem    userdata-qemu.img.qcow2 installed apps and their data
rem    cache.img*              Android's /cache partition
rem    sdcard.img              the virtual SD card
rem
rem  This script deletes the snapshots and /cache only. Installed apps, logins
rem  and app data all survive. The only effect is that the next launch is a
rem  cold boot -- 30 seconds or so instead of a couple -- after which a fresh
rem  Quick Boot snapshot is saved and you are back where you were.
rem
rem  To reclaim the userdata image as well, see
rem  15-android-emulator-wipe-data.bat. That one does lose your apps.
rem ===========================================================================

set "AVDH=%ANDROID_AVD_HOME%"
if not defined AVDH set "AVDH=%USERPROFILE%\.android\avd"

if not exist "%AVDH%\" (
    echo No AVD directory at %AVDH% -- nothing to do.
    call "%HERE%_common.cmd" end
    exit /b 0
)
echo AVD home: %AVDH%

call :emurunning
if errorlevel 1 (
    call "%HERE%_common.cmd" end
    exit /b 1
)

echo.
echo === snapshots found ===
set "FOUND="
for /d %%A in ("%AVDH%\*.avd") do call :measure "%%~A"
if not defined FOUND (
    echo   none. Either there are no AVDs, or none has a saved snapshot.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === confirm ===
echo A confirmation dialog has opened -- answer it to continue.
call "%HERE%_common.cmd" confirm "Delete the Quick Boot snapshots listed in the output?||Your installed apps and their data are NOT touched. The next emulator launch is a cold boot, then a fresh snapshot is saved.||Any running emulator must be closed first." "Delete emulator snapshots"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === deleting ===
for /d %%A in ("%AVDH%\*.avd") do call :wipe_snapshots "%%~A"

call "%HERE%_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:emurunning
rem A running emulator holds the whole AVD directory open, and deleting a
rem snapshot out from under it corrupts the AVD rather than just failing.
for %%P in (emulator.exe qemu-system-x86_64.exe qemu-system-aarch64.exe qemu-system-i386.exe) do call :emucheck %%P
if defined EMU_UP (
    echo.
    echo   An emulator is running ^(%EMU_UP%^). Close it and run this again --
    echo   deleting a snapshot while the emulator has it open corrupts the AVD.
    exit /b 1
)
exit /b 0

:emucheck
call "%HERE%_common.cmd" running "%~1"
if not errorlevel 1 set "EMU_UP=%~1"
exit /b 0

:measure
if not exist "%~1\snapshots\" exit /b 0
set "FOUND=1"
call "%HERE%_common.cmd" dirsize "%~1\snapshots"
exit /b 0

:wipe_snapshots
echo   %~nx1
call "%HERE%_common.cmd" rmdir "%~1\snapshots"
rem /cache is regenerated on boot like any Android cache partition.
del /f /a /q "%~1\cache.img.qcow2" > nul 2> nul
del /f /a /q "%~1\cache.img" > nul 2> nul
rem So the emulator does not try to resume from a snapshot that is now gone.
del /f /a /q "%~1\quickbootChoice.ini" > nul 2> nul
exit /b 0
