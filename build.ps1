<#
.SYNOPSIS
    Builds a single self-contained DiskSizeGrowthMon.exe into .\dist.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Runtime win-arm64
#>
[CmdletBinding()]
param(
    [string] $Runtime       = 'win-x64',
    [string] $Configuration = 'Release',
    [string] $Output        = "$PSScriptRoot\dist",
    [switch] $SkipTests
)

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

$project = "$PSScriptRoot\src\DiskSizeGrowthMon\DiskSizeGrowthMon.csproj"

if (-not $SkipTests) {
    Write-Host "==> Running smoke tests" -ForegroundColor Cyan
    dotnet run --project "$PSScriptRoot\tests\SmokeTests\SmokeTests.csproj" -c $Configuration -v q
    if ($LASTEXITCODE -ne 0) { throw "Smoke tests failed (exit $LASTEXITCODE)." }
}

Write-Host "==> Publishing $Runtime" -ForegroundColor Cyan
dotnet publish $project -c $Configuration -r $Runtime --self-contained true -o $Output -v m
if ($LASTEXITCODE -ne 0) { throw "Publish failed (exit $LASTEXITCODE)." }

$exe = Join-Path $Output 'DiskSizeGrowthMon.exe'
Write-Host ""
Write-Host ("==> {0} ({1:N1} MB)" -f $exe, ((Get-Item $exe).Length / 1MB)) -ForegroundColor Green
Write-Host "    Launching it will prompt for elevation; that is by design."
