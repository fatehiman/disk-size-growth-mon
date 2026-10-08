<#
  Lists, and optionally removes, superseded Store app versions.

  Windows keeps the old version of a packaged app in C:\Program Files\WindowsApps
  after an update. Normally a maintenance task removes it; on this machine that
  task clearly has not kept up -- six versions of one app is not unusual.

  "Superseded" here has a deliberately narrow meaning, because getting it wrong
  uninstalls something the user wanted:

      the package is STAGED for every user (nobody has it installed), AND
      another version of the same family IS installed, AND
      that installed version is NEWER than or equal to this one.

  The middle condition is what keeps a *pending* update safe: a newly staged
  version that has not been registered yet is newer than the installed one, so
  it fails the third test and is left alone.

  -Remove actually deletes. Without it this only reports.
#>
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'SilentlyContinue'

function Get-DirSize([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 0L }
    $sum = 0L
    foreach ($f in [IO.Directory]::EnumerateFiles($path, '*', 'AllDirectories')) {
        try { $sum += (New-Object IO.FileInfo $f).Length } catch {}
    }
    return $sum
}

$all = Get-AppxPackage -AllUsers
if (-not $all) {
    Write-Output '  could not read the package list (this script needs to run elevated).'
    exit 1
}

$stale = foreach ($group in ($all | Group-Object PackageFamilyName)) {
    if ($group.Count -lt 2) { continue }

    $installed = $group.Group | Where-Object {
        $_.PackageUserInformation | Where-Object { $_.InstallState -eq 'Installed' }
    }
    if (-not $installed) { continue }

    # The highest version anyone actually has registered.
    $newest = ($installed | Sort-Object { [version]$_.Version } -Descending)[0]

    $group.Group | Where-Object {
        $_.PackageFullName -ne $newest.PackageFullName -and
        -not ($_.PackageUserInformation | Where-Object { $_.InstallState -eq 'Installed' }) -and
        ([version]$_.Version) -le ([version]$newest.Version)
    }
}

if (-not $stale) {
    Write-Output '  no superseded versions found. Nothing to do.'
    exit 2
}

$rows = foreach ($p in $stale) {
    [PSCustomObject]@{
        MB   = [math]::Round((Get-DirSize $p.InstallLocation) / 1MB, 1)
        Name = $p.Name
        Ver  = $p.Version
        Full = $p.PackageFullName
    }
}
$rows = $rows | Sort-Object MB -Descending

$rows | Format-Table @{n='MB';e={'{0,9:N1}' -f $_.MB}}, Name, Ver -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ('  {0} superseded version(s), {1:N1} MB total.' -f $rows.Count, ($rows | Measure-Object MB -Sum).Sum)

if (-not $Remove) {
    Write-Output '  (report only -- nothing was removed)'
    exit 0
}

Write-Output ''
foreach ($r in $rows) {
    Write-Output ("  removing {0} {1}" -f $r.Name, $r.Ver)
    Remove-AppxPackage -Package $r.Full -AllUsers -ErrorAction SilentlyContinue
    if ($?) { } else { Write-Output '    (could not be removed -- Windows is still holding it)' }
}
exit 0
