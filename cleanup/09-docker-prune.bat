@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Docker: dangling images, stopped containers, build cache"

rem ===========================================================================
rem  `docker system prune -f` removes:
rem    - stopped containers
rem    - networks not used by any container
rem    - dangling images (no tag, no container)
rem    - the build cache
rem
rem  It does NOT remove named volumes -- that needs --volumes, which is not
rem  passed here, because a named volume is where a database keeps its data and
rem  losing one is not a cache miss, it is data loss.
rem
rem  Nor is -a passed. That would delete every image not currently attached to a
rem  running container, i.e. re-pull everything the next time you compose up.
rem  Uncomment the block at the bottom if you actually want that.
rem
rem  On Docker Desktop with WSL2 the space freed inside the VM does not shrink
rem  ext4.vhdx on its own. Run 10-wsl-compact-vhdx.bat afterwards to give the
rem  space back to Windows.
rem ===========================================================================

where docker > nul 2>&1
if errorlevel 1 (
    echo docker is not on PATH -- nothing to do.
    call "%~dp0_common.cmd" end
    exit /b 0
)

echo.
echo === is the daemon up? ===
docker info > nul 2>&1
if errorlevel 1 (
    echo The Docker daemon is not responding. Start Docker Desktop and retry.
    call "%~dp0_common.cmd" end
    exit /b 1
)
echo   yes

echo.
echo === before ===
docker system df

echo.
echo === docker system prune -f ===
docker system prune -f
echo docker exited with code %ERRORLEVEL%.

echo.
echo === builder cache ===
rem BuildKit keeps its own cache that `system prune` does not always reach.
docker builder prune -f

echo.
echo === after ===
docker system df

rem --- uncomment to also drop every image not attached to a running container
rem echo.
rem echo === docker image prune -a -f ===
rem docker image prune -a -f

call "%~dp0_common.cmd" end
exit /b 0
