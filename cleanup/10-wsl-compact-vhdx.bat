@echo off
setlocal EnableExtensions EnableDelayedExpansion
call "%~dp0_common.cmd" begin "Compact WSL2 virtual disks (ext4.vhdx) -- shuts down all distros"

rem ===========================================================================
rem  A WSL2 disk grows and never shrinks. Delete 40 GB inside the distro and
rem  ext4.vhdx stays 40 GB larger on Windows -- the free space exists inside the
rem  virtual disk and nowhere else. Compacting hands it back.
rem
rem  This is the most invasive script in the folder:
rem
rem    - every WSL distro is shut down, hard. Anything running inside one
rem      (a dev server, a database, an unsaved editor buffer) dies with it.
rem    - Docker Desktop on the WSL2 backend goes down with it too.
rem    - it takes minutes per disk, with no progress output.
rem
rem  So it asks first. If you would rather it did not, delete this file.
rem
rem  Optimize-VHD (Hyper-V) is not used: it is not installed on Home editions.
rem  diskpart's `compact vdisk` is, and it works everywhere.
rem ===========================================================================

where wsl > nul 2>&1
if errorlevel 1 (
    echo WSL is not installed -- nothing to do.
    call "%~dp0_common.cmd" end
    exit /b 0
)

net session > nul 2>&1
if errorlevel 1 (
    echo This script needs to run elevated ^(diskpart does^). Run it from the
    echo app's Cleanup dialog.
    call "%~dp0_common.cmd" end
    exit /b 1
)

echo.
echo === virtual disks found ===
set "COUNT=0"
for /f "usebackq delims=" %%V in (`powershell -NoProfile -NonInteractive -Command "Get-ChildItem -Path $env:LOCALAPPDATA\Packages,$env:LOCALAPPDATA\Docker,$env:LOCALAPPDATA\wsl -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }" 2^> nul`) do (
    set /a COUNT+=1
    set "VHD!COUNT!=%%V"
    call :showsize "%%V" !COUNT!
)

if %COUNT%==0 (
    echo   none found under %LOCALAPPDATA%\Packages, \Docker or \wsl.
    echo   A distro installed elsewhere can be compacted by hand:
    echo     wsl --shutdown
    echo     diskpart
    echo       select vdisk file="path\to\ext4.vhdx"
    echo       attach vdisk readonly
    echo       compact vdisk
    echo       detach vdisk
    call "%~dp0_common.cmd" end
    exit /b 0
)

echo.
echo === confirm ===
echo About to shut down ALL WSL distros and compact the %COUNT% disk^(s^) above.
echo Anything running inside WSL, including Docker Desktop, will be stopped.
echo A confirmation dialog has opened -- answer it to continue.
rem A GUI prompt, not `set /p`: the app runs these scripts with stdin closed so
rem that a script which reads input gets EOF instead of hanging forever, and
rem `set /p` would therefore auto-answer "no" every time.
powershell -NoProfile -NonInteractive -Command "Add-Type -AssemblyName System.Windows.Forms; $r=[System.Windows.Forms.MessageBox]::Show('Shut down all WSL distros and compact %COUNT% virtual disk(s)?' + [char]10 + [char]10 + 'Everything running inside WSL, Docker Desktop included, will be stopped.','Compact WSL disks','YesNo','Warning','Button2'); if($r -eq 'Yes'){exit 0} else {exit 1}"
if errorlevel 1 (
    echo Cancelled -- nothing was changed.
    call "%~dp0_common.cmd" end
    exit /b 0
)

echo.
echo === wsl --shutdown ===
wsl --shutdown
rem The VM host takes a moment to release its handle on the vhdx after the
rem distros stop; compacting too early fails with "file is in use".
rem ping rather than timeout, which refuses to run with stdin redirected.
ping -n 9 127.0.0.1 > nul
echo   done

for /l %%I in (1,1,%COUNT%) do call :compact "!VHD%%I!"

echo.
echo Docker Desktop, if you use it, needs starting again by hand.

call "%~dp0_common.cmd" end
exit /b 0

rem ------------------------------------------------------------------ helpers

:showsize
for %%A in ("%~1") do echo   [%~2] %%~zA bytes  %~1
exit /b 0

:compact
echo.
echo === compacting %~1 ===
rem `attach readonly` is what makes this safe: diskpart cannot write to the
rem disk's contents, it only rewrites the container to drop unused blocks.
set "SCRIPT=%TEMP%\dsm-compact-%RANDOM%.dpt"
> "%SCRIPT%" echo select vdisk file="%~1"
>>"%SCRIPT%" echo attach vdisk readonly
>>"%SCRIPT%" echo compact vdisk
>>"%SCRIPT%" echo detach vdisk
diskpart /s "%SCRIPT%"
if errorlevel 1 echo   diskpart reported an error ^(exit %ERRORLEVEL%^); the disk was left as it was.
del /f /q "%SCRIPT%" 2> nul
for %%A in ("%~1") do echo   now %%~zA bytes
exit /b 0
