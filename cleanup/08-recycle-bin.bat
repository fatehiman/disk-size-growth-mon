@echo off
setlocal EnableExtensions
call "%~dp0_common.cmd" begin "Empty the Recycle Bin on every fixed drive"

rem ===========================================================================
rem  This is the one script here that can lose something you wanted: the
rem  Recycle Bin is where deleted files wait for you to change your mind.
rem  Nothing else in this folder touches your own files.
rem
rem  Clear-RecycleBin is used rather than `rd /s /q C:\$Recycle.Bin`: the shell
rem  API keeps the bin's own metadata consistent, where deleting the folder
rem  outright leaves Explorer showing a full bin that contains nothing.
rem ===========================================================================

echo.
echo === current contents ===
powershell -NoProfile -NonInteractive -Command "$t=0; foreach($d in Get-PSDrive -PSProvider FileSystem){ $p=Join-Path $d.Root '$Recycle.Bin'; if(Test-Path $p){ $s=(Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length); $t+=$s.Sum; Write-Host ('  {0} {1,10:N1} MB in {2} file(s)' -f $d.Root,($s.Sum/1MB),$s.Count) } }; Write-Host ('  total {0:N1} MB' -f ($t/1MB))"

echo.
echo === emptying ===
rem -Force suppresses the confirmation prompt, which would otherwise sit there
rem forever with stdin redirected.
powershell -NoProfile -NonInteractive -Command "foreach($d in Get-PSDrive -PSProvider FileSystem){ try { Clear-RecycleBin -DriveLetter $d.Name -Force -ErrorAction Stop; Write-Host ('  emptied ' + $d.Root) } catch { Write-Host ('  ' + $d.Root + ': ' + $_.Exception.Message) } }"

call "%~dp0_common.cmd" end
exit /b 0
