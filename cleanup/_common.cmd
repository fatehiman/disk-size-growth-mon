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

if /i "%~1"=="begin"   goto begin
if /i "%~1"=="end"     goto end
if /i "%~1"=="rmdir"   goto rmdir_action
if /i "%~1"=="confirm" goto confirm_action
if /i "%~1"=="running" goto running_action
if /i "%~1"=="dirsize" goto dirsize_action
if /i "%~1"=="close"   goto close_action
if /i "%~1"=="kill"    goto kill_action
echo _common.cmd: unknown action "%~1"
exit /b 1

:confirm_action
rem Asks yes/no in a GUI dialog and returns 0 for yes, 1 for no.
rem
rem A dialog rather than `set /p`: the app runs these scripts with stdin closed,
rem so that a script which reads input gets EOF instead of hanging forever --
rem which would make `set /p` auto-answer "no" every single time.
rem
rem %2 = message, "|" in it becomes a line break. %3 = title.
rem Defaults to No, so a stray Enter cancels rather than proceeds.
rem
rem The text goes through the environment rather than being interpolated into
rem the PowerShell command line. Interpolating it looks simpler and is wrong:
rem an apostrophe in the message ("Gradle's downloads") closes PowerShell's
rem single-quoted string, the command dies with a parse error, and the caller
rem reads the non-zero exit as "the user said no" -- so the script silently
rem does nothing, every time. Environment variables need no quoting at all.
set "DSM_MSG=%~2"
set "DSM_TITLE=%~3"
powershell -NoProfile -NonInteractive -Command "Add-Type -AssemblyName System.Windows.Forms; $m=$env:DSM_MSG -replace '\|',[string][char]10; $r=[System.Windows.Forms.MessageBox]::Show($m,$env:DSM_TITLE,'YesNo','Warning','Button2'); if($r -eq 'Yes'){exit 0} else {exit 1}"
set "DSM_ANSWER=%ERRORLEVEL%"
set "DSM_MSG="
set "DSM_TITLE="
exit /b %DSM_ANSWER%

:running_action
rem 0 if a process with that image name is running, 1 if not. Used by the
rem scripts that must not touch files an IDE or emulator has open.
tasklist /fi "imagename eq %~2" 2> nul | find /i "%~2" > nul
exit /b %ERRORLEVEL%

:close_action
rem Asks every process with image name %2 to close, then waits up to %3 seconds
rem for them all to go. Returns 0 if the name is gone, 1 if something is left.
rem
rem `taskkill` WITHOUT /f, i.e. a WM_CLOSE to each window, so the app shuts down
rem the way it would if you clicked the X: a browser writes its session out and
rem offers to restore your tabs next launch. /f skips all of that.
rem
rem A browser is dozens of processes and only the parent has a window; the
rem renderers and the GPU process exit on their own once it does. So this polls
rem the image name rather than assuming one round of WM_CLOSE emptied it.
rem
rem Best-effort by nature. Chrome and Firefox are classic Win32 processes and do
rem honour it, but a packaged/Store app (Windows 11's Notepad, for one) can sit
rem there ignoring WM_CLOSE indefinitely, and so can any app showing a "save
rem changes?" prompt. Callers must handle the 1 return rather than assume 0.
if not exist "%SystemRoot%\System32\tasklist.exe" exit /b 1
tasklist /fi "imagename eq %~2" 2> nul | find /i "%~2" > nul
if errorlevel 1 exit /b 0
echo   asking %~2 to close^(up to %~3s^)...
taskkill /im "%~2" > nul 2> nul
set "_dsm_left=%~3"
:close_wait
tasklist /fi "imagename eq %~2" 2> nul | find /i "%~2" > nul
if errorlevel 1 goto close_gone
if "%_dsm_left%"=="0" goto close_timeout
set /a _dsm_left-=1
rem ping, not timeout: timeout refuses to run with stdin redirected, which it
rem always is when the app is capturing this output.
ping -n 2 127.0.0.1 > nul
goto close_wait

:close_gone
set "_dsm_left="
echo   %~2 has closed.
exit /b 0

:close_timeout
set "_dsm_left="
echo   %~2 is still running after %~3s.
exit /b 1

:kill_action
rem Force-terminates the image name and everything it started. Only for when
rem :close has already been given a fair chance -- this one loses whatever the
rem app had not written to disk.
rem
rem Returns 0 if the name is gone afterwards, 1 if something survived, matching
rem :close. Note that `find`'s own exit code is the other way round (0 means it
rem found a match, i.e. the process is still there), so it is mapped rather than
rem passed through.
echo   force-closing %~2...
taskkill /f /t /im "%~2" > nul 2> nul
ping -n 4 127.0.0.1 > nul
tasklist /fi "imagename eq %~2" 2> nul | find /i "%~2" > nul
if errorlevel 1 goto kill_gone
echo   %~2 SURVIVED the force-close.
exit /b 1

:kill_gone
echo   %~2 is gone.
exit /b 0

:dirsize_action
rem Prints "<n> MB  <path>" for a directory, or nothing if it is absent. Used
rem for the "here is what is big, prune it yourself" reports.
if not exist "%~2\" exit /b 0
rem Path through the environment, for the same reason as :confirm_action -- a
rem user folder like C:\Users\O'Brien would otherwise break the PowerShell
rem string and report nothing.
set "DSM_DIR=%~2"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -NonInteractive -Command "'{0,9:N1} MB' -f (((Get-ChildItem -LiteralPath $env:DSM_DIR -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum)/1MB)" 2^> nul`) do echo   %%S  %~2
set "DSM_DIR="
exit /b 0

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
