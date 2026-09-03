@echo off
rem ===========================================================================
rem  Shared prologue/epilogue for the cleanup scripts.
rem
rem  Deliberately a .cmd, not a .bat: the app lists *.bat, so this never shows
rem  up as something you can run on its own.
rem
rem  Usage:
rem
rem      call "%~dp0_common.cmd" begin "What this script does"
rem      ... work ...
rem      call "%~dp0_common.cmd" end
rem
rem  Free space is measured in whole MB rather than bytes because cmd's SET /A
rem  is 32-bit signed -- a byte count on any modern disk overflows it.
rem ===========================================================================

if /i "%~1"=="begin" goto begin
if /i "%~1"=="end"   goto end
if /i "%~1"=="rmdir" goto rmdir_action
echo _common.cmd: unknown action "%~1"
exit /b 1

:rmdir_action
rem Removes a cache directory, reporting rather than failing when it is absent
rem or partly locked. Never removes the directory it was pointed at if that is a
rem drive root -- a typo in a caller should not eat a volume.
if "%~2"=="" echo   ^(no path given^) & exit /b 0
if "%~2"=="%~d2\" echo   refusing to remove drive root %~2 & exit /b 1
if not exist "%~2\" echo   not present: %~2 & exit /b 0
echo   removing %~2
rd /s /q "%~2" 2> nul
if exist "%~2\" echo   ^(partly in use, some files were left behind^)
exit /b 0

:begin
rem UTF-8, so the app decodes the output correctly.
chcp 65001 > nul
call :freemb _dsm_before
echo ---------------------------------------------------------------------------
echo  %~2
echo  free on %SystemDrive% at start: %_dsm_before% MB
echo ---------------------------------------------------------------------------
exit /b 0

:end
call :freemb _dsm_after
echo.
echo ---------------------------------------------------------------------------
rem No parenthesised if/else here: cmd expands a whole block at parse time, so a
rem variable SET inside the block reads as empty later in the same block.
if not defined _dsm_before goto end_plain
if not defined _dsm_after  goto end_plain
set /a _dsm_gain=%_dsm_after% - %_dsm_before%
goto end_summary

:end_plain
echo  done.
goto end_done

:end_summary
echo  free on %SystemDrive% now: %_dsm_after% MB  ^(%_dsm_gain% MB reclaimed^)
echo  Zero or negative is normal: other processes write while this runs, and
echo  some cleanups only take effect after a restart.

:end_done
echo ---------------------------------------------------------------------------
set "_dsm_before="
set "_dsm_after="
set "_dsm_gain="
exit /b 0

:freemb
rem Sets the variable named by %1 to free MB on the system drive. Leaves it
rem undefined if PowerShell is unavailable, which the caller tolerates.
set "%~1="
for /f "usebackq delims=" %%F in (`powershell -NoProfile -NonInteractive -Command "[int]((Get-PSDrive ($env:SystemDrive[0])).Free/1MB)" 2^> nul`) do set "%~1=%%F"
exit /b 0
