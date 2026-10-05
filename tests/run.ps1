<#
    run.ps1 - Syntax-check the library and run every tests\test_*.lua under Lua 5.1.

    WoW runs Lua 5.1, so the tests do too - not a newer Lua that may be first
    on PATH. The XML is the list of runtime files, so a new one can't go
    unchecked.

    Usage:
        pwsh tests/run.ps1
        pwsh tests/run.ps1 -Lua "C:\path\to\lua5.1.exe"
#>

param(
    [string]$Lua = "C:\Program Files (x86)\Lua\5.1\lua.exe"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Lua)) { Write-Error "Lua 5.1 not found at $Lua (pass -Lua <path>)"; exit 1 }
$RepoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $RepoRoot
try {
    $luac = Join-Path (Split-Path -Parent $Lua) "luac.exe"
    $xml = (Get-Content "LibAccountSync-1.0.xml" -Raw) -replace '(?s)<!--.*?-->', ''   # listed in a comment is not loaded
    $xmlFiles = [regex]::Matches($xml, '<Script\s+file="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $testFiles = Get-ChildItem (Join-Path $PSScriptRoot "*.lua") -Recurse | ForEach-Object { $_.FullName }
    if (-not (Test-Path $luac)) {
        Write-Host "luac -p SKIPPED: no luac.exe beside $Lua - syntax was NOT checked" -ForegroundColor Yellow
    } else {
        & $luac -p @xmlFiles @testFiles
        if ($LASTEXITCODE -ne 0) { Write-Host "luac -p FAILED" -ForegroundColor Red; exit 1 }
        Remove-Item -LiteralPath "luac.out" -ErrorAction SilentlyContinue
        Write-Host "luac -p: ok ($($xmlFiles.Count) library files + $($testFiles.Count) test files)" -ForegroundColor DarkGray
    }

    $failed = 0
    Get-ChildItem (Join-Path $PSScriptRoot "test_*.lua") | Sort-Object Name | ForEach-Object {
        Write-Host "-- $($_.Name) " -NoNewline -ForegroundColor Cyan
        & $Lua $_.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -gt 0) { Write-Host "$failed test file(s) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "All test files passed." -ForegroundColor Green
}
finally { Pop-Location }
