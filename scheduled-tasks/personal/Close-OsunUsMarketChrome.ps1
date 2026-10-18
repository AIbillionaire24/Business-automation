[CmdletBinding()]
param(
    [int]$CloseWindowMinutes = 75,
    [switch]$WhatIfOnly,
    [switch]$ForceCloseWindow
)

$ErrorActionPreference = "Stop"

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "close-osun-us-market-chrome.log"

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Encoding UTF8 -Value "$timestamp $Message"
}

function Test-MarketCloseWindow {
    param([int]$WindowMinutes)

    $nyZone = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
    $nyNow = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $nyZone)
    $tradingDays = @(
        [DayOfWeek]::Monday,
        [DayOfWeek]::Tuesday,
        [DayOfWeek]::Wednesday,
        [DayOfWeek]::Thursday,
        [DayOfWeek]::Friday
    )

    if ($tradingDays -notcontains $nyNow.DayOfWeek) {
        Write-Log "Skip: New York date is not a weekday ($($nyNow.DayOfWeek))."
        return $false
    }

    $closeTime = [datetime]::new($nyNow.Year, $nyNow.Month, $nyNow.Day, 16, 0, 0)
    $endTime = $closeTime.AddMinutes($WindowMinutes)
    if ($nyNow -lt $closeTime -or $nyNow -ge $endTime) {
        Write-Log "Skip: New York time $($nyNow.ToString('yyyy-MM-dd HH:mm:ss')) is outside close window."
        return $false
    }

    Write-Log "Proceed: New York time $($nyNow.ToString('yyyy-MM-dd HH:mm:ss')) is inside close window."
    return $true
}

function Test-TargetTitle {
    param([string]$Title)

    $patterns = @(
        "오선의 미국 증시 라이브",
        "오선의 미국증시 라이브",
        "오선",
        "미국증시",
        "미국 증시",
        "미국주식",
        "미국 주식",
        "US Market",
        "U.S. Market"
    )

    foreach ($pattern in $patterns) {
        if ($Title -like "*$pattern*") {
            return $true
        }
    }

    return $false
}

if ($ForceCloseWindow) {
    Write-Log "Force: market close window check bypassed."
} elseif (-not (Test-MarketCloseWindow -WindowMinutes $CloseWindowMinutes)) {
    return
}

try {

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class OsunUsMarketWindowTools
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@

$chromeProcesses = @(Get-Process chrome -ErrorAction SilentlyContinue)
if ($chromeProcesses.Count -eq 0) {
    Write-Log "No Chrome process found."
    return
}

$chromeIds = @{}
foreach ($process in $chromeProcesses) {
    $chromeIds[[uint32]$process.Id] = $true
}

$windows = New-Object System.Collections.Generic.List[object]
$callback = [OsunUsMarketWindowTools+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)

    if (-not [OsunUsMarketWindowTools]::IsWindowVisible($hWnd)) {
        return $true
    }

    $length = [OsunUsMarketWindowTools]::GetWindowTextLength($hWnd)
    if ($length -le 0) {
        return $true
    }

    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [void][OsunUsMarketWindowTools]::GetWindowText($hWnd, $builder, $builder.Capacity)

    [uint32]$windowProcessId = 0
    [void][OsunUsMarketWindowTools]::GetWindowThreadProcessId($hWnd, [ref]$windowProcessId)
    if ($chromeIds.ContainsKey($windowProcessId)) {
        $windows.Add([pscustomobject]@{
            Handle = $hWnd
            ProcessId = $windowProcessId
            Title = $builder.ToString()
        })
    }

    return $true
}

[void][OsunUsMarketWindowTools]::EnumWindows($callback, [IntPtr]::Zero)

$targets = @($windows | Where-Object { Test-TargetTitle -Title $_.Title })
if ($targets.Count -eq 0) {
    $knownTitles = ($windows | ForEach-Object { $_.Title }) -join " | "
    Write-Log "No matching Chrome window found. Chrome titles: $knownTitles"
    return
}

$wmClose = 0x0010
foreach ($target in $targets) {
    Write-Log "Closing Chrome window: pid=$($target.ProcessId), title=$($target.Title)"
    if (-not $WhatIfOnly) {
        [void][OsunUsMarketWindowTools]::PostMessage($target.Handle, $wmClose, [IntPtr]::Zero, [IntPtr]::Zero)
    }
}

} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
