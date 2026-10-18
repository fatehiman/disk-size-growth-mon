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
rem  .NET app happens to be running right now -- this tool included. It stays
rem  open while its process is alive, so `rd /s /q` simply fails on that one
rem  folder and moves on to the rest.
rem
rem  WinWebAppShield is different: it may hold the profile (the LOGIN) of a wrapped
rem  app you actually use, and a profile that is not running is not a leftover.
rem  Deleting it logged out every wrapped app once. So only the cache folders
rem  inside each profile are removed, never the profile itself.
rem ===========================================================================

echo.
echo === %TEMP%\.net ===
call :nukesubfolders "%TEMP%\.net"

echo.
echo === %LOCALAPPDATA%\WinWebAppShield  ^(caches only, logins are kept^) ===
call :clearcaches "%LOCALAPPDATA%\WinWebAppShield"

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:clearcaches
rem A profile folder under WinWebAppShield may be the login of a wrapped app you
rem really use, so it is NEVER removed. Only the cache folders inside it go; cookies,
rem Local Storage, IndexedDB, Session Storage and Service Worker are left alone.
if not exist "%~1\" echo   not present: %~1 & exit /b 0
echo   clearing caches in %~1
for /d %%P in ("%~1\*") do (
  for %%C in ("Default\Cache" "Default\Code Cache" "Default\GPUCache" "Default\DawnGraphiteCache" "Default\DawnWebGPUCache" "GrShaderCache" "GraphiteDawnCache" "ShaderCache" "component_crx_cache" "Crashpad\reports") do (
    if exist "%%~P\EBWebView\%%~C\" rd /s /q "%%~P\EBWebView\%%~C" 2> nul
  )
)
echo   done ^(a cache still open by a running app was skipped; logins untouched^)
exit /b 0

:nukesubfolders
rem Removes every immediate subdirectory of %1, one at a time, so a folder
rem still open in another process is skipped instead of aborting the rest.
if not exist "%~1\" echo   not present: %~1 & exit /b 0
echo   clearing %~1
for /d %%D in ("%~1\*") do rd /s /q "%%~D" 2> nul
echo   done ^(anything still open by a running process was skipped^)
exit /b 0
