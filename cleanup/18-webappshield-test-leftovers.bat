@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "WebAppShield test-run leftovers: .NET single-file extraction cache and per-run WebView2 profiles"

rem ===========================================================================
rem  win-webapp-shield's smoke-test.ps1 starts many disposable copies of the
rem  wrapper exe -- 24 configs per run. Every copy gets its own single-file
rem  .NET extraction folder under %TEMP%\.net and its own WebView2 profile
rem  folder under %LOCALAPPDATA%\WinWebAppShield, named
rem  "<exe-basename>-<hash-of-full-exe-path>". A throwaway test copy makes a
rem  new hash every time, none of it is reused between runs, and after a round
rem  of testing this is thousands of folders and several GB doing nothing.
rem
rem  %TEMP%\.net also holds the extraction folder of whatever self-contained
rem  .NET app happens to be running right now -- this tool included -- and
rem  WinWebAppShield may hold the profile of a wrapped app you actually use.
rem  Both stay open while their process is alive, so `rd /s /q` simply fails
rem  on that one folder and moves on to the rest; nothing needs to be excluded
rem  by name the way 03-temp-files.bat excludes ".net" wholesale to stay
rem  simple.
rem ===========================================================================

echo.
echo === %TEMP%\.net ===
call :nukesubfolders "%TEMP%\.net"

echo.
echo === %LOCALAPPDATA%\WinWebAppShield ===
call :nukesubfolders "%LOCALAPPDATA%\WinWebAppShield"

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:nukesubfolders
rem Removes every immediate subdirectory of %1, one at a time, so a folder
rem still open in another process is skipped instead of aborting the rest.
if not exist "%~1\" echo   not present: %~1 & exit /b 0
echo   clearing %~1
for /d %%D in ("%~1\*") do rd /s /q "%%~D" 2> nul
echo   done ^(anything still open by a running process was skipped^)
exit /b 0
