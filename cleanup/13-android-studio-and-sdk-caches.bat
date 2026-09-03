@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Android Studio indexes and logs, Android SDK scratch dirs"

rem ===========================================================================
rem  Two separate things live under different roots, and only one of them is
rem  disposable:
rem
rem    %LOCALAPPDATA%\Google\AndroidStudio<ver>\   caches, indexes, logs
rem    %APPDATA%\Google\AndroidStudio<ver>\        your settings and keymaps
rem
rem  Only the first is touched, and only these subfolders of it. Settings,
rem  installed plugins and Local History (the IDE's own undo-past-a-restart
rem  record, which is a recovery feature, not a cache) are left alone.
rem
rem  Cost: the next project open re-indexes, which takes a few minutes on a
rem  large project. Nothing is lost.
rem
rem  The SDK itself is NOT pruned here. Old build-tools, unused system images
rem  and extra platforms are worth gigabytes, but "unused" is not something a
rem  script can determine -- an AVD or a project's compileSdk may need any of
rem  them. They are measured and reported at the end so you can prune with the
rem  SDK Manager, which knows what depends on what.
rem ===========================================================================

echo.
echo === Android Studio ===
call "%HERE%_common.cmd" running "studio64.exe"
if not errorlevel 1 (
    echo   Android Studio is running. Its index and caches are locked open, so
    echo   most of this would fail. Close it and run this again.
    goto sdk
)

set "FOUND="
for /d %%S in ("%LOCALAPPDATA%\Google\AndroidStudio*") do call :studio "%%~S"
if not defined FOUND echo   no Android Studio cache directory found.

:sdk
echo.
echo === Android SDK ===
set "SDK=%ANDROID_HOME%"
if not defined SDK set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"

if not exist "%SDK%\" (
    echo   no SDK at %SDK%; set ANDROID_HOME if yours is elsewhere.
    goto avdreport
)
echo SDK: %SDK%

rem Half-finished downloads and unpack scratch space. The SDK Manager leaves
rem these behind when an install is cancelled or fails.
call "%HERE%_common.cmd" rmdir "%SDK%\.temp"
call "%HERE%_common.cmd" rmdir "%SDK%\temp"
call "%HERE%_common.cmd" rmdir "%SDK%\.downloadIntermediates"

echo.
echo === ~\.android ===
rem Repository manifests and AVD scratch. Not the AVDs themselves.
call "%HERE%_common.cmd" rmdir "%USERPROFILE%\.android\cache"
rem Left by Studio 3.x; harmless to remove if this machine still has one.
call "%HERE%_common.cmd" rmdir "%USERPROFILE%\.android\build-cache"

:avdreport
echo.
echo === big things left alone, for you to prune by hand ===
call "%HERE%_common.cmd" dirsize "%SDK%\system-images"
call "%HERE%_common.cmd" dirsize "%SDK%\build-tools"
call "%HERE%_common.cmd" dirsize "%SDK%\platforms"
call "%HERE%_common.cmd" dirsize "%SDK%\sources"
call "%HERE%_common.cmd" dirsize "%SDK%\emulator"
call "%HERE%_common.cmd" dirsize "%USERPROFILE%\.android\avd"
echo.
echo   system-images / build-tools / platforms: prune in Android Studio under
echo     Settings ^> Languages ^& Frameworks ^> Android SDK ^> SDK Platforms and
echo     SDK Tools, ticking "Show Package Details" to see every version.
echo   sources: the framework source you step into from the IDE. Re-downloadable
echo     from the same screen if you decide you do not want it.
echo   avd: your emulators. See 14-android-emulator-snapshots.bat and
echo     15-android-emulator-wipe-data.bat -- most of the size is not the
echo     emulator, it is its saved state.

call "%HERE%_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:studio
set "FOUND=1"
echo   %~1
rem Named subfolders only. Deleting the whole directory would take LocalHistory,
rem projects (per-project window state) and installed plugins with it.
call "%HERE%_common.cmd" rmdir "%~1\index"
call "%HERE%_common.cmd" rmdir "%~1\caches"
call "%HERE%_common.cmd" rmdir "%~1\log"
call "%HERE%_common.cmd" rmdir "%~1\tmp"
call "%HERE%_common.cmd" rmdir "%~1\compile-server"
call "%HERE%_common.cmd" rmdir "%~1\global-model-cache"
call "%HERE%_common.cmd" rmdir "%~1\splash"
call "%HERE%_common.cmd" rmdir "%~1\extResources"
del /f /a /q "%~1\gmaven.index" > nul 2> nul
del /f /a /q "%~1\icon-cache-v1.db" > nul 2> nul
exit /b 0
