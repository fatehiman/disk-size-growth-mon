<#
  Moves the developer caches that refill C: fastest onto another drive and
  leaves a directory symlink behind, so every tool keeps finding them at the
  path it already knows.

  Why a symlink and not an environment variable: the tools here read a
  half-dozen different variables between them (GRADLE_USER_HOME, HF_HOME,
  ANDROID_USER_HOME, PLAYWRIGHT_BROWSERS_PATH...), each with its own rules
  about when it is read, and a variable set today is not seen by a service or
  a process that was already running. A symlink is read by the filesystem, so
  it applies to everything immediately and there is nothing to remember.

  What this will NOT do:
    - merge into a target that already has files in it
    - move a folder a program currently has open
    - start a move it does not have room to finish

  -Move performs the move. Without it this only reports.
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = 'E:\Apps\c-user',
    [switch]$Move
)

$ErrorActionPreference = 'SilentlyContinue'

# source -> name under $TargetRoot. Only caches: things a tool rebuilds or
# re-downloads on its own if they ever go missing.
$items = @(
    @{ Src = "$env:USERPROFILE\.gradle";          Name = 'gradle';        What = 'Gradle wrapper distributions and dependency cache' }
    @{ Src = "$env:USERPROFILE\.cache";           Name = 'cache';         What = 'Hugging Face model downloads and other tool caches' }
    @{ Src = "$env:USERPROFILE\.android";         Name = 'android-home';  What = 'Android emulator images (AVDs) and adb keys' }
    @{ Src = "$env:LOCALAPPDATA\ms-playwright";   Name = 'ms-playwright'; What = 'Playwright browser builds' }
)

# Image names that must not be running: each one holds files in the folders above.
$blockers = @('java.exe', 'studio64.exe', 'qemu-system-x86_64.exe', 'emulator.exe', 'adb.exe')

$RP = 1024  # FileAttributes.ReparsePoint

function Test-IsLink([string]$path) {
    try { return ((([int][IO.File]::GetAttributes($path))) -band $RP) -ne 0 } catch { return $false }
}

function Get-DirSize([string]$path) {
    $sum = 0L
    foreach ($f in [IO.Directory]::EnumerateFiles($path, '*', 'AllDirectories')) {
        try { $sum += (New-Object IO.FileInfo $f).Length } catch {}
    }
    return $sum
}

# ---- report -------------------------------------------------------------

$plan = foreach ($i in $items) {
    $src = $i.Src
    $dst = Join-Path $TargetRoot $i.Name

    $state = 'move'
    $size  = 0L

    if (-not (Test-Path -LiteralPath $src)) {
        $state = 'not present'
    } elseif (Test-IsLink $src) {
        $state = 'already moved'
    } else {
        $size = Get-DirSize $src
        if ((Test-Path -LiteralPath $dst) -and (Get-ChildItem -LiteralPath $dst -Force)) {
            $state = 'target not empty - skipping'
        }
    }

    [PSCustomObject]@{
        GB    = [math]::Round($size / 1GB, 2)
        State = $state
        Src   = $src
        Dst   = $dst
        What  = $i.What
    }
}

foreach ($p in $plan) {
    '  {0,7:N2} GB  {1,-28}  {2}' -f $p.GB, $p.State, $p.Src | Write-Output
    '                            -> {0}   ({1})' -f $p.Dst, $p.What | Write-Output
}

$todo  = @($plan | Where-Object { $_.State -eq 'move' })
$total = ($todo | Measure-Object GB -Sum).Sum
Write-Output ''
Write-Output ('  {0} folder(s) to move, {1:N2} GB.' -f $todo.Count, $total)

if ($todo.Count -eq 0) { Write-Output '  nothing to do.'; exit 2 }

# ---- room on the target -------------------------------------------------

$targetDrive = (Split-Path -Qualifier $TargetRoot)
$free = (Get-PSDrive ($targetDrive[0])).Free
Write-Output ('  free on {0} {1:N2} GB, needed {2:N2} GB (plus 2 GB margin).' -f $targetDrive, ($free / 1GB), $total)
if ($free -lt (($total + 2) * 1GB)) {
    Write-Output '  NOT ENOUGH ROOM on the target drive. Free some space there first.'
    exit 1
}

if (-not $Move) { Write-Output '  (report only -- nothing was moved)'; exit 0 }

# ---- nothing may be holding the files -----------------------------------

$running = foreach ($b in $blockers) {
    if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($b)) -ErrorAction SilentlyContinue) { $b }
}
if ($running) {
    Write-Output ''
    Write-Output ('  these are running and hold files in the folders above: {0}' -f ($running -join ', '))
    Write-Output '  close Android Studio / the emulator / any Gradle daemon and run this again.'
    Write-Output '  (a Gradle daemon stops with:  gradlew --stop)'
    exit 1
}

# ---- move ---------------------------------------------------------------

foreach ($p in $todo) {
    Write-Output ''
    Write-Output ('  moving {0}  ({1:N2} GB)' -f $p.Src, $p.GB)

    New-Item -ItemType Directory -Path $p.Dst -Force | Out-Null

    # /move so robocopy deletes each source file only after it is copied, and
    # /copy:DAT rather than the default, which would also carry ACLs that mean
    # nothing on the new volume.
    robocopy $p.Src $p.Dst /e /move /copy:DAT /r:1 /w:1 /nfl /ndl /njh /njs /nc /ns | Out-Null
    $rc = $LASTEXITCODE

    # robocopy: 0-7 are success, 8 and above are real failures.
    if ($rc -ge 8) {
        Write-Output ("    robocopy failed (exit {0}). The folder was left where it was." -f $rc)
        continue
    }

    if (Test-Path -LiteralPath $p.Src) {
        # /move empties it but leaves the top directory behind when something
        # was locked. Only remove it if it really is empty.
        if (Get-ChildItem -LiteralPath $p.Src -Force -Recurse) {
            Write-Output '    some files could not be moved -- leaving the original in place, no link made.'
            continue
        }
        Remove-Item -LiteralPath $p.Src -Force -Recurse
    }

    New-Item -ItemType SymbolicLink -Path $p.Src -Target $p.Dst -ErrorAction SilentlyContinue | Out-Null
    if (Test-IsLink $p.Src) {
        Write-Output ('    done, {0} is now a link to {1}' -f $p.Src, $p.Dst)
    } else {
        Write-Output '    THE LINK WAS NOT CREATED. The data is safe at the target, but the'
        Write-Output ('    original path is gone. Create it by hand with:  mklink /d "{0}" "{1}"' -f $p.Src, $p.Dst)
    }
}

exit 0
