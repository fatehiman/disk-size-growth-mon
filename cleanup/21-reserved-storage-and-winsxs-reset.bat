@echo off
rem ===========================================================================
rem  Two Windows-servicing space reclaims that 06-dism-component-store.bat
rem  deliberately leaves alone, because each one gives something up.
rem
rem  1. Reserved storage.
rem     Windows sets aside several GB permanently so that a feature update
rem     always has room to work. It shows as used space and nothing can be put
rem     there. Turning it off returns that space now; updates then install the
rem     ordinary way and need free space at the time they run. On a disk that
rem     is already tight this is a good trade -- but keep some headroom, or an
rem     update will fail to stage.
rem
rem  2. DISM /ResetBase.
rem     06- runs StartComponentCleanup, which removes superseded components.
rem     /ResetBase goes further and removes the *backups* of the updates that
rem     are currently installed. That is usually the larger half -- run
rem     06- first and read "Backups and Disabled Features" in its report.
rem
rem     The cost: installed updates can no longer be uninstalled. Windows
rem     Update keeps working, and future updates stay removable. Do not run
rem     this while an update is misbehaving and you might want to roll it back.
rem ===========================================================================
call "%~dp0_common.cmd" begin "Reserved storage and WinSxS backup removal"

net session > nul 2>&1
if errorlevel 1 (
  echo   This script needs to run elevated.
  call "%~dp0_common.cmd" end
  exit /b 1
)

echo.
echo  ---- Component store, as it stands ----
echo.
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore

echo.
echo  ---- Reserved storage, as it stands ----
echo.
Dism.exe /Online /Get-ReservedStorageState

echo.
call "%~dp0_common.cmd" confirm "Turn OFF reserved storage?||Windows is holding several GB aside for future feature updates.|Turning it off gives that space back now.||Updates will still install -- they just need free space at the|time they run, so do not let the disk fill completely.||This can be turned back on later with:|  DISM /Online /Set-ReservedStorageState /State:Enabled" "Reserved storage"
if errorlevel 1 goto skip_reserved

echo.
echo  Disabling reserved storage...
Dism.exe /Online /Set-ReservedStorageState /State:Disabled
if errorlevel 1 echo   ^(DISM refused -- this usually means a servicing operation is pending. Reboot and try again.^)

:skip_reserved
echo.
call "%~dp0_common.cmd" confirm "Remove the WinSxS backups of installed updates? (/ResetBase)||This is the big one: on this machine the backups are several GB.||The cost is permanent -- the updates you have installed RIGHT NOW|can no longer be uninstalled. Windows Update keeps working and|future updates stay removable.||Do NOT do this if an update is currently causing you trouble.||It takes 10-30 minutes and prints nothing while it works." "WinSxS /ResetBase"
if errorlevel 1 (
  echo   left alone.
  goto finish
)

echo.
echo  Running DISM /StartComponentCleanup /ResetBase.
echo  No output until it finishes. Do not close this window.
echo.
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
if errorlevel 1 echo   ^(DISM reported a problem -- see the message above.^)

echo.
echo  ---- Component store afterwards ----
echo.
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore

:finish
call "%~dp0_common.cmd" end
