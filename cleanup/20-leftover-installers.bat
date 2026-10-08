@echo off
rem ===========================================================================
rem  Deletes installer payloads that apps downloaded, ran, and then kept.
rem
rem  These are not caches -- nothing re-reads them. An updater downloads a
rem  setup.exe or a .nupkg into its own folder, installs from it, and never
rem  comes back. On a machine that has been running a while they add up to
rem  several GB of files that exist for no reason at all.
rem
rem  Everything here is re-downloadable by the app that made it, so the worst
rem  case is one slower update later.
rem
rem  NOT touched, deliberately:
rem    C:\ProgramData\Package Cache   -- Visual Studio / VC++ redist repair and
rem                                      uninstall read this back. Removing it
rem                                      makes "Repair" fail later.
rem    C:\Windows\Installer           -- same story for every MSI on the box,
rem                                      and telling the orphans apart needs
rem                                      more than a path list.
rem ===========================================================================
call "%~dp0_common.cmd" begin "Leftover installer payloads"

echo.
echo  What is there now:
echo.
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\Ollama\updates_v2"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\lm-studio-updater"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\insomnia\packages"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\antigravity-updater"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\redisinsight-updater"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\bluestacks-services-updater"
call "%~dp0_common.cmd" dirsize "%LOCALAPPDATA%\Postman\update"
call "%~dp0_common.cmd" dirsize "%ProgramFiles(x86)%\Common Files\VMware\InstallerCache"
call "%~dp0_common.cmd" dirsize "%ProgramData%\NVIDIA Corporation\Downloader"
call "%~dp0_common.cmd" dirsize "%ProgramData%\NVIDIA Corporation\ChatRTX\Temp"
call "%~dp0_common.cmd" dirsize "%SystemDrive%\MSOCache"
call "%~dp0_common.cmd" dirsize "%SystemRoot%\Panther"

echo.
call "%~dp0_common.cmd" confirm "Delete the installer payloads listed above?||These are setup files that were already installed from. No app|reads them again; an updater re-downloads if it ever needs to.||Visual Studio's Package Cache and C:\Windows\Installer are NOT|touched." "Leftover installers"
if errorlevel 1 (
  echo   left alone.
  goto finish
)

echo.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Ollama\updates_v2"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\lm-studio-updater"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\insomnia\packages"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\antigravity-updater"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\redisinsight-updater"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\bluestacks-services-updater"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Postman\update"
call "%~dp0_common.cmd" rmdir "%ProgramFiles(x86)%\Common Files\VMware\InstallerCache"
call "%~dp0_common.cmd" rmdir "%ProgramData%\NVIDIA Corporation\Downloader"
call "%~dp0_common.cmd" rmdir "%ProgramData%\NVIDIA Corporation\ChatRTX\Temp"

rem MSOCache is Office's local copy of its own installation media. Office only
rem wants it for a repair, and a repair falls back to downloading. It is hidden
rem and system, so rd needs the attributes cleared first.
if exist "%SystemDrive%\MSOCache\" (
  echo   removing %SystemDrive%\MSOCache
  attrib -h -s -r "%SystemDrive%\MSOCache" > nul 2> nul
  rd /s /q "%SystemDrive%\MSOCache" 2> nul
  if exist "%SystemDrive%\MSOCache\" echo   ^(partly in use, some files were left behind^)
)

rem Setup and upgrade logs. Windows writes these during a feature update and
rem never reads them again; only support engineers do.
call "%~dp0_common.cmd" rmdir "%SystemRoot%\Panther"

rem Cursor keeps a full second copy of its global state database as a backup and
rem rewrites it on exit. On this machine each copy is around 1 GB. Only safe
rem while Cursor is closed, or it is recreated immediately.
call "%~dp0_common.cmd" running "Cursor.exe"
if errorlevel 1 (
  if exist "%APPDATA%\Cursor\User\globalStorage\state.vscdb.backup" (
    echo   removing Cursor's state.vscdb.backup
    del /f /q "%APPDATA%\Cursor\User\globalStorage\state.vscdb.backup" 2> nul
  )
) else (
  echo   Cursor is running -- leaving its state backup alone.
)

:finish
call "%~dp0_common.cmd" end
