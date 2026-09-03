@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Temp folders: per-user %%TEMP%%, C:\Windows\Temp, crash dumps, INetCache"

rem ===========================================================================
rem  The contents of the temp folders are deleted; the folders themselves stay,
rem  because plenty of software assumes they exist and never re-creates them.
rem
rem  Files currently open by a running process cannot be deleted and are
rem  reported as skipped. That is expected -- do not read it as a failure.
rem ===========================================================================

echo.
echo === %TEMP% ===
rem %TEMP%\.net is where a single-file .NET app extracts its native libraries --
rem including the SQLite library this very tool has loaded. Pulling it out from
rem under a running process is asking for trouble, so it is left alone.
call :emptydir "%TEMP%" ".net"

echo.
echo === %SystemRoot%\Temp ===
call :emptydir "%SystemRoot%\Temp"

echo.
echo === Crash dumps and error reports ===
rem WER queues .wer reports and full-memory .dmp files here; a single dump can
rem be gigabytes. Only useful if you are actively debugging a crash.
call :emptydir "%LOCALAPPDATA%\CrashDumps"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue"
call "%~dp0_common.cmd" rmdir "%ProgramData%\Microsoft\Windows\WER\ReportArchive"
call "%~dp0_common.cmd" rmdir "%ProgramData%\Microsoft\Windows\WER\ReportQueue"

echo.
echo === Internet Explorer / WinINet cache ===
rem Still used by any app that renders HTML through the old WebBrowser control,
rem which is more of them than you would guess.
call :emptydir "%LOCALAPPDATA%\Microsoft\Windows\INetCache"

rem The Delivery Optimization cache lives in 04-windows-update-cache.bat, which
rem stops the service that holds those files open first.

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:emptydir
rem Deletes the contents of a directory but keeps the directory itself.
rem %2, if given, is the name of one immediate subdirectory to leave alone.
rem
rem Top-level files are deleted without /s and subdirectories are removed one at
rem a time, so the excluded subdirectory really is excluded -- `del /s` would
rem have recursed straight into it.
if not exist "%~1\" echo   not present: %~1 & exit /b 0
echo   emptying %~1
if not "%~2"=="" echo   keeping %~2\
del /f /a /q "%~1\*" > nul 2> nul
for /d %%D in ("%~1\*") do call :rmsub "%%~D" "%~2"
echo   done ^(anything still open by a running process was skipped^)
exit /b 0

:rmsub
if /i "%~nx1"=="%~2" exit /b 0
rd /s /q "%~1" 2> nul
exit /b 0
