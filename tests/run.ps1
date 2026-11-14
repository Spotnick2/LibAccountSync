<#
    run.ps1 - Syntax-check the library and run every tests\test_*.lua under
    Lua 5.1, through WowTestKit's runner at the commit tests\kit.pin names;
    then the log reader's Python test.

    WoW runs Lua 5.1, so the tests do too - not a newer Lua that may be first
    on PATH. The XML is the list of runtime files, so a new one can't go
    unchecked.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
        pwsh tests/run.ps1 -KitDev        # the ..\WowTestKit working copy instead of the pin
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe",
    [switch]$KitDev
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "kit.ps1")
$kit = Get-WowTestKit -RepoRoot $RepoRoot -KitDev:$KitDev

# No TOC (a library): the files the XML loads are the ones to check, plus the
# probe and every Lua file under tests\ (the fixtures, the harness, the stub).
$xml = (Get-Content -LiteralPath (Join-Path $RepoRoot "LibAccountSync-1.0.xml") -Raw) -replace '(?s)<!--.*?-->', ''
$scripts = @([regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
Push-Location $RepoRoot
try {
    $extra = $scripts + @("Tools\LibAccountSyncProbe\LibAccountSyncProbe.lua") +
        @(Get-ChildItem "tests" -Filter "*.lua" -Recurse | Resolve-Path -Relative)
} finally { Pop-Location }
& (Join-Path $kit "scripts\run.ps1") -RepoRoot $RepoRoot -Extra $extra -Lua $Lua
$failed = $LASTEXITCODE -ne 0

# The probe's log reader is Python (Tools/read-wirelog.py), and so is its test.
$python = Get-Command python -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $PSScriptRoot "test_*.py") | Sort-Object Name | ForEach-Object {
    Write-Host "-- $($_.Name) " -NoNewline -ForegroundColor Cyan
    if (-not $python) { Write-Host "SKIPPED: no python on PATH" -ForegroundColor Yellow; return }
    Push-Location $RepoRoot
    try { & $python.Source -I $_.FullName; if ($LASTEXITCODE -ne 0) { $failed = $true } }
    finally { Pop-Location }
}
if ($failed) { Write-Host "FAILED" -ForegroundColor Red; exit 1 }
exit 0
