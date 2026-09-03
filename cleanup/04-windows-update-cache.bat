@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Windows Update download cache and Delivery Optimization cache"

rem ===========================================================================
rem  SoftwareDistribution\Download holds update payloads that have already been
rem  installed. Windows re-downloads anything it still needs, so emptying it is
rem  safe -- it is exactly what "Windows Update Cleanup" in Disk Cleanup does,
rem  minus the reboot.
rem
rem  The services holding those files open have to stop first. They are started
rem  again at the end whatever happens, including if a delete fails.
rem
rem  Needs elevation. The app is elevated, so running it from there is enough.
rem ===========================================================================

net session > nul 2>&1
if errorlevel 1 (
    echo This script needs to run elevated. Run it from the app's Cleanup dialog,
    echo or open an Administrator command prompt.
    call "%~dp0_common.cmd" end
    exit /b 1
)

echo.
echo === stopping services ===
call :stop wuauserv
call :stop bits
call :stop dosvc
call :stop cryptsvc

echo.
echo === SoftwareDistribution\Download ===
call :emptydir "%SystemRoot%\SoftwareDistribution\Download"

echo.
echo === Delivery Optimization cache ===
rem Peer-to-peer update payloads already applied; routinely several GB.
call :emptydir "%SystemRoot%\SoftwareDistribution\DeliveryOptimization"
call :emptydir "%SystemRoot%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"

echo.
echo === catroot2 ===
rem Update signature catalogues. Windows rebuilds this on the next update check;
rem clearing it is the standard fix for a stuck update as well.
call :emptydir "%SystemRoot%\System32\catroot2"

echo.
echo === restarting services ===
call :start cryptsvc
call :start dosvc
call :start bits
call :start wuauserv

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:stop
echo   stopping %~1
net stop %~1 > nul 2> nul
if errorlevel 1 echo   ^(%~1 was not running, or refused to stop^)
exit /b 0

:start
echo   starting %~1
net start %~1 > nul 2> nul
if errorlevel 1 echo   ^(%~1 did not start; it is probably set to start on demand, which is fine^)
exit /b 0

:emptydir
if not exist "%~1\" echo   not present: %~1 & exit /b 0
echo   emptying %~1
del /f /a /q "%~1\*" > nul 2> nul
for /d %%D in ("%~1\*") do rd /s /q "%%~D" 2> nul
echo   done
exit /b 0
