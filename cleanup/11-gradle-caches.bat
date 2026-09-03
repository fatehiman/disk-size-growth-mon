@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Gradle derived caches (~%%GRADLE_USER_HOME%%\caches, minus the downloads)"

rem ===========================================================================
rem  What C:\Users\<you>\.gradle actually is
rem  ---------------------------------------
rem  Gradle's per-user home. Nothing in it is your source code; it is entirely
rem  things Gradle downloaded or computed so it would not have to again:
rem
rem    caches\modules-2      dependency jars downloaded from Maven Central etc.
rem    caches\jars-N         instrumented copies of plugin/build classpath jars
rem    caches\transforms-N   outputs of artifact transforms (AAR -> JAR, ...)
rem    caches\<version>      per-Gradle-version compiled build scripts, Kotlin
rem                          DSL accessors, file hashes, execution history
rem    caches\build-cache-N  the local build cache (task outputs)
rem    wrapper\dists         whole Gradle distributions the wrapper downloaded
rem    daemon                daemon logs, one folder per version
rem
rem  This script deletes the DERIVED half: everything under caches\ except
rem  modules-2 (real downloads) and journal-1 (cache bookkeeping), plus daemon
rem  logs and scratch dirs. Gradle rebuilds all of it. The cost is one slower
rem  build per project, with no re-downloading.
rem
rem  For modules-2 and wrapper\dists -- the half that costs a re-download --
rem  see 12-gradle-deep-clean.bat.
rem ===========================================================================

set "GUH=%GRADLE_USER_HOME%"
if not defined GUH set "GUH=%USERPROFILE%\.gradle"

if not exist "%GUH%\" (
    echo No Gradle home at %GUH% -- nothing to do.
    call "%HERE%_common.cmd" end
    exit /b 0
)
echo Gradle home: %GUH%

rem A running daemon holds file locks under caches\, so deletions would half
rem succeed and leave the cache in a state Gradle has to repair anyway.
echo.
echo === stopping Gradle daemons ===
where gradle > nul 2>&1
if errorlevel 1 (echo   gradle not on PATH; skipping --stop) else (call gradle --stop)
call "%HERE%_common.cmd" running "java.exe"
if not errorlevel 1 echo   note: java.exe is still running. If a build or an IDE is using
if not errorlevel 1 echo   Gradle right now, some folders below will refuse to delete.

echo.
echo === caches ===
for /d %%D in ("%GUH%\caches\*") do call :cache_dir "%%~D"

echo.
echo === daemon logs and scratch ===
call "%HERE%_common.cmd" rmdir "%GUH%\daemon"
call "%HERE%_common.cmd" rmdir "%GUH%\.tmp"
call "%HERE%_common.cmd" rmdir "%GUH%\workers"
call "%HERE%_common.cmd" rmdir "%GUH%\kotlin-profile"
call "%HERE%_common.cmd" rmdir "%GUH%\notifications"

echo.
echo === kept on purpose ===
call "%HERE%_common.cmd" dirsize "%GUH%\caches\modules-2"
call "%HERE%_common.cmd" dirsize "%GUH%\wrapper\dists"
echo   Both are downloads, not derived data. 12-gradle-deep-clean.bat clears
echo   them if you would rather have the space than the next fast build.

call "%HERE%_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:cache_dir
rem %HERE%, captured at the top, rather than %~dp0: inside a CALLed subroutine
rem %0 is the label (":cache_dir"), and while %~dp0 does still resolve to the
rem script's folder, relying on that is a bet on a quirk. One variable is
rem clearer than a footnote.
if /i "%~nx1"=="modules-2" echo   keeping modules-2 ^(downloaded dependencies^) & exit /b 0
if /i "%~nx1"=="journal-1" echo   keeping journal-1 ^(cache bookkeeping^) & exit /b 0
call "%HERE%_common.cmd" rmdir "%~1"
exit /b 0
