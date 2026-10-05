<#
    deploy.ps1 - Copy this LibAccountSync checkout into a consumer addon's
    Libs\LibAccountSync-1.0 in the Forever AddOns folder (what the packager's
    externals would put there, for in-game testing of a dev copy).

    Copies only what runs in game: LibAccountSync-1.0.xml, every file it loads
    (LibStub, ChatThrottleLib, the runtime) and LICENSE. Refuses to copy a
    checkout missing any of them, removes files the library no longer ships,
    and prints the commit so an in-game check can be tied to it.

    Consumers call it from their own deploy:
        pwsh ..\LibAccountSync\Tools\deploy.ps1 -Addon GlassChat
        pwsh ..\LibAccountSync\Tools\deploy.ps1 -Addon GlassChat -AddOnsPath "D:\...\_classic_beta_\Interface\AddOns"
#>

param(
    [Parameter(Mandatory)][string]$Addon,
    [string]$AddOnsPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns",
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"
$LibRoot = Split-Path -Parent $PSScriptRoot

# --- Preflight: everything the XML loads, and LICENSE.
$xmlPath = Join-Path $LibRoot "LibAccountSync-1.0.xml"
if (-not (Test-Path -LiteralPath $xmlPath)) { Write-Error "LibAccountSync-1.0.xml not found in $LibRoot"; exit 1 }
$xml = (Get-Content -LiteralPath $xmlPath -Raw) -replace '(?s)<!--.*?-->', ''
$scripts = @([regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
if ($scripts.Count -eq 0) { Write-Error "LibAccountSync-1.0.xml lists no Script files"; exit 1 }
$files = @("LibAccountSync-1.0.xml", "LICENSE") + $scripts
$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LibRoot $_)) })
if ($missing.Count -gt 0) { Write-Error ("LibAccountSync checkout is incomplete, missing: " + ($missing -join ", ")); exit 1 }

$luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
if (Test-Path -LiteralPath $luac) {
    Push-Location $LibRoot
    try {
        & $luac -p @scripts
        if ($LASTEXITCODE -ne 0) { Write-Error "luac -p failed on the LibAccountSync checkout"; exit 1 }
        Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
    } finally { Pop-Location }
} else {
    Write-Host "  luac -p SKIPPED (no $luac)" -ForegroundColor Yellow
}

$commit = "unknown"
try {
    $commit = (git -C $LibRoot rev-parse --short HEAD).Trim()
    if (git -C $LibRoot status --porcelain) { $commit += " (with uncommitted changes)" }
} catch { }

# --- Copy.
if (-not (Test-Path -LiteralPath $AddOnsPath)) { Write-Error "AddOns path not found: $AddOnsPath"; exit 1 }
# Absolute, so the stale-file sweep below compares like with like (with a
# relative path it matched nothing and deleted every file it had just copied:
# LibGlass's deploy).
$AddOnsPath = (Resolve-Path -LiteralPath $AddOnsPath).ProviderPath
$dest = Join-Path $AddOnsPath "$Addon\Libs\LibAccountSync-1.0"
Write-Host "Deploying LibAccountSync $commit -> $dest" -ForegroundColor Cyan
foreach ($f in $files) {
    $target = Join-Path $dest $f
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $LibRoot $f) -Destination $target -Force
}
# A file the library no longer ships must not linger where the client finds it.
$keep = $files | ForEach-Object { (Join-Path $dest $_).ToLowerInvariant() }
Get-ChildItem -LiteralPath $dest -File -Recurse | Where-Object { $keep -notcontains $_.FullName.ToLowerInvariant() } |
    ForEach-Object {
        Write-Host "  removing stale $($_.FullName.Substring($dest.Length + 1))" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $_.FullName -Force
    }
Write-Host "  $($files.Count) files"
