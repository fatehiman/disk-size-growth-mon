@echo off
setlocal EnableExtensions
set "HERE=%~dp0"
call "%HERE%_common.cmd" begin "Google Chrome caches, every profile (closes Chrome first)"

rem ===========================================================================
rem  Clears Chrome's caches across every profile -- Default, Profile 1..N,
rem  Guest and System -- and the caches that sit above the profiles.
rem
rem  DELETED (all of it re-downloads or recompiles on demand):
rem    Cache                       the HTTP cache, usually the biggest single item
rem    Code Cache                  compiled JavaScript
rem    Service Worker\CacheStorage the Cache API store -- often larger than the
rem                                HTTP cache on a machine that uses web apps
rem    Service Worker\ScriptCache  compiled service-worker scripts
rem    GPUCache, ShaderCache, GrShaderCache, Dawn*Cache
rem    image_cache, AutofillAiModelCache, optimization_guide_*
rem    component_crx_cache, extensions_crx_cache   cached installer packages
rem
rem  NOT TOUCHED. Chrome keeps these right next to the caches, which is exactly
rem  why this script names its targets instead of globbing for "*Cache*":
rem    Cookies, Login Data         you stay signed in, passwords stay put
rem    History, Bookmarks, Web Data, Preferences, Local State
rem    Local Storage, IndexedDB, Session Storage    site data, not cache
rem    Sessions, Current Tabs      your open tabs come back
rem    Service Worker\Database     the registrations themselves (~1 MB)
rem
rem  What you will notice afterwards: first visit to each site is slower, and
rem  web apps re-fetch their offline assets. Nothing logs you out.
rem
rem  Edge, Brave and Opera use this same layout under their own vendor folder.
rem  This script deliberately only touches Google Chrome.
rem ===========================================================================

set "ROOT=%LOCALAPPDATA%\Google"
set "FOUND="
for /d %%C in ("%ROOT%\Chrome*") do if exist "%%~C\User Data\" set "FOUND=1"

if not defined FOUND (
    echo Chrome does not appear to be installed for this user
    echo ^(nothing under %ROOT%\Chrome*\User Data^) -- nothing to do.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === what is there now ===
for /d %%C in ("%ROOT%\Chrome*") do if exist "%%~C\User Data\" call :survey "%%~C\User Data"

echo.
echo === confirm ===
echo A confirmation dialog has opened -- answer it to continue.
call "%HERE%_common.cmd" confirm "Close Chrome and clear its caches in every profile?||Chrome will be asked to close normally, so it saves your session and offers to restore your tabs on the next launch. Save anything you have typed into a page first.||You stay signed in: cookies, passwords, history and bookmarks are not touched. Sites will just load slower the first time." "Clear Chrome caches"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%HERE%_common.cmd" end
    exit /b 0
)

echo.
echo === closing Chrome ===
rem 30s is generous on purpose: Chrome flushes its session, cookie and history
rem databases on the way out, and a browser with many tabs is not instant.
call "%HERE%_common.cmd" close "chrome.exe" 30
if errorlevel 1 (
    rem Almost always "Continue running background apps when Chrome is closed",
    rem which leaves chrome.exe alive with only a tray icon.
    echo   Chrome did not close. This is usually the "keep background apps
    echo   running" setting, or a page asking you to confirm leaving.
    echo   A second dialog has opened.
    call "%HERE%_common.cmd" confirm "Chrome is still running. Force-close it?||Anything not yet saved by a page will be lost. Chrome may show 'restore pages?' next launch.||Answer No to stop here and change nothing." "Chrome is still running"
    if errorlevel 1 goto bail
    call "%HERE%_common.cmd" kill "chrome.exe"
)

:closed
rem Deleting a cache file Chrome still has mapped gets a sharing violation at
rem best and a corrupt cache index at worst, so this is checked, not assumed.
call "%HERE%_common.cmd" running "chrome.exe"
if not errorlevel 1 goto bail

echo.
echo === clearing ===
for /d %%C in ("%ROOT%\Chrome*") do if exist "%%~C\User Data\" call :install "%%~C\User Data"

echo.
echo Chrome will rebuild its caches as you browse. Your tabs, logins and
echo history are as you left them.

call "%HERE%_common.cmd" end
exit /b 0

:bail
echo.
echo Chrome is still running, so NOTHING was deleted -- clearing a cache that
echo the browser has open corrupts it rather than freeing it. Close Chrome and
echo run this again.
call "%HERE%_common.cmd" end
exit /b 1

rem ------------------------------------------------------------------ helpers

:survey
rem The three that dominate, per profile. Not every target -- there are a dozen
rem more, and measuring each means another recursive walk of a directory with
rem thousands of files, which would make this slower than the cleanup itself.
echo   %~1
for /d %%P in ("%~1\*") do if exist "%%~P\Preferences" call :survey_profile "%%~P"
exit /b 0

:survey_profile
echo     %~nx1
call "%HERE%_common.cmd" dirsize "%~1\Cache"
call "%HERE%_common.cmd" dirsize "%~1\Code Cache"
call "%HERE%_common.cmd" dirsize "%~1\Service Worker\CacheStorage"
exit /b 0

:install
rem One Chrome installation ("User Data" root).
echo   %~1
call :toplevel "%~1"
rem Profile directories are Default, Profile 1..N, Guest Profile, System
rem Profile. Rather than guess the names, treat any directory holding a
rem Preferences file as a profile.
for /d %%P in ("%~1\*") do if exist "%%~P\Preferences" call :profile "%%~P"
exit /b 0

:toplevel
rem Caches shared by every profile.
for %%D in (ShaderCache GrShaderCache GraphiteDawnCache GPUPersistentCache component_crx_cache extensions_crx_cache optimization_guide_model_store) do call "%HERE%_common.cmd" rmdir "%~1\%%D"
exit /b 0

:profile
echo     profile: %~nx1
for %%D in ("Cache" "Code Cache" "GPUCache" "DawnCache" "DawnGraphiteCache" "DawnWebGPUCache" "ShaderCache" "GrShaderCache" "image_cache" "AutofillAiModelCache" "optimization_guide_hint_cache_store" "optimization_guide_prediction_model_downloads" "Service Worker\CacheStorage" "Service Worker\ScriptCache") do call "%HERE%_common.cmd" rmdir "%~1\%%~D"
exit /b 0
