@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Mozilla Firefox caches, every profile (closes Firefox first)"

rem ===========================================================================
rem  Firefox splits each profile across two roots, and which half a thing lives
rem  in tells you whether it is disposable:
rem
rem    %LOCALAPPDATA%\Mozilla\Firefox\Profiles\<id>\   caches (by design)
rem    %APPDATA%\Mozilla\Firefox\Profiles\<id>\        your actual profile
rem
rem  So the Local half is cleared wholesale by name, and the Roaming half is
rem  touched in exactly one place: the DOM Cache API store, which Firefox
rem  unhelpfully files under site data.
rem
rem  DELETED:
rem    cache2\                  the HTTP cache
rem    startupCache\            precompiled chrome/XUL and script caches
rem    shader-cache\, thumbnails\, jumpListCache\, OfflineCache\
rem    safebrowsing\            re-downloaded from Google within minutes
rem    minidumps\, crashes\     crash dumps, only useful mid-debugging
rem    storage\default\<site>\cache\    the Cache API store, per origin
rem
rem  NOT TOUCHED:
rem    cookies.sqlite           you stay signed in
rem    logins.json, key4.db     saved passwords
rem    places.sqlite            history AND bookmarks, same file
rem    sessionstore*, sessionstore-backups\   your open tabs
rem    bookmarkbackups\         the only copy if places.sqlite is ever damaged
rem    storage\default\<site>\ls\ and \idb\   localStorage and IndexedDB
rem    extensions\, prefs.js, containers.json
rem
rem  Note the shape of the storage\default rule: per origin, only the `cache`
rem  subdirectory goes. Deleting the origin folder would take localStorage and
rem  IndexedDB with it, which is site data -- a shopping basket, a draft, an
rem  offline document -- not a cache.
rem ===========================================================================

set "FFLOCAL=%LOCALAPPDATA%\Mozilla\Firefox\Profiles"
set "FFROAM=%APPDATA%\Mozilla\Firefox\Profiles"

set "FOUND="
if exist "%FFLOCAL%\" set "FOUND=1"
if exist "%FFROAM%\"  set "FOUND=1"

if not defined FOUND (
    echo Firefox does not appear to be installed for this user.
    echo Looked in:
    echo   %FFLOCAL%
    echo   %FFROAM%
    echo Nothing to do.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === profiles found ===
for /d %%P in ("%FFLOCAL%\*") do call :survey "%%~P"
for /d %%P in ("%FFROAM%\*")  do call :survey_roam "%%~P"

echo.
echo === confirm ===
echo A confirmation dialog has opened -- answer it to continue.
call "%HERE%_common.cmd" confirm "Close Firefox and clear its caches in every profile?||Firefox will be asked to close normally, so it writes out your session and reopens your tabs on the next launch. Save anything you have typed into a page first.||You stay signed in: cookies, passwords, history and bookmarks are not touched. Sites will just load slower the first time." "Clear Firefox caches"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === closing Firefox ===
rem Firefox writes places.sqlite, cookies.sqlite and the session store on the
rem way out; 30s gives it room to finish rather than leaving a stale lock.
call "%HERE%_common.cmd" close "firefox.exe" 30
if errorlevel 1 (
    echo   Firefox did not close. Usually a page asking you to confirm leaving,
    echo   or a download still in progress. A second dialog has opened.
    call "%HERE%_common.cmd" confirm "Firefox is still running. Force-close it?||Downloads in progress will be interrupted and unsaved page input lost. Firefox may offer to restore the session next launch.||Answer No to stop here and change nothing." "Firefox is still running"
    if errorlevel 1 goto bail
    call "%HERE%_common.cmd" kill "firefox.exe"
)

rem Also the crash reporter and the WebExtension host, which keep profile files
rem open after the browser itself has gone.
call "%HERE%_common.cmd" close "crashreporter.exe" 5
call "%HERE%_common.cmd" close "plugin-container.exe" 5

call "%HERE%_common.cmd" running "firefox.exe"
if not errorlevel 1 goto bail

echo.
echo === clearing local caches ===
for /d %%P in ("%FFLOCAL%\*") do call :clear_local "%%~P"

echo.
echo === clearing the Cache API store ===
for /d %%P in ("%FFROAM%\*") do call :clear_roam "%%~P"

echo.
echo === Firefox updates ===
rem Downloaded update packages already applied.
call "%HERE%_common.cmd" rmdir "%LOCALAPPDATA%\Mozilla\updates"

echo.
echo Firefox will rebuild its caches as you browse. Your tabs, logins, history
echo and bookmarks are as you left them.

call "%HERE%_common.cmd" end
exit /b 0

:bail
echo.
echo Firefox is still running, so NOTHING was deleted -- clearing cache2 while
echo the browser has it open corrupts the cache rather than freeing it. Close
echo Firefox and run this again.
call "%HERE%_common.cmd" end
exit /b 1

rem ------------------------------------------------------------------ helpers

:survey
echo   %~nx1  ^(local^)
call "%HERE%_common.cmd" dirsize "%~1\cache2"
call "%HERE%_common.cmd" dirsize "%~1\startupCache"
exit /b 0

:survey_roam
if not exist "%~1\storage\default\" exit /b 0
echo   %~nx1  ^(roaming, Cache API only^)
call "%HERE%_common.cmd" dirsize "%~1\storage\default"
echo     ^(that figure includes localStorage and IndexedDB, which stay^)
exit /b 0

:clear_local
echo   %~nx1
for %%D in (cache2 startupCache shader-cache thumbnails jumpListCache OfflineCache safebrowsing minidumps crashes) do call "%HERE%_common.cmd" rmdir "%~1\%%D"
exit /b 0

:clear_roam
if not exist "%~1\storage\default\" exit /b 0
echo   %~nx1
set "N=0"
for /d %%O in ("%~1\storage\default\*") do call :clear_origin "%%~O"
echo     %N% origin cache folder^(s^) removed
exit /b 0

:clear_origin
rem Only the `cache` subfolder. Its siblings `ls` and `idb` are localStorage and
rem IndexedDB, which are site data and stay.
if not exist "%~1\cache\" exit /b 0
rd /s /q "%~1\cache" 2> nul
if not exist "%~1\cache\" set /a N+=1
exit /b 0
