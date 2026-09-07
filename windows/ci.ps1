# windows/ci.ps1 — Continuous integration script for Windows.
# Builds both products (one --product per invocation per CLAUDE.md), runs
# the test suite, then the tray idle-CPU gate (windows/perf.ps1).
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    . (Join-Path $PSScriptRoot "env.ps1")

    Write-Host "==> Building infinitus-win..."
    swift build --product infinitus-win
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> Building infinitus-tray-win..."
    swift build --product infinitus-tray-win
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> Running test suite..."
    swift test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Advisory on the GitHub windows job (continue-on-error: true) — still
    # a real local gate, and the only idle-CPU check Windows has. Samples
    # the tray with the accounts panel open, twice 15 s apart.
    Write-Host "==> Perf gate (tray, panel open)..."
    & (Join-Path $PSScriptRoot "perf.ps1") -Mode open -WindowSeconds 15 -WarmupSeconds 15 -ScratchPath ".build"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "==> CI completed successfully."
    exit 0
}
finally {
    Pop-Location
}
