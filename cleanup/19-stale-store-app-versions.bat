@echo off
rem ===========================================================================
rem  Removes superseded Microsoft Store app versions from
rem  C:\Program Files\WindowsApps.
rem
rem  Windows keeps the previous version of a packaged app after it updates, and
rem  a maintenance task is supposed to clear it out later. That task does not
rem  always win, and the leftovers are large -- an app that updates often can
rem  end up with five or six copies of itself on disk.
rem
rem  The rule this uses is in _appx-prune.ps1 and is deliberately narrow: a
rem  version is only removed when nobody has it installed AND a newer-or-equal
rem  version of the same app IS installed. A freshly staged update that has not
rem  been registered yet is therefore never touched.
rem
rem  Nothing you use is uninstalled. Your app data lives under
rem  %LOCALAPPDATA%\Packages and is not involved.
rem ===========================================================================
call "%~dp0_common.cmd" begin "Superseded Microsoft Store app versions"

net session > nul 2>&1
if errorlevel 1 (
  echo   This script needs to run elevated -- the package list for all users
  echo   is not readable otherwise.
  call "%~dp0_common.cmd" end
  exit /b 1
)

echo.
echo  Looking for superseded versions...
echo.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0_appx-prune.ps1"
rem 2 = nothing to do, 1 = could not read the list. Highest test first: cmd's
rem `if errorlevel N` means "N or greater".
if errorlevel 2 goto finish
if errorlevel 1 goto finish

echo.
call "%~dp0_common.cmd" confirm "Remove the superseded Store app versions listed above?||Only versions that nobody has installed are removed, and only|when a newer version of the same app is already installed.||App settings and data are not touched." "Store app versions"
if errorlevel 1 (
  echo   left alone.
  goto finish
)

echo.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0_appx-prune.ps1" -Remove

:finish
call "%~dp0_common.cmd" end
