param(
    [string]$Url = "https://www.youtube.com/channel/UCWskYkV4c4S9D__rsfOl2JA/live?autoplay=1",
    [int]$RefreshEverySeconds = 60,
    [int]$DurationMinutes = 10,
    [int]$InitialDelaySeconds = 20,
    [object]$CloseWhenLiveEnds = $true,
    [int]$WatchEverySeconds = 30,
    [int]$MaxWatchMinutes = 45,
    [int]$EndedConfirmChecks = 3,
    [int]$MaxWatchReadFailures = 10,
    [int]$RemoteDebuggingPort = 0,
    [string]$ProfileName = "youtube-live",
    [int]$PlaybackVolumePercent = 25,
    [object]$DisableYouTubeAutoplay = $true,
    [string[]]$ExtensionPaths = @(),
    [string]$ExtensionNamePattern = "AdBlocker Ultimate|Adblock Ultimate|AdBlock Ultimate",
    [object]$UseExistingChromeProfile = $false,
    [object]$ExistingProfileOpenOnly = $false,
    [string]$ChromeProfileDirectory = "Default"
)

$ErrorActionPreference = "Continue"

function ConvertTo-BoolValue {
    param(
        [object]$Value,
        [bool]$Default
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    if ($Value -is [int] -or $Value -is [long]) {
        return ([int64]$Value -ne 0)
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch ($text.ToLowerInvariant()) {
        '$true' { return $true }
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        '$false' { return $false }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        default { return $Default }
    }
}

$CloseWhenLiveEnds = ConvertTo-BoolValue -Value $CloseWhenLiveEnds -Default $true
$DisableYouTubeAutoplay = ConvertTo-BoolValue -Value $DisableYouTubeAutoplay -Default $true
$UseExistingChromeProfile = ConvertTo-BoolValue -Value $UseExistingChromeProfile -Default $false
$ExistingProfileOpenOnly = ConvertTo-BoolValue -Value $ExistingProfileOpenOnly -Default $false

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$holidayFile = "C:\Scripts\hiworks_holidays.txt"
$logDir = Join-Path $env:LOCALAPPDATA "CodexAutomation"
$logFile = Join-Path $logDir "open_youtube_live_with_refresh.log"
$runId = "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $PID
$safeProfileName = ($ProfileName -replace '[^A-Za-z0-9_-]', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeProfileName)) {
    $safeProfileName = "youtube-live"
}
$chromeProfileDir = Join-Path $logDir "chrome-$safeProfileName-$runId"

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

try {
    Get-ChildItem -LiteralPath $logDir -Directory -Filter "chrome-$safeProfileName-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    # Old temporary Chrome profiles are best-effort cleanup only.
}

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

function Get-HolidayReason {
    param([datetime]$Date)

    if (!(Test-Path -LiteralPath $holidayFile)) {
        return $null
    }

    $dateText = $Date.ToString("yyyy-MM-dd")
    foreach ($line in Get-Content -LiteralPath $holidayFile -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match '^(?<date>\d{4}-\d{2}-\d{2})(?:\s+(?<reason>.*))?$') {
            if ($Matches.date -eq $dateText) {
                if ([string]::IsNullOrWhiteSpace($Matches.reason)) {
                    return "configured holiday"
                }
                return $Matches.reason
            }
        }
    }

    return $null
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Get-ExtensionManifestName {
    param(
        [string]$ManifestPath,
        [object]$Manifest
    )

    $name = [string]$Manifest.name
    if ($name -notmatch '^__MSG_(.+)__$') {
        return $name
    }

    $messageKey = $Matches[1]
    $extensionDir = Split-Path -Parent $ManifestPath
    foreach ($locale in @($Manifest.default_locale, "ko", "en", "en_US")) {
        if ([string]::IsNullOrWhiteSpace($locale)) {
            continue
        }

        $messagesPath = Join-Path $extensionDir "_locales\$locale\messages.json"
        if (!(Test-Path -LiteralPath $messagesPath)) {
            continue
        }

        try {
            $messages = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($messages.$messageKey.message) {
                return [string]$messages.$messageKey.message
            }
        } catch {
            continue
        }
    }

    $name
}

function Resolve-ChromeExtensionPaths {
    param(
        [string[]]$ExplicitPaths,
        [string]$NamePattern
    )

    $resolvedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($ExplicitPaths)) {
        if (![string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $resolvedPaths.Add((Resolve-Path -LiteralPath $path).Path)
        }
    }

    if ($resolvedPaths.Count -gt 0 -or [string]::IsNullOrWhiteSpace($NamePattern)) {
        return @($resolvedPaths)
    }

    $chromeUserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    if (!(Test-Path -LiteralPath $chromeUserData)) {
        return @()
    }

    $extensionMatches = New-Object System.Collections.Generic.List[object]
    $profiles = Get-ChildItem -LiteralPath $chromeUserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }

    foreach ($profile in $profiles) {
        $extensionsRoot = Join-Path $profile.FullName "Extensions"
        if (!(Test-Path -LiteralPath $extensionsRoot)) {
            continue
        }

        foreach ($extensionIdDir in Get-ChildItem -LiteralPath $extensionsRoot -Directory -Force -ErrorAction SilentlyContinue) {
            foreach ($versionDir in Get-ChildItem -LiteralPath $extensionIdDir.FullName -Directory -Force -ErrorAction SilentlyContinue) {
                $manifestPath = Join-Path $versionDir.FullName "manifest.json"
                if (!(Test-Path -LiteralPath $manifestPath)) {
                    continue
                }

                try {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $extensionName = Get-ExtensionManifestName -ManifestPath $manifestPath -Manifest $manifest
                    if ($extensionName -match $NamePattern) {
                        $versionValue = [version]"0.0"
                        [void][version]::TryParse([string]$manifest.version, [ref]$versionValue)
                        $extensionMatches.Add([PSCustomObject]@{
                            Name = $extensionName
                            Version = $versionValue
                            Path = $versionDir.FullName
                            LastWriteTime = $versionDir.LastWriteTime
                        })
                    }
                } catch {
                    continue
                }
            }
        }
    }

    $match = $extensionMatches |
        Sort-Object Version, LastWriteTime -Descending |
        Select-Object -First 1

    if ($match) {
        return @($match.Path)
    }

    @()
}

function Quote-ChromeArgumentValue {
    param([string]$Value)

    '"' + ($Value -replace '"', '\"') + '"'
}

function Get-CdpTargets {
    param([int]$Port)

    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3
}

function Get-CdpPageTarget {
    param([int]$Port)

    $targets = Get-CdpTargets -Port $Port
    $targets |
        Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } |
        Sort-Object @{ Expression = { $_.url -notlike "*youtube.com*" } }, id |
        Select-Object -First 1
}

function Wait-ForCdpPageTarget {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $target = Get-CdpPageTarget -Port $Port
            if ($target) {
                return $target
            }
        } catch {
        }

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Invoke-CdpCommand {
    param(
        [string]$WebSocketUrl,
        [string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 8
    )

    $client = [System.Net.WebSockets.ClientWebSocket]::new()
    $cancel = [System.Threading.CancellationToken]::None
    try {
        $connected = $client.ConnectAsync([Uri]$WebSocketUrl, $cancel)
        if (!$connected.Wait($TimeoutSeconds * 1000)) {
            throw "CDP websocket connect timed out"
        }

        $id = Get-Random -Minimum 1000 -Maximum 999999
        $payload = @{
            id = $id
            method = $Method
            params = $Params
        } | ConvertTo-Json -Depth 20 -Compress

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        $sent = $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel)
        if (!$sent.Wait($TimeoutSeconds * 1000)) {
            throw "CDP websocket send timed out"
        }

        $buffer = New-Object byte[] 65536
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $builder = [System.Text.StringBuilder]::new()
        while ((Get-Date) -lt $deadline) {
            $receiveSegment = [ArraySegment[byte]]::new($buffer)
            $received = $client.ReceiveAsync($receiveSegment, $cancel)
            if (!$received.Wait(1000)) {
                continue
            }

            $result = $received.Result
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                break
            }

            [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
            if (!$result.EndOfMessage) {
                continue
            }

            $text = $builder.ToString()
            [void]$builder.Clear()
            try {
                $json = $text | ConvertFrom-Json
                if ($json.id -eq $id) {
                    return $json
                }
            } catch {
            }
        }

        throw "CDP response timed out: $Method"
    } finally {
        try {
            if ($client.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $client.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $cancel).Wait(1000) | Out-Null
            }
        } catch {
        }
        $client.Dispose()
    }
}

function Invoke-PageCommand {
    param(
        [int]$Port,
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $target = Get-CdpPageTarget -Port $Port
    if (!$target) {
        throw "Chrome page target not found"
    }

    Invoke-CdpCommand -WebSocketUrl $target.webSocketDebuggerUrl -Method $Method -Params $Params
}

function Get-YouTubeLiveState {
    param([int]$Port)

    $expression = @'
(() => {
  const text = ((document.body && document.body.innerText) || '').toLowerCase();
  const video = document.querySelector('video');
  const duration = video ? video.duration : null;
  const finiteDuration = Number.isFinite(duration);
  const liveBadge = !!document.querySelector('.ytp-live-badge');
  const endedText =
    text.includes('this live stream has ended') ||
    text.includes('streamed live') ||
    text.includes('stream ended') ||
    text.includes('live stream recording is not available') ||
    text.includes('실시간 스트리밍이 종료') ||
    text.includes('스트리밍이 종료') ||
    text.includes('라이브 스트림이 종료');
  const upcomingText =
    text.includes('waiting for') ||
    text.includes('premieres in') ||
    text.includes('scheduled for') ||
    text.includes('대기 중') ||
    text.includes('예정');
  const liveByDuration = !!(video && !finiteDuration && video.readyState > 0);
  const videoEnded = !!(video && video.ended);
  const state = {
    title: document.title || '',
    href: location.href,
    hasVideo: !!video,
    liveBadge,
    liveByDuration,
    videoEnded,
    finiteDuration,
    duration: finiteDuration ? duration : null,
    endedText,
    upcomingText
  };
  state.isLive = !!(liveBadge || liveByDuration);
  state.isEnded = !!(endedText || videoEnded);
  return JSON.stringify(state);
})()
'@

    $response = Invoke-PageCommand -Port $Port -Method "Runtime.evaluate" -Params @{
        expression = $expression
        returnByValue = $true
        awaitPromise = $true
    }

    $value = $response.result.result.value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $value | ConvertFrom-Json
}

function Set-YouTubePlaybackVolume {
    param(
        [int]$Port,
        [int]$VolumePercent
    )

    $clampedPercent = [Math]::Max(0, [Math]::Min(100, $VolumePercent))
    $volume = [Math]::Round($clampedPercent / 100, 2)
    $expression = @"
(() => {
  const percent = $clampedPercent;
  const volume = $volume;
  const now = Date.now();
  try {
    localStorage.setItem('yt-player-volume', JSON.stringify({
      data: String(percent),
      creation: now,
      expiration: now + 31536000000
    }));
  } catch (e) {}

  function applyVolume() {
    const videos = Array.from(document.querySelectorAll('video'));
    for (const video of videos) {
      video.volume = volume;
      video.dispatchEvent(new Event('volumechange', { bubbles: true }));
    }
    return videos.length;
  }

  const count = applyVolume();
  clearInterval(window.__codexYoutubeVolumeTimer);
  window.__codexYoutubeVolumeTimer = setInterval(applyVolume, 5000);
  return JSON.stringify({ ok: count > 0, videoCount: count, volume: volume, percent: percent });
})()
"@

    $response = Invoke-PageCommand -Port $Port -Method "Runtime.evaluate" -Params @{
        expression = $expression
        returnByValue = $true
        awaitPromise = $true
    }

    $value = $response.result.result.value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $value | ConvertFrom-Json
}

function Install-YouTubeVolumeLimiter {
    param(
        [int]$Port,
        [int]$VolumePercent
    )

    $clampedPercent = [Math]::Max(0, [Math]::Min(100, $VolumePercent))
    $volume = [Math]::Round($clampedPercent / 100, 2)
    $expression = @"
(() => {
  const percent = $clampedPercent;
  const volume = $volume;
  const now = Date.now();

  function savePreference() {
    try {
      if (!/youtube\.com$/i.test(location.hostname) && !/\.youtube\.com$/i.test(location.hostname)) {
        return;
      }
      localStorage.setItem('yt-player-volume', JSON.stringify({
        data: String(percent),
        creation: now,
        expiration: now + 31536000000
      }));
    } catch (e) {}
  }

  function applyVolume() {
    savePreference();
    const media = Array.from(document.querySelectorAll('video,audio'));
    for (const item of media) {
      item.volume = volume;
      item.dispatchEvent(new Event('volumechange', { bubbles: true }));
    }
  }

  if (!window.__codexYoutubeVolumeLimiterInstalled) {
    window.__codexYoutubeVolumeLimiterInstalled = true;
    const nativePlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function(...args) {
      try {
        this.volume = volume;
      } catch (e) {}
      return nativePlay.apply(this, args);
    };
  }

  function start() {
    applyVolume();
    clearInterval(window.__codexYoutubeVolumeLimiterTimer);
    window.__codexYoutubeVolumeLimiterTimer = setInterval(applyVolume, 1000);
    try {
      const root = document.documentElement || document.body;
      if (root && window.MutationObserver) {
        if (window.__codexYoutubeVolumeLimiterObserver) {
          window.__codexYoutubeVolumeLimiterObserver.disconnect();
        }
        window.__codexYoutubeVolumeLimiterObserver = new MutationObserver(applyVolume);
        window.__codexYoutubeVolumeLimiterObserver.observe(root, { childList: true, subtree: true });
      }
    } catch (e) {}
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  }
  start();
})()
"@

    Invoke-PageCommand -Port $Port -Method "Page.addScriptToEvaluateOnNewDocument" -Params @{
        source = $expression
    } | Out-Null

    Invoke-PageCommand -Port $Port -Method "Runtime.evaluate" -Params @{
        expression = $expression
        returnByValue = $true
        awaitPromise = $true
    } | Out-Null
}

function Install-YouTubeAutoplayBlocker {
    param([int]$Port)

    $expression = @'
(() => {
  function isYouTube() {
    return /(^|\.)youtube\.com$/i.test(location.hostname);
  }

  function disableAutoplay() {
    const result = { toggleFound: false, toggled: false, disabled: false };
    if (!isYouTube()) {
      return result;
    }

    try {
      localStorage.setItem('yt-autonav-paused', 'true');
      localStorage.setItem('yt-player-autonav', 'false');
    } catch (e) {}

    const candidates = Array.from(document.querySelectorAll(
      '.ytp-autonav-toggle-button, button[aria-label*="Autoplay"], button[aria-label*="자동재생"]'
    ));

    for (const element of candidates) {
      const button = element.closest ? (element.closest('button') || element) : element;
      result.toggleFound = true;

      const checked = button.getAttribute('aria-checked');
      const pressed = button.getAttribute('aria-pressed');
      if (checked === 'false' || pressed === 'false') {
        result.disabled = true;
        continue;
      }

      if (checked === 'true' || pressed === 'true') {
        button.click();
        result.toggled = true;
        result.disabled = true;
      }
    }

    return result;
  }

  function start() {
    const firstResult = disableAutoplay();
    clearInterval(window.__codexYoutubeAutoplayBlockerTimer);
    window.__codexYoutubeAutoplayBlockerTimer = setInterval(disableAutoplay, 2000);
    return firstResult;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
    return JSON.stringify({ pending: true });
  }

  return JSON.stringify(start());
})()
'@

    Invoke-PageCommand -Port $Port -Method "Page.addScriptToEvaluateOnNewDocument" -Params @{
        source = $expression
    } | Out-Null

    $response = Invoke-PageCommand -Port $Port -Method "Runtime.evaluate" -Params @{
        expression = $expression
        returnByValue = $true
        awaitPromise = $true
    }

    $value = $response.result.result.value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $value | ConvertFrom-Json
}

if (-not ("YouTubeLiveWindowTools" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class YouTubeLiveWindowInfo {
    public long HandleValue;
    public int ProcessId;
    public string Title;
}

public class YouTubeLiveWindowTools {
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

    public static YouTubeLiveWindowInfo[] GetVisibleWindows() {
        var windows = new List<YouTubeLiveWindowInfo>();
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

            windows.Add(new YouTubeLiveWindowInfo {
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

function Get-YouTubeLiveChromeWindows {
    @([YouTubeLiveWindowTools]::GetVisibleWindows()) | Where-Object {
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

function Close-LiveChrome {
    param(
        [int]$Port,
        [string]$ProfileDir,
        [int]$BrowserProcessId = 0,
        [long[]]$WindowHandles = @(),
        [string]$TitlePattern = ""
    )

    try {
        $browserVersion = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 3
        if ($browserVersion.webSocketDebuggerUrl) {
            Invoke-CdpCommand -WebSocketUrl $browserVersion.webSocketDebuggerUrl -Method "Browser.close" -TimeoutSeconds 5 | Out-Null
            Write-Log "[OK] Requested dedicated Chrome browser close"
            Start-Sleep -Seconds 3
        }
    } catch {
        Write-Log "[WARN] Browser.close was not available before close: $($_.Exception.Message)"
    }

    try {
        $targets = Get-CdpTargets -Port $Port
        foreach ($target in $targets) {
            if ($target.type -eq "page" -and $target.id) {
                try {
                    Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/close/{1}" -f $Port, [Uri]::EscapeDataString($target.id)) -TimeoutSec 3 | Out-Null
                    Write-Log "[OK] Requested Chrome page close: $($target.title)"
                } catch {
                    Write-Log "[WARN] Failed to request Chrome page close: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "[WARN] Could not query Chrome targets before close: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 3

    foreach ($handle in @($WindowHandles | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        try {
            $window = Get-YouTubeLiveChromeWindows | Where-Object { [long]$_.HandleValue -eq [long]$handle } | Select-Object -First 1
            if ($window) {
                [YouTubeLiveWindowTools]::CloseWindow([long]$handle) | Out-Null
                Write-Log "[OK] Sent close message to tracked Chrome window: $($window.Title)"
            } else {
                Write-Log "[INFO] Tracked Chrome window handle not found: $handle"
            }
        } catch {
            Write-Log "[WARN] Failed to close tracked Chrome window $handle`: $($_.Exception.Message)"
        }
    }

    if (![string]::IsNullOrWhiteSpace($TitlePattern)) {
        try {
            $matchedWindows = @(Get-YouTubeLiveChromeWindows | Where-Object { $_.Title -match $TitlePattern })
            foreach ($window in $matchedWindows) {
                [YouTubeLiveWindowTools]::CloseWindow([long]$window.HandleValue) | Out-Null
                Write-Log "[OK] Sent fallback close message to Chrome window: $($window.Title)"
            }
        } catch {
            Write-Log "[WARN] Failed title-based Chrome close fallback: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2

    try {
        $allChromeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'")
        $matchedProcesses = New-Object System.Collections.Generic.List[object]

        if (![string]::IsNullOrWhiteSpace($ProfileDir)) {
            foreach ($chromeProcess in $allChromeProcesses) {
                if ($chromeProcess.CommandLine -and $chromeProcess.CommandLine.Contains($ProfileDir)) {
                    $matchedProcesses.Add($chromeProcess)
                }
            }
        }

        if ($BrowserProcessId -gt 0) {
            $processesByParent = @{}
            foreach ($chromeProcess in $allChromeProcesses) {
                $parentId = [int]$chromeProcess.ParentProcessId
                if (!$processesByParent.ContainsKey($parentId)) {
                    $processesByParent[$parentId] = New-Object System.Collections.Generic.List[object]
                }
                $processesByParent[$parentId].Add($chromeProcess)
            }

            $pending = [System.Collections.Queue]::new()
            $visited = @{}
            $pending.Enqueue($BrowserProcessId)
            while ($pending.Count -gt 0) {
                $processId = [int]$pending.Dequeue()
                if ($visited.ContainsKey($processId)) {
                    continue
                }
                $visited[$processId] = $true

                foreach ($chromeProcess in $allChromeProcesses) {
                    if ([int]$chromeProcess.ProcessId -eq $processId) {
                        $matchedProcesses.Add($chromeProcess)
                        break
                    }
                }

                if ($processesByParent.ContainsKey($processId)) {
                    foreach ($childProcess in $processesByParent[$processId]) {
                        $pending.Enqueue([int]$childProcess.ProcessId)
                    }
                }
            }
        }

        $chromeProcesses = @($matchedProcesses | Sort-Object ProcessId -Unique)
        if ($chromeProcesses.Count -eq 0) {
            Write-Log "[INFO] No dedicated Chrome process found to stop. BrowserProcessId=$BrowserProcessId Profile=$ProfileDir"
        }

        foreach ($chromeProcess in $chromeProcesses) {
            try {
                Stop-Process -Id $chromeProcess.ProcessId -Force -ErrorAction Stop
                Write-Log "[OK] Stopped dedicated Chrome process: $($chromeProcess.ProcessId)"
            } catch {
                Write-Log "[WARN] Failed to stop Chrome process $($chromeProcess.ProcessId): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Log "[WARN] Failed to enumerate dedicated Chrome processes: $($_.Exception.Message)"
    }

    try {
        if (Test-Path -LiteralPath $ProfileDir) {
            Remove-Item -LiteralPath $ProfileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "[WARN] Failed to remove temporary Chrome profile: $($_.Exception.Message)"
    }
}

$now = Get-Date
$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
if ($weekday -notcontains $now.DayOfWeek.ToString()) {
    Write-Log "[SKIP] Today is not a weekday: $($now.DayOfWeek)"
    exit 0
}

$holidayReason = Get-HolidayReason -Date $now.Date
if ($holidayReason) {
    Write-Log "[SKIP] Today is configured holiday: $($now.ToString('yyyy-MM-dd')) $holidayReason"
    exit 0
}

Write-Log "=============================================="
Write-Log "YouTube live refresh started"
Write-Log "Url: $Url"
Write-Log "CloseWhenLiveEnds: $CloseWhenLiveEnds"
Write-Log "PlaybackVolumePercent: $PlaybackVolumePercent"
Write-Log "DisableYouTubeAutoplay: $DisableYouTubeAutoplay"
Write-Log "MaxWatchReadFailures: $MaxWatchReadFailures"
Write-Log "UseExistingChromeProfile: $UseExistingChromeProfile"
Write-Log "ExistingProfileOpenOnly: $ExistingProfileOpenOnly"
Write-Log "ChromeProfileDirectory: $ChromeProfileDirectory"
Write-Log "=============================================="

if (!(Test-Path -LiteralPath $chromePath)) {
    Write-Log "[ERROR] Chrome not found: $chromePath"
    exit 1
}

if ($UseExistingChromeProfile -and $ExistingProfileOpenOnly) {
    try {
        $viewerArgs = @(
            "--new-window",
            "--start-maximized",
            "--profile-directory=$ChromeProfileDirectory",
            "--autoplay-policy=no-user-gesture-required",
            $Url
        )

        $viewerLaunchProcess = Start-Process -FilePath $chromePath -ArgumentList $viewerArgs -PassThru
        Write-Log "[OK] Viewer Chrome opened with existing profile only. ProfileDirectory=$ChromeProfileDirectory LauncherProcessId=$([int]$viewerLaunchProcess.Id)"
        Write-Log "YouTube live refresh completed. ExistingProfileOpenOnly=True"
        exit 0
    } catch {
        Write-Log "[ERROR] Failed to open existing-profile Chrome: $($_.Exception.Message)"
        exit 1
    }
}

$launchedChromeProcessId = 0
$targetWindowHandles = @()
$closeTitlePattern = ""

if ($Url -match "moneymoneycomics|moneycomics") {
    $closeTitlePattern = "머니|MoneyComics|moneymoneycomics"
} elseif ($Url -match "UCWskYkV4c4S9D__rsfOl2JA|hankyung") {
    $closeTitlePattern = "한경|Hankyung|Global Market|글로벌마켓"
} elseif ($Url -match "유사남|%EC%9C%A0%EC%82%AC%EB%82%A8|yusanam") {
    $closeTitlePattern = "유사남|Yusanam"
}

$baselineWindowHandles = @{}
foreach ($window in @(Get-YouTubeLiveChromeWindows)) {
    $baselineWindowHandles[[string]$window.HandleValue] = $true
}

if ($RemoteDebuggingPort -le 0) {
    $RemoteDebuggingPort = Get-FreeTcpPort
}

$extensionLoadPaths = @()
if ($UseExistingChromeProfile) {
    Write-Log "[OK] Existing Chrome profile will provide login state and installed extensions"
} else {
    $extensionLoadPaths = @(Resolve-ChromeExtensionPaths -ExplicitPaths $ExtensionPaths -NamePattern $ExtensionNamePattern)
    if ($extensionLoadPaths.Count -gt 0) {
        Write-Log "[OK] Chrome extension will be loaded: $($extensionLoadPaths -join ', ')"
    } else {
        Write-Log "[WARN] Matching Chrome extension was not found. Pattern=$ExtensionNamePattern"
    }
}

try {
    if ($UseExistingChromeProfile) {
        $viewerArgs = @(
            "--new-window",
            "--profile-directory=$ChromeProfileDirectory",
            "--autoplay-policy=no-user-gesture-required",
            $Url
        )

        $viewerLaunchProcess = Start-Process -FilePath $chromePath -ArgumentList $viewerArgs -PassThru
        Write-Log "[OK] Viewer Chrome opened with existing profile. ProfileDirectory=$ChromeProfileDirectory LauncherProcessId=$([int]$viewerLaunchProcess.Id)"

        New-Item -ItemType Directory -Path $chromeProfileDir -Force | Out-Null
        $chromeArgs = @(
            "--headless=new",
            "--mute-audio",
            "--no-first-run",
            "--disable-gpu",
            "--disable-default-apps",
            "--autoplay-policy=no-user-gesture-required",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=$RemoteDebuggingPort",
            "--user-data-dir=$chromeProfileDir",
            "about:blank"
        )

        $launchedChromeProcess = Start-Process -FilePath $chromePath -ArgumentList $chromeArgs -PassThru
        $launchedChromeProcessId = [int]$launchedChromeProcess.Id
        Write-Log "[OK] Headless monitor Chrome opened. Port=$RemoteDebuggingPort Profile=$chromeProfileDir ProcessId=$launchedChromeProcessId"
    } else {
        New-Item -ItemType Directory -Path $chromeProfileDir -Force | Out-Null
        $chromeArgs = @(
            "--new-window",
            "--no-first-run",
            "--disable-infobars",
            "--disable-default-apps",
            "--autoplay-policy=no-user-gesture-required",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=$RemoteDebuggingPort",
            "--user-data-dir=$chromeProfileDir"
        )

        if ($extensionLoadPaths.Count -gt 0) {
            $extensionArg = $extensionLoadPaths -join ","
            $quotedExtensionArg = Quote-ChromeArgumentValue -Value $extensionArg
            $chromeArgs += "--disable-extensions-except=$quotedExtensionArg"
            $chromeArgs += "--load-extension=$quotedExtensionArg"
        }

        $chromeArgs += "about:blank"

        $launchedChromeProcess = Start-Process -FilePath $chromePath -ArgumentList $chromeArgs -PassThru
        $launchedChromeProcessId = [int]$launchedChromeProcess.Id
        Write-Log "[OK] Dedicated Chrome opened. Port=$RemoteDebuggingPort Profile=$chromeProfileDir ProcessId=$launchedChromeProcessId"
    }
} catch {
    Write-Log "[ERROR] Failed to open Chrome: $($_.Exception.Message)"
    exit 1
}

$windowDetectionDeadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $windowDetectionDeadline -and @($targetWindowHandles).Count -eq 0) {
    $newWindows = @(
        Get-YouTubeLiveChromeWindows |
            Where-Object { !$baselineWindowHandles.ContainsKey([string]$_.HandleValue) }
    )

    if ($newWindows.Count -gt 0) {
        $targetWindowHandles = @($newWindows | ForEach-Object { [long]$_.HandleValue })
        Write-Log "[OK] Tracked Chrome window(s): $(Get-WindowSummary -Windows $newWindows)"
        break
    }

    Start-Sleep -Milliseconds 500
}

if (@($targetWindowHandles).Count -eq 0) {
    Write-Log "[WARN] Could not identify newly opened Chrome window; close fallback will use process/profile and title matching when safe"
}

$pageTarget = Wait-ForCdpPageTarget -Port $RemoteDebuggingPort -TimeoutSeconds 25
if (!$pageTarget) {
    Write-Log "[ERROR] Chrome page target was not available"
    $targetFallbackPattern = $closeTitlePattern
    $closeWindowHandles = $targetWindowHandles
    if ($UseExistingChromeProfile) {
        $targetFallbackPattern = ""
        $closeWindowHandles = @()
    }
    Close-LiveChrome -Port $RemoteDebuggingPort -ProfileDir $chromeProfileDir -BrowserProcessId $launchedChromeProcessId -WindowHandles $closeWindowHandles -TitlePattern $targetFallbackPattern
    exit 1
}

try {
    Install-YouTubeVolumeLimiter -Port $RemoteDebuggingPort -VolumePercent $PlaybackVolumePercent
    Write-Log "[OK] Early playback volume limiter installed at $PlaybackVolumePercent%"
} catch {
    Write-Log "[WARN] Failed to install early playback volume limiter: $($_.Exception.Message)"
}

if ($DisableYouTubeAutoplay) {
    try {
        $autoplayState = Install-YouTubeAutoplayBlocker -Port $RemoteDebuggingPort
        if ($autoplayState) {
            Write-Log "[OK] YouTube autoplay blocker installed. ToggleFound=$($autoplayState.toggleFound) Toggled=$($autoplayState.toggled) Disabled=$($autoplayState.disabled)"
        } else {
            Write-Log "[OK] YouTube autoplay blocker installed"
        }
    } catch {
        Write-Log "[WARN] Failed to install YouTube autoplay blocker: $($_.Exception.Message)"
    }
}

try {
    Invoke-PageCommand -Port $RemoteDebuggingPort -Method "Page.navigate" -Params @{ url = $Url } | Out-Null
    Write-Log "[OK] Navigated Chrome page to URL after volume limiter install"
} catch {
    Write-Log "[ERROR] Failed to navigate Chrome page to URL: $($_.Exception.Message)"
    $targetFallbackPattern = $closeTitlePattern
    $closeWindowHandles = $targetWindowHandles
    if ($UseExistingChromeProfile) {
        $targetFallbackPattern = ""
        $closeWindowHandles = @()
    }
    Close-LiveChrome -Port $RemoteDebuggingPort -ProfileDir $chromeProfileDir -BrowserProcessId $launchedChromeProcessId -WindowHandles $closeWindowHandles -TitlePattern $targetFallbackPattern
    exit 1
}

for ($i = 0; $i -lt $InitialDelaySeconds; $i += 2) {
    Start-Sleep -Seconds ([Math]::Min(2, $InitialDelaySeconds - $i))
    try {
        Set-YouTubePlaybackVolume -Port $RemoteDebuggingPort -VolumePercent $PlaybackVolumePercent | Out-Null
    } catch {
    }
}

try {
    $volumeState = Set-YouTubePlaybackVolume -Port $RemoteDebuggingPort -VolumePercent $PlaybackVolumePercent
    if ($volumeState -and $volumeState.ok) {
        Write-Log "[OK] Playback volume set to $PlaybackVolumePercent%"
    } else {
        Write-Log "[WARN] Playback volume preference saved, but video element was not available yet"
    }
} catch {
    Write-Log "[WARN] Failed to set initial playback volume: $($_.Exception.Message)"
}

$refreshDeadline = (Get-Date).AddMinutes($DurationMinutes)
$watchDeadline = (Get-Date).AddMinutes($MaxWatchMinutes)
$refreshCount = 0
$seenLive = $false
$notLiveChecks = 0
$watchReadFailures = 0
$closedReason = ""

while ((Get-Date) -lt $refreshDeadline) {
    try {
        Invoke-PageCommand -Port $RemoteDebuggingPort -Method "Page.reload" -Params @{ ignoreCache = $true } | Out-Null
        $refreshCount++
        Write-Log "[OK] Sent CDP reload #$refreshCount"
    } catch {
        Write-Log "[WARN] Failed to reload page: $($_.Exception.Message)"
    }

    try {
        Start-Sleep -Seconds 5
        Set-YouTubePlaybackVolume -Port $RemoteDebuggingPort -VolumePercent $PlaybackVolumePercent | Out-Null
        $state = Get-YouTubeLiveState -Port $RemoteDebuggingPort
        if ($state) {
            Write-Log ("Live state after refresh: isLive={0} isEnded={1} title='{2}'" -f $state.isLive, $state.isEnded, $state.title)
            if ($state.isLive) {
                $seenLive = $true
            }
        }
    } catch {
        Write-Log "[WARN] Failed to read live state after refresh: $($_.Exception.Message)"
    }

    $sleepSeconds = [Math]::Max(1, $RefreshEverySeconds - 5)
    Start-Sleep -Seconds $sleepSeconds
}

if ($CloseWhenLiveEnds) {
    Write-Log "Watching for live end. MaxWatchMinutes=$MaxWatchMinutes WatchEverySeconds=$WatchEverySeconds MaxWatchReadFailures=$MaxWatchReadFailures"

    while ((Get-Date) -lt $watchDeadline) {
        try {
            Set-YouTubePlaybackVolume -Port $RemoteDebuggingPort -VolumePercent $PlaybackVolumePercent | Out-Null
            $state = Get-YouTubeLiveState -Port $RemoteDebuggingPort
            if ($state) {
                $watchReadFailures = 0
                Write-Log ("Live watch state: seenLive={0} isLive={1} isEnded={2} title='{3}'" -f $seenLive, $state.isLive, $state.isEnded, $state.title)
                if ($state.isLive) {
                    $seenLive = $true
                    $notLiveChecks = 0
                } elseif ($state.isEnded) {
                    $notLiveChecks++
                } elseif ($seenLive) {
                    $notLiveChecks++
                } else {
                    $notLiveChecks = 0
                }

                if ($notLiveChecks -ge $EndedConfirmChecks) {
                    $closedReason = "live ended"
                    break
                }
            }
        } catch {
            $watchReadFailures++
            Write-Log "[WARN] Failed to read live watch state: $($_.Exception.Message)"
            if ($watchReadFailures -ge $MaxWatchReadFailures) {
                $closedReason = "watch state unavailable"
                Write-Log "[WARN] Live watch state failed $watchReadFailures consecutive times; closing dedicated Chrome"
                break
            }
        }

        Start-Sleep -Seconds $WatchEverySeconds
    }

    if ([string]::IsNullOrWhiteSpace($closedReason)) {
        $closedReason = "watch timeout"
    }

    Write-Log "Closing dedicated Chrome. Reason=$closedReason RefreshCount=$refreshCount"
    $targetFallbackPattern = $closeTitlePattern
    $closeWindowHandles = $targetWindowHandles
    if ($UseExistingChromeProfile) {
        $targetFallbackPattern = ""
        $closeWindowHandles = @()
        Write-Log "[INFO] Existing Chrome profile mode: leaving visible Chrome window open"
    }
    Close-LiveChrome -Port $RemoteDebuggingPort -ProfileDir $chromeProfileDir -BrowserProcessId $launchedChromeProcessId -WindowHandles $closeWindowHandles -TitlePattern $targetFallbackPattern
} else {
    Write-Log "YouTube live refresh completed without auto-close. RefreshCount=$refreshCount"
}

Write-Log "YouTube live refresh completed. RefreshCount=$refreshCount ClosedReason=$closedReason"
