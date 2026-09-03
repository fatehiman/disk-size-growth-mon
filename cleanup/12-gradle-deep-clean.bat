@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Gradle downloads: caches\modules-2 and wrapper\dists (re-downloaded on next build)"

rem ===========================================================================
rem  The half of ~\.gradle that 11-gradle-caches.bat deliberately leaves alone:
rem
rem    caches\modules-2   every dependency jar/pom Gradle ever downloaded
rem    wrapper\dists      whole Gradle distributions (a "-all" one is ~400 MB
rem                       on its own, since it bundles sources and docs)
rem
rem  Both are safe in the sense that Gradle re-fetches them. The cost is not a
rem  slower build, it is bandwidth and time: the next build of each project
rem  re-downloads its dependency graph, and the wrapper re-downloads its whole
rem  distribution before it can even start.
rem
rem  Worth it when you need the space now. Not worth it on a metered
rem  connection, offline, or five minutes before a demo. Hence the prompt.
rem ===========================================================================

set "GUH=%GRADLE_USER_HOME%"
if not defined GUH set "GUH=%USERPROFILE%\.gradle"

if not exist "%GUH%\" (
    echo No Gradle home at %GUH% -- nothing to do.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo Gradle home: %GUH%
echo.
echo === what would go ===
call "%HERE%_common.cmd" dirsize "%GUH%\caches\modules-2"
call "%HERE%_common.cmd" dirsize "%GUH%\wrapper\dists"

echo.
echo === confirm ===
echo A confirmation dialog has opened -- answer it to continue.
call "%HERE%_common.cmd" confirm "Delete Gradle's downloaded dependencies and distributions?||The next build of every project re-downloads its dependency graph, and the Gradle wrapper re-downloads its whole distribution first. Minutes, and bandwidth.||Nothing else is affected." "Gradle deep clean"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === stopping Gradle daemons ===
where gradle > nul 2>&1
if errorlevel 1 (echo   gradle not on PATH; skipping --stop) else (call gradle --stop)

echo.
echo === deleting ===
call "%HERE%_common.cmd" rmdir "%GUH%\caches\modules-2"
call "%HERE%_common.cmd" rmdir "%GUH%\wrapper\dists"

call "%HERE%_common.cmd" end
exit /b 0
