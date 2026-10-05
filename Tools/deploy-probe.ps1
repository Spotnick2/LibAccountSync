<#
    deploy-probe.ps1 - Install the measurement probe (docs/PLAN.md section 7)
    as the addon LibAccountSyncProbe, with this checkout embedded in its Libs\.
    Run it on the machine where both accounts play; a brand-new addon folder
    needs a client restart the first time, /reload after that.

        pwsh Tools/deploy-probe.ps1
        pwsh Tools/deploy-probe.ps1 -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"
#>

param(
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"
$LibRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot "LibAccountSyncProbe"
if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath
$dest = Join-Path $AddOnsPath "LibAccountSyncProbe"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in @("LibAccountSyncProbe.toc", "Probe.lua")) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
& (Join-Path $PSScriptRoot "deploy.ps1") -Addon "LibAccountSyncProbe" -AddOnsPath $AddOnsPath
Write-Host "Probe installed in $dest. In game: /lasprobe" -ForegroundColor Green
