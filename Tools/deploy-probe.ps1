<#
    deploy-probe.ps1 - Install the measurement probe (docs/PLAN.md section 7)
    as the addon LibAccountSyncProbe, with this checkout embedded in its Libs\.
    Run it on every machine where an account taking part plays.

    The probe is a ForeverProbe module (## Dependencies: ForeverProbe), so the
    ForeverProbe checkout ($env:FOREVERPROBE, else ..\ForeverProbe) is deployed
    first, through its own Tools\deploy.ps1; if it refuses, the probe is not
    touched. New or changed files, a brand-new addon folder included, need only
    /reload (ForeverProbe docs/GUIDE.md section 7).

        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\...\_forever_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"
$LibRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "LibAccountSyncProbe"
if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath

# The host first: without it the client loads no LibAccountSyncProbe at all.
$ForeverProbe = if ($env:FOREVERPROBE) { $env:FOREVERPROBE } else { Join-Path (Split-Path -Parent $LibRoot) "ForeverProbe" }
if (-not (Test-Path -LiteralPath (Join-Path $ForeverProbe "Tools\deploy.ps1"))) {
    Write-Error "ForeverProbe checkout not found at $ForeverProbe (clone github.com/Spotnick2/ForeverProbe there, or set `$env:FOREVERPROBE)"
    exit 1
}
& pwsh -NoProfile -File (Join-Path $ForeverProbe "Tools\deploy.ps1") -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "ForeverProbe deploy refused; LibAccountSyncProbe was not touched"; exit 1 }

$dest = Join-Path $AddOnsPath "LibAccountSyncProbe"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$files = @("LibAccountSyncProbe.toc", "LibAccountSyncProbe.lua")
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
# The file before the ForeverProbe migration must not linger where the client finds it.
Get-ChildItem -LiteralPath $dest -File | Where-Object { $files -notcontains $_.Name } | ForEach-Object {
    Write-Host "  removing stale $($_.Name)" -ForegroundColor DarkYellow
    Remove-Item -LiteralPath $_.FullName -Force
}
& (Join-Path $PSScriptRoot "deploy.ps1") -Addon "LibAccountSyncProbe" -AddOnsPath $AddOnsPath
if ($LASTEXITCODE -ne 0) { Write-Error "LibAccountSync deploy into the probe failed"; exit 1 }
Write-Host "Probe installed in $dest." -ForegroundColor Green
Write-Host "In game: /reload, then /fp las (commands) or /fp steps las check (the two-account check)." -ForegroundColor Green
