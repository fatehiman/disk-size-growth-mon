@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin ".NET / NuGet / Python / Java / Rust / Go / Gradle package caches"

rem ===========================================================================
rem  Download and build caches for the non-Node toolchains. All regenerable;
rem  the cost is one slower restore or build per project.
rem
rem  Not touched: anything inside a project (bin, obj, target, .venv). Those are
rem  yours to delete, and a global sweep for them is how people lose work.
rem ===========================================================================

echo.
echo === NuGet / .NET SDK ===
where dotnet > nul 2>&1
if errorlevel 1 goto no_dotnet
rem Clears http-cache, global-packages, temp and plugins-cache in one go.
call dotnet nuget locals all --clear
goto after_dotnet
:no_dotnet
echo dotnet not on PATH; removing the cache folders directly.
call "%~dp0_common.cmd" rmdir "%USERPROFILE%\.nuget\packages"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\NuGet\v3-cache"
:after_dotnet
rem Left behind by dotnet regardless of `nuget locals`.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\Temp\NuGetScratch"

echo.
echo === Python ===
where pip > nul 2>&1
if errorlevel 1 (echo pip not on PATH, skipping.) else (call pip cache purge)
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\pip\Cache"
rem uv and poetry keep their own wheel caches.
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\uv\cache"
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\pypoetry\Cache"

echo.
echo === Java / Maven ===
rem Gradle is not touched here. It is worth gigabytes on its own and needs the
rem daemons stopped first, so it has its own pair of scripts:
rem   11-gradle-caches.bat      derived caches, no re-download
rem   12-gradle-deep-clean.bat  the downloads too
echo   Gradle: see 11-gradle-caches.bat and 12-gradle-deep-clean.bat
call "%~dp0_common.cmd" rmdir "%USERPROFILE%\.m2\repository\.cache"

echo.
echo === Rust ===
rem Registry sources and downloaded crates; `cargo build` refetches as needed.
call "%~dp0_common.cmd" rmdir "%USERPROFILE%\.cargo\registry\cache"
call "%~dp0_common.cmd" rmdir "%USERPROFILE%\.cargo\registry\src"

echo.
echo === Go ===
where go > nul 2>&1
if errorlevel 1 goto no_go
rem Build cache only. The module cache is left in place -- clearing it means
rem re-downloading every dependency of every project.
call go clean -cache
goto done
:no_go
call "%~dp0_common.cmd" rmdir "%LOCALAPPDATA%\go-build"

:done
call "%~dp0_common.cmd" end
exit /b 0
