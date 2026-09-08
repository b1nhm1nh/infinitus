# windows/perf.ps1 — idle-CPU / RSS / heap-growth / USER+GDI handle gate
# for infinitus-tray-win (phase 07 step 0).
#
# Mirrors tools/e2e.sh: two samples WINDOW_S apart, idle % =
# (cpuSeconds_B - cpuSeconds_A) / WINDOW_S * 100. The tray has no control
# socket, so this samples Get-Process + GetGuiResources rather than
# `infinitus-win control perf` (that route still exists for the daemon).
#
# Budgets are Windows-baseline, not the Mac's 8% / 220 MB. Override via
# env: IDLE_BUDGET_PCT, RSS_BUDGET_MB, GROWTH_BUDGET_KB_MIN,
# USER_BUDGET, GDI_BUDGET.
#
# Usage (repo root, env.ps1 already sourced):
#   powershell -File windows\perf.ps1                # launch --panel, gate
#   powershell -File windows\perf.ps1 -Mode closed   # tray, panel not shown
#   powershell -File windows\perf.ps1 -TargetPid 1234  # already-running tray

[CmdletBinding()]
param(
    [ValidateSet("open", "closed", "both")]
    [string]$Mode = "open",
    [int]$WindowSeconds = 15,
    # Launch-time caches / first engine probe land here (tools/e2e.sh sleeps 10).
    [int]$WarmupSeconds = 15,
    # Not -Pid: $PID is a PowerShell automatic variable (this process).
    [int]$TargetPid,
    [string]$Exe,
    [string]$ScratchPath
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$envScript = Join-Path $PSScriptRoot "env.ps1"
if (Test-Path $envScript) { . $envScript }

# Formula matches tools/e2e.sh: (delta cpuSeconds / wall) * 100 = % of
# ONE core. The README's 0.13% / 30 MB is Task Manager's all-cores view
# (0.13% * 32 cores ≈ 4% of one core — closed idle after warmup). Measured
# debug baseline 2026-09-07, 15 s window after 30 s warmup:
#   closed  2.91%  29.9 MB  USER 5  GDI 7
#   open    10.29% 40.7 MB  USER 16 GDI 16
# Headroom is for a busy box, not tens of points — a 20 fps GDI repaint
# timer still fails this. heapBytes is PrivateUsage, which swings several
# MB between samples on a debug binary (Swift runtime / Foundation caches);
# the growth number is reported, not gated, unless it is huge.
$IdleBudgetPct = if ($env:IDLE_BUDGET_PCT) { [double]$env:IDLE_BUDGET_PCT } else { 20.0 }
$RssBudgetMb = if ($env:RSS_BUDGET_MB) { [int]$env:RSS_BUDGET_MB } else { 80 }
$GrowthBudgetKbMin = if ($env:GROWTH_BUDGET_KB_MIN) { [int]$env:GROWTH_BUDGET_KB_MIN } else { 32768 }
$UserBudget = if ($env:USER_BUDGET) { [int]$env:USER_BUDGET } else { 256 }
$GdiBudget = if ($env:GDI_BUDGET) { [int]$env:GDI_BUDGET } else { 256 }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WinGuiResources {
    [DllImport("user32.dll")]
    public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
    public const uint GR_GDIOBJECTS = 0;
    public const uint GR_USEROBJECTS = 1;
}
"@

function Find-TrayExe {
    if ($Exe) { return $Exe }
    if ($env:INFINITUS_TRAY_EXE -and (Test-Path $env:INFINITUS_TRAY_EXE)) {
        return $env:INFINITUS_TRAY_EXE
    }
    $roots = @()
    if ($ScratchPath) { $roots += (Join-Path $root $ScratchPath) }
    $roots += (Join-Path $root ".build-p07")
    $roots += (Join-Path $root ".build")
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $hits = @(Get-ChildItem -Path $r -Recurse -Filter "infinitus-tray-win.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($hits.Count -gt 0) { return $hits[0].FullName }
    }
    return $null
}

function Get-Sample([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $handle = $p.Handle
    $user = [WinGuiResources]::GetGuiResources($handle, [WinGuiResources]::GR_USEROBJECTS)
    $gdi = [WinGuiResources]::GetGuiResources($handle, [WinGuiResources]::GR_GDIOBJECTS)
    return [pscustomobject]@{
        At            = [DateTime]::UtcNow
        CpuSeconds    = $p.TotalProcessorTime.TotalSeconds
        RssBytes      = [int64]$p.WorkingSet64
        HeapBytes     = [int64]$p.PrivateMemorySize64
        Threads       = [int]$p.Threads.Count
        Handles       = [int]$p.HandleCount
        UserHandles   = [int]$user
        GdiHandles    = [int]$gdi
    }
}

function Write-Sample([string]$label, $s) {
    $rssMb = [math]::Round($s.RssBytes / 1MB, 1)
    $heapMb = [math]::Round($s.HeapBytes / 1MB, 1)
    Write-Host ("  {0}: cpuSeconds={1:N3} rss={2} MB heap={3} MB threads={4} USER={5} GDI={6} handles={7}" -f `
        $label, $s.CpuSeconds, $rssMb, $heapMb, $s.Threads, $s.UserHandles, $s.GdiHandles, $s.Handles)
}

function Invoke-Gate([string]$label, [int]$ProcessId) {
    Write-Host "==> sampling $label (pid $ProcessId) twice, ${WindowSeconds}s apart"
    $a = Get-Sample $ProcessId
    Write-Sample "A" $a
    Start-Sleep -Seconds $WindowSeconds
    $b = Get-Sample $ProcessId
    Write-Sample "B" $b

    $dt = ($b.At - $a.At).TotalSeconds
    if ($dt -le 0) { throw "zero-length sample window" }
    $idlePct = [math]::Round((($b.CpuSeconds - $a.CpuSeconds) / $dt) * 100.0, 2)
    $rssMb = [math]::Round($b.RssBytes / 1MB, 1)
    $growthKbMin = [int]((($b.HeapBytes - $a.HeapBytes) / 1024.0) * 60.0 / $dt)
    $userDelta = $b.UserHandles - $a.UserHandles
    $gdiDelta = $b.GdiHandles - $a.GdiHandles

    Write-Host ("idle CPU ($label): {0}%  rss: {1} MB  heap growth: {2} KB/min  USER {3} (d{4:+0;-0;0})  GDI {5} (d{6:+0;-0;0})  (budgets {7}% / {8} MB / {9} KB/min / USER {10} / GDI {11})" -f `
        $idlePct, $rssMb, $growthKbMin, $b.UserHandles, $userDelta, $b.GdiHandles, $gdiDelta, `
        $IdleBudgetPct, $RssBudgetMb, $GrowthBudgetKbMin, $UserBudget, $GdiBudget)

    $failures = @()
    if ($idlePct -gt $IdleBudgetPct) { $failures += "idle CPU ${idlePct}% over budget ${IdleBudgetPct}%" }
    if ($rssMb -gt $RssBudgetMb) { $failures += "RSS ${rssMb} MB over budget ${RssBudgetMb} MB" }
    if ($growthKbMin -gt $GrowthBudgetKbMin) { $failures += "idle heap growth ${growthKbMin} KB/min over budget ${GrowthBudgetKbMin} KB/min" }
    if ($b.UserHandles -gt $UserBudget) { $failures += "USER handles $($b.UserHandles) over budget $UserBudget" }
    if ($b.GdiHandles -gt $GdiBudget) { $failures += "GDI handles $($b.GdiHandles) over budget $GdiBudget" }
    # Absolute USER/GDI budgets catch a leak. A +1 during a 15 s window is
    # first-paint jitter (a font, an icon); fail only on a real climb.
    if ($userDelta -ge 8) { $failures += "USER handles grew by $userDelta during idle window" }
    elseif ($userDelta -gt 0) { Write-Host "WARN: USER handles grew by $userDelta during idle window" }
    if ($gdiDelta -ge 8) { $failures += "GDI handles grew by $gdiDelta during idle window" }
    elseif ($gdiDelta -gt 0) { Write-Host "WARN: GDI handles grew by $gdiDelta during idle window" }

    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { Write-Host "FAIL: $f" }
        return $false
    }
    Write-Host "PASS: $label idle gate"
    return $true
}

function Start-Tray([string]$path, [string[]]$ExtraArgs) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $path
    $psi.Arguments = ($ExtraArgs -join " ")
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $root
    $psi.EnvironmentVariables["Path"] = $env:Path
    if ($env:INFINITUS_ACCOUNTS_JSON) {
        $psi.EnvironmentVariables["INFINITUS_ACCOUNTS_JSON"] = $env:INFINITUS_ACCOUNTS_JSON
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 200
        try {
            $live = Get-Process -Id $proc.Id -ErrorAction Stop
            if ($live.WorkingSet64 -gt 0) { return $proc }
        } catch { }
    }
    if ($proc.HasExited) {
        throw "tray exited immediately (code $($proc.ExitCode))"
    }
    return $proc
}

function Stop-Tray($proc) {
    if (-not $proc) { return }
    try {
        if (-not $proc.HasExited) {
            $proc.Kill()
            $proc.WaitForExit(3000) | Out-Null
        }
    } catch { }
}

$pass = $true
$launched = $null

try {
    if ($TargetPid) {
        $null = Get-Process -Id $TargetPid -ErrorAction Stop
        $modes = if ($Mode -eq "both") { @("open") } else { @($Mode) }
        foreach ($m in $modes) {
            if (-not (Invoke-Gate "tray pid $TargetPid ($m)" $TargetPid)) { $pass = $false }
        }
    } else {
        $tray = Find-TrayExe
        if (-not $tray) {
            Write-Error "infinitus-tray-win.exe not found. Build it first (swift build --product infinitus-tray-win) or pass -Exe / INFINITUS_TRAY_EXE."
            exit 2
        }
        $run = @()
        if ($Mode -eq "both") { $run = @("closed", "open") } else { $run = @($Mode) }
        foreach ($m in $run) {
            $trayArgs = @()
            $label = "tray, panel closed"
            if ($m -eq "open") {
                $trayArgs = @("--panel")
                $label = "tray, panel open"
            }
            Write-Host "==> launching $tray $($trayArgs -join ' ')"
            $launched = Start-Tray $tray $trayArgs
            if ($WarmupSeconds -gt 0) {
                Write-Host "==> warmup ${WarmupSeconds}s (launch caches, first engine probe)"
                Start-Sleep -Seconds $WarmupSeconds
            }
            if (-not (Invoke-Gate $label $launched.Id)) { $pass = $false }
            Stop-Tray $launched
            $launched = $null
        }
    }
} finally {
    Stop-Tray $launched
}

if (-not $pass) { exit 1 }
Write-Host "perf gate: ok"
exit 0
