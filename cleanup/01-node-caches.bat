@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Node.js package-manager caches (npm, yarn, pnpm, bun, node-gyp, Electron)"

rem ===========================================================================
rem  Everything here is a download cache. Clearing it costs one slower install
rem  per package and nothing else.
rem
rem  node_modules folders are deliberately NOT touched: deleting those breaks
rem  every project until you reinstall, and that is not a call a cleanup script
rem  gets to make on your behalf.
rem ===========================================================================

echo.
echo === npm ===
where npm > nul 2>&1
if errorlevel 1 (echo npm not on PATH, skipping.) else (call npm cache clean --force)
rem npm sometimes leaves the content-addressable store behind after a clean.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\npm-cache\_cacache"
call "%~dp0_common.cmd" rmdir "%APPDATA%\npm-cache\_cacache"

echo.
echo === yarn ===
where yarn > nul 2>&1
if errorlevel 1 (echo yarn not on PATH, skipping.) else (call yarn cache clean)
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Yarn\Cache"

echo.
echo === pnpm ===
rem `store prune` drops only entries no project links to. pnpm projects hard-link
rem into the store, so anything still in use survives.
where pnpm > nul 2>&1
if errorlevel 1 (echo pnpm not on PATH, skipping.) else (call pnpm store prune)

echo.
echo === bun ===
call "%~dp0_common.cmd" rmdir "%USERPROFILE%\.bun\install\cache"

echo.
echo === node-gyp headers ===
rem Node headers per version, re-fetched on demand the next time a native
rem module is built.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\node-gyp\Cache"

echo.
echo === Electron ===
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\electron\Cache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\electron-builder\Cache"

call "%~dp0_common.cmd" end
exit /b 0
