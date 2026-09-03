@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Thumbnail, icon, font and GPU shader caches"

rem ===========================================================================
rem  Pure display caches. Windows and your GPU driver rebuild all of it on
rem  demand; the only visible effect is that thumbnails in a big picture folder
rem  redraw slowly once, and the first launch of a 3D game recompiles shaders.
rem
rem  Explorer is NOT restarted here, on purpose. This script runs elevated (the
rem  app is), and re-launching explorer.exe from an elevated process can bring
rem  the shell back at high integrity, which quietly breaks drag-and-drop and
rem  every non-elevated app's shell integration until the next logon. Trading
rem  that for a few hundred MB is a bad deal.
rem
rem  So the thumbnail and icon databases are deleted only if Explorer does not
rem  happen to hold them open; whatever is locked is reported and left. Use
rem  05-windows-cleanmgr.bat, which asks the shell to purge them properly, or
rem  just log off and run this again.
rem ===========================================================================

set "SHELLCACHE=%LOCALAPPDATA%\Microsoft\Windows\Explorer"

echo.
echo === GPU shader caches ===
rem These do not need Explorer stopped, so they go first.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\D3DSCache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\NVIDIA\DXCache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\NVIDIA\GLCache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\AMD\DxCache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\AMD\GLCache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Intel\ShaderCache"

echo.
echo === font cache ===
rem Rebuilt at the next logon by the font cache services.
net stop FontCache > nul 2> nul
net stop FontCache3.0.0.0 > nul 2> nul
del /f /a /q "%SystemRoot%\ServiceProfiles\LocalService\AppData\Local\FontCache\*" > nul 2> nul
del /f /a /q "%SystemRoot%\ServiceProfiles\LocalService\AppData\Local\*.dat" > nul 2> nul
net start FontCache > nul 2> nul
echo   font cache cleared and the service restarted

echo.
echo === thumbnail and icon caches ===
call :trydel "%SHELLCACHE%\thumbcache_*.db"
call :trydel "%SHELLCACHE%\iconcache_*.db"
call :trydel "%LOCALAPPDATA%\IconCache.db"
echo   Anything reported as in use is held open by Explorer. Log off and run
echo   this again, or use 05-windows-cleanmgr.bat's Thumbnail Cache handler.

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:trydel
rem Deletes a pattern one file at a time, so a single locked file does not hide
rem the fact that the others went.
set "_found="
rem dir /a, not a plain FOR: FOR skips files with the hidden attribute, and
rem IconCache.db is hidden.
for /f "delims=" %%F in ('dir /a /b "%~1" 2^> nul') do call :trydel_one "%~dp1%%F"
if not defined _found echo   nothing matching %~1
set "_found="
exit /b 0

:trydel_one
set "_found=1"
del /f /a /q "%~1" > nul 2> nul
if exist "%~1" (echo   in use, left alone: %~1) else (echo   deleted %~1)
exit /b 0
