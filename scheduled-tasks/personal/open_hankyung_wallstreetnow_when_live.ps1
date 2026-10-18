param(
    [string]$LiveUrl = "https://www.youtube.com/@hkglobalmarket/live?autoplay=1",
    [string]$TitleRegex = "",
    [int]$PollEverySeconds = 60,
    [int]$MaxWaitMinutes = 60,
    [string]$ChromeProfileDirectory = "Default",
    [bool]$CloseWhenLiveEnds = $true,
    [int]$WatchEverySeconds = 30,
    [int]$MaxWatchMinutes = 180,
    [int]$EndedConfirmChecks = 3,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = "Continue"

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$logDir = Join-Path $env:LOCALAPPDATA "CodexAutomation"
$logFile = Join-Path $logDir "open_hankyung_wallstreetnow_when_live.log"

if ([string]::IsNullOrWhiteSpace($TitleRegex)) {
    $kimHyunSeok = [string]::Concat([char]0xAE40, [char]0xD604, [char]0xC11D)
    $wallStreetNow = [string]::Concat([char]0xC6D4, [char]0xC2A4, [char]0xD2B8, [char]0xB9AC, [char]0xD2B8, [char]0xB098, [char]0xC6B0)
    $TitleRegex = "$kimHyunSeok|$wallStreetNow"
}

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

if (-not ("HankyungChromeWindowTools" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class HankyungChromeWindowInfo {
    public long HandleValue;
    public int ProcessId;
    public string Title;
}

public class HankyungChromeWindowTools {
    private const uint WM_CLOSE = 0x0010;
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public static HankyungChromeWindowInfo[] GetVisibleWindows() {
        var windows = new List<HankyungChromeWindowInfo>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) {
                return true;
            }

            int length = GetWindowTextLength(hWnd);
            if (length <= 0) {
                return true;
            }

            var title = new StringBuilder(length + 1);
            GetWindowText(hWnd, title, title.Capacity);

            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);

            windows.Add(new HankyungChromeWindowInfo {
                HandleValue = hWnd.ToInt64(),
                ProcessId = (int)processId,
                Title = title.ToString()
            });

            return true;
        }, IntPtr.Zero);

        return windows.ToArray();
    }

    public static bool CloseWindow(long handleValue) {
        return PostMessage(new IntPtr(handleValue), WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }
}
"@
}

function Get-ChromeWindows {
    @([HankyungChromeWindowTools]::GetVisibleWindows()) | Where-Object {
        try {
            $process = Get-Process -Id $_.ProcessId -ErrorAction Stop
            $process.ProcessName -eq "chrome"
        } catch {
            $false
        }
    }
}

function Get-WindowSummary {
    param([object[]]$Windows)

    @($Windows | ForEach-Object { "$($_.HandleValue): $($_.Title)" }) -join " | "
}

function Wait-ForNewChromeWindow {
    param([hashtable]$BaselineWindowHandles)

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $newWindows = @(
            Get-ChromeWindows |
                Where-Object { !$BaselineWindowHandles.ContainsKey([string]$_.HandleValue) }
        )

        if ($newWindows.Count -gt 0) {
            Write-Log "[OK] Tracked opened Chrome window(s): $(Get-WindowSummary -Windows $newWindows)"
            return [long]$newWindows[0].HandleValue
        }

        Start-Sleep -Milliseconds 500
    }

    Write-Log "[WARN] Could not identify the newly opened Chrome window; live-end close will be skipped"
    return 0
}

function Test-ChromeWindowExists {
    param([long]$WindowHandle)

    if ($WindowHandle -le 0) {
        return $false
    }

    $window = Get-ChromeWindows |
        Where-Object { [long]$_.HandleValue -eq [long]$WindowHandle } |
        Select-Object -First 1

    return ($null -ne $window)
}

function Close-TrackedChromeWindow {
    param([long]$WindowHandle)

    if ($WindowHandle -le 0) {
        Write-Log "[WARN] No tracked Chrome window handle; not closing any Chrome window"
        return $false
    }

    $window = Get-ChromeWindows |
        Where-Object { [long]$_.HandleValue -eq [long]$WindowHandle } |
        Select-Object -First 1

    if (!$window) {
        Write-Log "[INFO] Tracked Chrome window is already closed. Handle=$WindowHandle"
        return $true
    }

    [HankyungChromeWindowTools]::CloseWindow([long]$WindowHandle) | Out-Null
    Write-Log "[OK] Closed tracked Chrome window only. Handle=$WindowHandle Title='$($window.Title)'"
    return $true
}

function Get-YouTubeLivePageState {
    param([string]$Url)

    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
        "Accept-Language" = "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7"
    }

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20 -Headers $headers
    $content = [string]$response.Content

    $title = ""
    $titleMatch = [regex]::Match($content, "<title>(.*?)</title>", "Singleline")
    if ($titleMatch.Success) {
        $title = [System.Net.WebUtility]::HtmlDecode($titleMatch.Groups[1].Value)
        $title = ($title -replace "\s+", " ").Trim()
    }

    $videoId = ""
    foreach ($pattern in @(
        '"externalVideoId":"(?<id>[A-Za-z0-9_-]+)"',
        '"canonicalUrl":"https://www\.youtube\.com/watch\?v=(?<id>[A-Za-z0-9_-]+)'
    )) {
        $match = [regex]::Match($content, $pattern)
        if ($match.Success) {
            $videoId = $match.Groups["id"].Value
            break
        }
    }

    $watchUrl = $Url
    if (![string]::IsNullOrWhiteSpace($videoId)) {
        $watchUrl = "https://www.youtube.com/watch?v=$videoId&autoplay=1"
    }

    [pscustomobject]@{
        Title = $title
        VideoId = $videoId
        WatchUrl = $watchUrl
        IsLiveNow = ($content -match '"isLiveNow":true')
        IsLiveContent = ($content -match '"isLiveContent":true')
        MatchesTitle = ([string]::IsNullOrWhiteSpace($TitleRegex) -or $title -match $TitleRegex)
    }
}

function Open-ChromeUrl {
    param([string]$Url)

    if (!(Test-Path -LiteralPath $chromePath)) {
        throw "Chrome not found: $chromePath"
    }

    $args = @(
        "--new-window",
        "--start-maximized",
        "--profile-directory=$ChromeProfileDirectory",
        "--autoplay-policy=no-user-gesture-required",
        $Url
    )

    $baselineWindowHandles = @{}
    foreach ($window in @(Get-ChromeWindows)) {
        $baselineWindowHandles[[string]$window.HandleValue] = $true
    }

    if ($WhatIfOnly) {
        Write-Log "[WHATIF] Would open Chrome: $Url"
        return [pscustomobject]@{
            Url = $Url
            LauncherProcessId = 0
            WindowHandle = 0
        }
    }

    $process = Start-Process -FilePath $chromePath -ArgumentList $args -PassThru
    $windowHandle = Wait-ForNewChromeWindow -BaselineWindowHandles $baselineWindowHandles
    Write-Log "[OK] Opened Chrome. Url=$Url LauncherProcessId=$([int]$process.Id) WindowHandle=$windowHandle"

    [pscustomobject]@{
        Url = $Url
        LauncherProcessId = [int]$process.Id
        WindowHandle = $windowHandle
    }
}

function Watch-LiveEndAndClose {
    param(
        [string]$WatchUrl,
        [long]$WindowHandle
    )

    if (!$CloseWhenLiveEnds) {
        Write-Log "Live-end close disabled; leaving opened Chrome window as-is"
        return
    }

    if ($WhatIfOnly) {
        Write-Log "[WHATIF] Would watch live end and close tracked Chrome window. Url=$WatchUrl"
        return
    }

    if ($WindowHandle -le 0) {
        Write-Log "[WARN] Live-end close skipped because the opened Chrome window was not tracked"
        return
    }

    Write-Log "Watching for live end. WatchEverySeconds=$WatchEverySeconds MaxWatchMinutes=$MaxWatchMinutes EndedConfirmChecks=$EndedConfirmChecks WindowHandle=$WindowHandle"

    $watchDeadline = (Get-Date).AddMinutes($MaxWatchMinutes)
    $notLiveChecks = 0
    while ((Get-Date) -lt $watchDeadline) {
        Start-Sleep -Seconds $WatchEverySeconds

        if (!(Test-ChromeWindowExists -WindowHandle $WindowHandle)) {
            Write-Log "Tracked Chrome window was closed before live-end detection"
            return
        }

        try {
            $state = Get-YouTubeLivePageState -Url $WatchUrl
            Write-Log ("Watch state: isLiveNow={0} isLiveContent={1} videoId={2} title='{3}'" -f $state.IsLiveNow, $state.IsLiveContent, $state.VideoId, $state.Title)

            if ($state.IsLiveNow) {
                $notLiveChecks = 0
                continue
            }

            $notLiveChecks++
            Write-Log "Live end candidate detected. ConsecutiveNotLiveChecks=$notLiveChecks/$EndedConfirmChecks"

            if ($notLiveChecks -ge $EndedConfirmChecks) {
                Close-TrackedChromeWindow -WindowHandle $WindowHandle | Out-Null
                Write-Log "Hankyung live watcher completed: live ended and tracked window closed"
                return
            }
        } catch {
            Write-Log "[WARN] Failed to read live state while watching end: $($_.Exception.Message)"
        }
    }

    Write-Log "Live-end watch timed out; leaving tracked Chrome window open. WindowHandle=$WindowHandle"
}

Write-Log "=============================================="
Write-Log "Hankyung Wall Street Now live watcher started"
Write-Log "LiveUrl: $LiveUrl"
Write-Log "TitleRegex: $TitleRegex"
Write-Log "PollEverySeconds: $PollEverySeconds"
Write-Log "MaxWaitMinutes: $MaxWaitMinutes"
Write-Log "ChromeProfileDirectory: $ChromeProfileDirectory"
Write-Log "CloseWhenLiveEnds: $CloseWhenLiveEnds"
Write-Log "WatchEverySeconds: $WatchEverySeconds"
Write-Log "MaxWatchMinutes: $MaxWatchMinutes"
Write-Log "EndedConfirmChecks: $EndedConfirmChecks"
Write-Log "WhatIfOnly: $WhatIfOnly"
Write-Log "=============================================="

$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
while ((Get-Date) -lt $deadline) {
    try {
        $state = Get-YouTubeLivePageState -Url $LiveUrl
        Write-Log ("State: isLiveNow={0} isLiveContent={1} matchesTitle={2} videoId={3} title='{4}'" -f $state.IsLiveNow, $state.IsLiveContent, $state.MatchesTitle, $state.VideoId, $state.Title)

        if ($state.IsLiveNow -and $state.MatchesTitle) {
            $openedChrome = Open-ChromeUrl -Url $state.WatchUrl
            Write-Log "Hankyung Wall Street Now live watcher opened live"
            Watch-LiveEndAndClose -WatchUrl $state.WatchUrl -WindowHandle $openedChrome.WindowHandle
            Write-Log "Hankyung Wall Street Now live watcher completed"
            exit 0
        }
    } catch {
        Write-Log "[WARN] Failed to read/open live state: $($_.Exception.Message)"
    }

    $remainingSeconds = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
    if ($remainingSeconds -le 0) {
        break
    }

    Start-Sleep -Seconds ([Math]::Min($PollEverySeconds, $remainingSeconds))
}

Write-Log "Hankyung Wall Street Now live watcher completed: no matching live found before timeout"
exit 0
