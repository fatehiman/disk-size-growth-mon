@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Android emulator: wipe data (DELETES apps and data inside your AVDs)"

rem ===========================================================================
rem  The equivalent of "Wipe Data" in the AVD Manager, done to every AVD at
rem  once, from outside the emulator.
rem
rem  This is NOT a cache cleanup. It deletes:
rem
rem    snapshots\              Quick Boot state
rem    userdata-qemu.img*      every app you installed in the emulator, every
rem                            login, every bit of app data
rem    cache.img*              /cache
rem    sdcard.img.qcow2        anything written to the virtual SD card
rem
rem  The AVDs themselves survive -- same name, same device profile, same API
rem  level. They just come back factory-fresh, and the first boot afterwards is
rem  a slow one while Android sets itself up again.
rem
rem  Usually the biggest single reclaim available on an Android dev machine, and
rem  usually harmless, because an emulator is a disposable test device. It is
rem  not harmless if you have a hard-to-reproduce state in there -- a
rem  half-finished test account, a build you cannot rebuild. Hence the prompt,
rem  which defaults to No.
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
echo === AVDs and what they are holding ===
set "FOUND="
set "COUNT=0"
for /d %%A in ("%AVDH%\*.avd") do call :measure "%%~A"
if not defined FOUND (
    echo   no AVDs found.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === confirm ===
echo A confirmation dialog has opened -- answer it to continue.
call "%HERE%_common.cmd" confirm "Factory-reset ALL %COUNT% emulator(s) on this machine?||Every app installed inside them, every login and all app data will be gone. The AVDs themselves stay, with the same name, device and API level.||This is the AVD Manager's Wipe Data, applied to all of them." "Wipe emulator data"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === wiping ===
for /d %%A in ("%AVDH%\*.avd") do call :wipe "%%~A"

echo.
echo The next launch of each emulator will take a while: Android is doing its
echo first-boot setup. That is expected, not a hang.

call "%HERE%_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:emurunning
for %%P in (emulator.exe qemu-system-x86_64.exe qemu-system-aarch64.exe qemu-system-i386.exe) do call :emucheck %%P
if defined EMU_UP (
    echo.
    echo   An emulator is running ^(%EMU_UP%^). Close it and run this again --
    echo   deleting its disk images while it has them open corrupts the AVD.
    exit /b 1
)
exit /b 0

:emucheck
call "%HERE%_common.cmd" running "%~1"
if not errorlevel 1 set "EMU_UP=%~1"
exit /b 0

:measure
set "FOUND=1"
set /a COUNT+=1
echo   %~nx1
call "%HERE%_common.cmd" dirsize "%~1"
exit /b 0

:wipe
echo   %~nx1
call "%HERE%_common.cmd" rmdir "%~1\snapshots"
rem The .qcow2 files are the copy-on-write deltas over the base images; the
rem plain .img files are those bases. Both go, and the emulator recreates them
rem from the system image on the next boot.
for %%F in (userdata-qemu.img userdata-qemu.img.qcow2 cache.img cache.img.qcow2 sdcard.img.qcow2) do call :rmfile "%~1\%%F"
rem Stale pointers to state that no longer exists.
del /f /a /q "%~1\quickbootChoice.ini"  > nul 2> nul
del /f /a /q "%~1\bootcompleted.ini"    > nul 2> nul
del /f /a /q "%~1\version_num.cache"    > nul 2> nul
exit /b 0

:rmfile
if not exist "%~1" exit /b 0
del /f /a /q "%~1" > nul 2> nul
if exist "%~1" (echo     in use, left alone: %~nx1) else (echo     deleted %~nx1)
exit /b 0
