@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "DISM component store cleanup (superseded WinSxS updates)"

rem ===========================================================================
rem  WinSxS keeps the previous version of every updated component so updates can
rem  be uninstalled. StartComponentCleanup removes the superseded copies once
rem  they are past the 30-day grace period, which typically frees 2-8 GB on a
rem  machine that has been patched for a while.
rem
rem  /ResetBase is NOT used. It would free a little more by making every
rem  installed update permanent -- and permanently un-uninstallable, so a bad
rem  update could no longer be rolled back. Not a trade worth making
rem  automatically.
rem
rem  This is slow: 5-20 minutes is normal, and there is no output until each
rem  stage completes. It is not hung. If you do need to stop it, the Kill button
rem  is safe here -- DISM transacts the servicing stack and rolls back cleanly.
rem ===========================================================================

net session > nul 2>&1
if errorlevel 1 (
    echo This script needs to run elevated. Run it from the app's Cleanup dialog.
    call "%~dp0_common.cmd" end
    exit /b 1
)

echo.
echo === how big is the component store? ===
rem AnalyzeComponentStore reports the reclaimable size and whether Windows
rem itself thinks a cleanup is worthwhile.
dism /online /cleanup-image /analyzecomponentstore

echo.
echo === StartComponentCleanup ===
dism /online /cleanup-image /startcomponentcleanup
echo dism exited with code %ERRORLEVEL%.

call "%~dp0_common.cmd" end
exit /b 0
