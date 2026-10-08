@echo off
rem ===========================================================================
rem  ONE-TIME. Moves the developer caches that refill C: fastest onto E: and
rem  leaves a directory symlink behind, so every tool still finds them where it
rem  expects.
rem
rem  This is the one script here that changes the shape of the disk rather than
rem  emptying something. Run it once. Afterwards the folders live on E: and
rem  every later re-download lands there too -- which is the point: deleting
rem  these caches only buys a few days, moving them buys forever.
rem
rem    ~\.gradle                     wrapper distributions + dependency cache
rem    ~\.cache                      Hugging Face models and other tool caches
rem    ~\.android                    emulator images (AVDs), adb keys
rem    %LOCALAPPDATA%\ms-playwright  Playwright browser builds
rem
rem  The rules are in _move-to-e.ps1 and it refuses rather than guesses: it will
rem  not merge into a target that already has files in it, will not move a
rem  folder a program has open, and will not start a move it cannot finish.
rem  The move itself is robocopy /move -- each file is deleted only after it
rem  has been copied.
rem
rem  Close Android Studio and stop any Gradle daemon (gradlew --stop) first.
rem ===========================================================================
call "%~dp0_common.cmd" begin "Move developer caches to E: (one-time)"

net session > nul 2>&1
if errorlevel 1 (
  echo   This script needs to run elevated -- creating a directory symlink
  echo   is a privileged operation unless Developer Mode is on.
  call "%~dp0_common.cmd" end
  exit /b 1
)

echo.
echo  What would move:
echo.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0_move-to-e.ps1"
rem 2 = nothing to move, 1 = something is in the way. Highest test first.
if errorlevel 2 goto finish
if errorlevel 1 goto finish

echo.
call "%~dp0_common.cmd" confirm "Move these caches to E: and leave symlinks behind?||Every tool keeps finding them at the same path. Nothing is|deleted -- the files are copied to E:, then removed from C:.||Run this ONCE. Afterwards the caches refill on E:, not on C:.||Close Android Studio and stop Gradle daemons first." "Move caches to E:"
if errorlevel 1 (
  echo   left alone.
  goto finish
)

echo.
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0_move-to-e.ps1" -Move

:finish
call "%~dp0_common.cmd" end
