param(
    [string]$Url = "https://extra.lms.example.com/",
    [string]$CredentialPath = "",
    [switch]$SetupCredential,
    [int]$RemoteDebuggingPort = 9222,
    [int]$TimeoutSeconds = 45,
    [int]$DedupeWindowMinutes = 5,
    [switch]$UseIsolatedProfile,
    [string]$ProfileDirectory = "Default",
    [switch]$DisableUiFallback,
    [switch]$IgnoreHoliday,
    [int]$CdpTimeoutSeconds = 15
)

# 2026-10-17 QA 반영 (로그인 정보 오입력 방지):
#  - 허용 도메인(https + extra.lms.example.com)인 탭/창에만 ID·비밀번호 입력. 확인 못 하면 입력 중단.
#    · CDP: Lms 가 아닌 페이지는 대상에서 제외, 입력 직전 페이지 안에서도 location 재확인
#    · UI fallback: 창 제목 + Chrome 주소창 도메인이 모두 맞는 창만 사용, ID/비밀번호 입력 직전마다 재확인
#    · "새로 열린 아무 Chrome 창" 선택 로직 제거
#  - CDP WebSocket 연결/송수신에 제한 시간(-CdpTimeoutSeconds)
#  - UI 자동화 접근 실패와 "로그인 폼 없음(이미 로그인 추정)"을 구분 — 접근 실패는 exit 1
#  v5 (QA v3): 전역 키 입력(클립보드 붙여넣기) 직전마다 '현재 포그라운드 창 = 대상 Lms 창'을 확인.
#     포커스 전환·좌표 클릭·입력칸 포커스를 확인하지 못하면 입력하지 않고 실패 반환.
#  v6 (QA v5): 붙여넣기 함수 안에서도 Ctrl+A·Ctrl+V 각각 직전에 대상 창(+입력칸) 포커스 재확인.
#     전역 키 입력은 검사 직후 극히 짧은 경쟁 구간이 원리상 남으므로, 값 설정은 ValuePattern(키 입력 없음)을 1순위로 유지.
$allowedHosts = @('extra.lms.example.com')
$lmsTitlePattern = "ExtraNet|Lms|lms|extra\.lms"
$addressBarNamePattern = "Address and search bar|주소창|주소 및 검색"

$ErrorActionPreference = "Continue"

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$logDir = Join-Path $env:LOCALAPPDATA "CodexAutomation"
$logFile = Join-Path $logDir "open_lms_prefill.log"
$recentOpenFile = Join-Path $logDir "open_lms_prefill.last_open.json"
$runId = "{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $PID
$chromeProfileDir = Join-Path $logDir "chrome-lms-prefill-$runId"

if ([string]::IsNullOrWhiteSpace($CredentialPath)) {
    $CredentialPath = Join-Path $logDir "lms_login_credential.xml"
}

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

try {
    Get-ChildItem -LiteralPath $logDir -Directory -Filter "chrome-lms-prefill-*" -ErrorAction SilentlyContinue |
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

# https + 허용 호스트인지
function Test-AllowedUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $u = [Uri]$Url
        return ($u.IsAbsoluteUri -and $u.Scheme -eq 'https' -and ($allowedHosts -contains $u.Host.ToLowerInvariant()))
    } catch {
        return $false
    }
}

# Chrome 주소창 텍스트(스킴 생략 가능)가 허용 호스트인지. 명시적 http:// 는 거부.
function Test-AllowedAddressText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.Trim()
    if ($t -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        return (Test-AllowedUrl -Url $t)
    }
    return (Test-AllowedUrl -Url ("https://" + $t))
}

# Shared holiday/vacation list used by the C:\Scripts hiworks automation.
$holidayFile = "C:\Scripts\hiworks_holidays.txt"

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

function Test-RecentOpen {
    param(
        [string]$Path,
        [int]$WindowMinutes
    )

    if ($WindowMinutes -le 0 -or !(Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if (!$state.openedAt) {
            return $false
        }

        $openedAt = [DateTimeOffset]::Parse([string]$state.openedAt)
        $elapsed = [DateTimeOffset]::Now - $openedAt
        if ($elapsed.TotalMinutes -lt $WindowMinutes) {
            Write-Log "[INFO] Recent Lms open detected $([math]::Round($elapsed.TotalSeconds, 1)) seconds ago; skipping duplicate launch"
            return $true
        }
    } catch {
        Write-Log "[WARN] Failed to read recent-open state: $($_.Exception.Message)"
    }

    return $false
}

function Write-RecentOpen {
    param(
        [string]$Path,
        [string]$Url
    )

    try {
        @{
            openedAt = [DateTimeOffset]::Now.ToString("o")
            url = $Url
            processId = $PID
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Write-Log "[WARN] Failed to write recent-open state: $($_.Exception.Message)"
    }
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

function Get-CdpTargets {
    param([int]$Port)

    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3
}

function Get-CdpPageTarget {
    param([int]$Port)

    $targets = Get-CdpTargets -Port $Port
    # 허용 도메인 페이지만 대상. 없으면 $null (다른 페이지로 대체하지 않음)
    @($targets) |
        Where-Object { $_.type -eq "page" -and (Test-AllowedUrl -Url ([string]$_.url)) } |
        Sort-Object id |
        Select-Object -First 1
}

function Wait-ForCdpPageTarget {
    param(
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $target = Get-CdpPageTarget -Port $Port
            if ($target) {
                return $target
            }
        } catch {
            Start-Sleep -Milliseconds 500
        }

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Test-CdpAvailable {
    param([int]$Port)

    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-PageCommand {
    param(
        [int]$Port,
        [string]$Method,
        [object]$Params = $null
    )

    $target = Get-CdpPageTarget -Port $Port
    if (!$target -or [string]::IsNullOrWhiteSpace($target.webSocketDebuggerUrl)) {
        throw "Allowed Lms page target not found"
    }
    if (!(Test-AllowedUrl -Url ([string]$target.url))) {
        throw "Page target is not on an allowed host: $($target.url)"
    }

    $webSocket = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($CdpTimeoutSeconds))
    try {
        $uri = [Uri]$target.webSocketDebuggerUrl
        $webSocket.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult()

        $payload = @{
            id = 1
            method = $Method
        }
        if ($null -ne $Params) {
            $payload.params = $Params
        }

        $json = $payload | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $segment = [ArraySegment[byte]]::new($bytes)
        $webSocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

        $buffer = New-Object byte[] 65536
        $responseText = ""
        do {
            $responseSegment = [ArraySegment[byte]]::new($buffer)
            $result = $webSocket.ReceiveAsync($responseSegment, $cts.Token).GetAwaiter().GetResult()
            if ($result.Count -gt 0) {
                $responseText += [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            }
        } until ($result.EndOfMessage)

        return $responseText | ConvertFrom-Json
    } finally {
        try {
            if ($webSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $closeCts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3))
                try {
                    $webSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $closeCts.Token).GetAwaiter().GetResult()
                } finally {
                    $closeCts.Dispose()
                }
            }
        } catch {
            # 닫기 실패는 무시 (이미 결과를 받았거나 시간 초과)
        }
        $webSocket.Dispose()
        $cts.Dispose()
    }
}

function ConvertTo-PlainText {
    param([Security.SecureString]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Protect-JavaScriptString {
    param([string]$Value)

    ($Value | ConvertTo-Json -Compress)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class LmsWindowInfo {
    public IntPtr Handle { get; set; }
    public long HandleValue { get { return Handle.ToInt64(); } }
    public int ProcessId { get; set; }
    public string Title { get; set; }
}

public struct LmsWindowRect {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class LmsWindowTools {
    private const int SW_RESTORE = 9;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;

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
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    public static long GetForegroundHandle() {
        return GetForegroundWindow().ToInt64();
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out LmsWindowRect lpRect);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    public static LmsWindowInfo[] GetWindows() {
        var windows = new List<LmsWindowInfo>();
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

            windows.Add(new LmsWindowInfo {
                Handle = hWnd,
                ProcessId = (int)processId,
                Title = title.ToString()
            });

            return true;
        }, IntPtr.Zero);

        return windows.ToArray();
    }

    public static bool FocusWindow(long handleValue) {
        var handle = new IntPtr(handleValue);
        ShowWindow(handle, SW_RESTORE);
        return SetForegroundWindow(handle);
    }

    public static LmsWindowRect GetRect(long handleValue) {
        LmsWindowRect rect;
        GetWindowRect(new IntPtr(handleValue), out rect);
        return rect;
    }

    public static bool TryClickWindowRatio(long handleValue, double xRatio, double yRatio) {
        var handle = new IntPtr(handleValue);
        ShowWindow(handle, SW_RESTORE);
        SetForegroundWindow(handle);

        LmsWindowRect rect;
        if (!GetWindowRect(handle, out rect)) {
            return false;
        }

        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) {
            return false;
        }

        int x = rect.Left + (int)Math.Round(width * xRatio);
        int y = rect.Top + (int)Math.Round(height * yRatio);
        if (!SetCursorPos(x, y)) {
            return false;
        }

        System.Threading.Thread.Sleep(150);
        mouse_event(MOUSEEVENTF_LEFTDOWN, (uint)x, (uint)y, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(MOUSEEVENTF_LEFTUP, (uint)x, (uint)y, 0, UIntPtr.Zero);
        return true;
    }
}
"@

function Get-ChromeWindows {
    [LmsWindowTools]::GetWindows() | Where-Object {
        try {
            $process = Get-Process -Id $_.ProcessId -ErrorAction Stop
            $process.ProcessName -eq "chrome"
        } catch {
            $false
        }
    }
}

function Set-TextViaClipboard {
    param(
        [string]$Text,
        [long]$WindowHandle,
        [System.Windows.Automation.AutomationElement]$Element = $null
    )

    # 키 입력 직전마다 호출: 대상 창이 포그라운드이고, 입력칸이 주어졌으면 그 칸에 키보드 포커스가 있어야 함
    $assertTarget = {
        param([string]$Step)
        if ([LmsWindowTools]::GetForegroundHandle() -ne $WindowHandle) {
            throw "Foreground changed before $Step; refusing keyboard input"
        }
        if ($Element -and -not $Element.Current.HasKeyboardFocus) {
            throw "Target input lost keyboard focus before $Step; refusing keyboard input"
        }
    }

    $hadClipboard = $false
    $previousClipboard = ""
    try {
        $previousClipboard = Get-Clipboard -Raw -ErrorAction Stop
        $hadClipboard = $true
    } catch {
    }

    try {
        & $assertTarget 'clipboard set'
        Set-Clipboard -Value $Text
        Start-Sleep -Milliseconds 150
        & $assertTarget 'Ctrl+A'
        [System.Windows.Forms.SendKeys]::SendWait("^a")
        Start-Sleep -Milliseconds 100
        & $assertTarget 'Ctrl+V'
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 200
    } finally {
        try {
            if ($hadClipboard) {
                Set-Clipboard -Value $previousClipboard
            } else {
                Set-Clipboard -Value ""
            }
        } catch {
        }
    }
}

function Test-ForegroundIs {
    param([long]$HandleValue)
    return ([LmsWindowTools]::GetForegroundHandle() -eq $HandleValue)
}

function Set-AutomationElementText {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string]$Text,
        [long]$WindowHandle
    )

    # 1순위: ValuePattern — 키 입력 없이 해당 요소에 직접 값 설정
    try {
        $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($valuePattern) {
            $valuePattern.SetValue($Text)
            return $true
        }
    } catch {
    }

    # 2순위: 포커스 + 클립보드 붙여넣기(전역 키 입력) — 대상 창·입력칸 포커스가 확인될 때만
    try {
        $Element.SetFocus()
        Start-Sleep -Milliseconds 150
        if (!(Test-ForegroundIs -HandleValue $WindowHandle)) {
            Write-Log "[ERROR] Foreground window is not the Lms window; refusing keyboard input"
            return $false
        }
        if (!$Element.Current.HasKeyboardFocus) {
            Write-Log "[ERROR] Target input does not have keyboard focus; refusing keyboard input"
            return $false
        }
        Set-TextViaClipboard -Text $Text -WindowHandle $WindowHandle -Element $Element
        return $true
    } catch {
        Write-Log "[ERROR] Keyboard input aborted: $($_.Exception.Message)"
        return $false
    }
}

function Get-ChromeAddressBarText {
    param([long]$HandleValue)

    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$HandleValue)
    $editCondition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
    $rect = [LmsWindowTools]::GetRect($HandleValue)

    $named = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
    $toolbar = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
    foreach ($e in $edits) {
        try {
            $name = [string]$e.Current.Name
            $b = $e.Current.BoundingRectangle
            if ($name -match $addressBarNamePattern) {
                $named.Add($e)
            } elseif ($b.Top -lt ($rect.Top + 90) -and $b.Width -ge 200) {
                $toolbar.Add($e)
            }
        } catch {
        }
    }

    foreach ($c in @($named) + @($toolbar)) {
        try {
            $vp = $c.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $v = [string]$vp.Current.Value
            if (![string]::IsNullOrWhiteSpace($v)) {
                return $v
            }
        } catch {
        }
    }
    return $null
}

$script:hostMismatchLogged = @{}
function Test-WindowOnAllowedHost {
    param([long]$HandleValue)

    $text = $null
    try {
        $text = Get-ChromeAddressBarText -HandleValue $HandleValue
    } catch {
        $text = $null
    }

    if (Test-AllowedAddressText -Text $text) {
        return $true
    }

    $key = "$HandleValue|$text"
    if (!$script:hostMismatchLogged.ContainsKey($key)) {
        $script:hostMismatchLogged[$key] = $true
        $shown = if ($text) { $text } else { "(address bar unreadable)" }
        Write-Log "[INFO] Chrome window $HandleValue is not on an allowed host: $shown"
    }
    return $false
}

function Get-LmsChromeWindowForUiFallback {
    param(
        [hashtable]$BaselineHandles,
        [int]$TimeoutSeconds
    )

    # 제목이 Lms 이고 주소창 도메인이 허용 호스트인 창만. 새 창 우선, 그다음 기존 창.
    # (제목이 안 맞는 '새로 열린 아무 창'은 고르지 않는다)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $titled = @(Get-ChromeWindows | Where-Object { $_.Title -match $lmsTitlePattern })
        $ordered = @($titled | Where-Object { !$BaselineHandles.ContainsKey([string]$_.HandleValue) }) +
                   @($titled | Where-Object { $BaselineHandles.ContainsKey([string]$_.HandleValue) })
        foreach ($w in $ordered) {
            if (Test-WindowOnAllowedHost -HandleValue ([long]$w.HandleValue)) {
                return $w
            }
        }

        Start-Sleep -Milliseconds 500
    }

    return $null
}

function Invoke-LmsUiPrefill {
    param(
        [string]$UserId,
        [string]$Password,
        [hashtable]$BaselineHandles,
        [int]$TimeoutSeconds
    )

    $window = Get-LmsChromeWindowForUiFallback -BaselineHandles $BaselineHandles -TimeoutSeconds $TimeoutSeconds
    if (!$window) {
        Write-Log "[ERROR] UI fallback could not find a Lms Chrome window on an allowed host; not typing credentials"
        return $false
    }

    $hwnd = [long]$window.HandleValue
    Write-Log "[INFO] UI fallback targeting Chrome window: $($window.Title)"
    [LmsWindowTools]::FocusWindow($hwnd) | Out-Null
    Start-Sleep -Seconds 2

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawPasswordField = $false
    $readWindowOk = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
            $editCondition = New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            )
            $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
            $rect = [LmsWindowTools]::GetRect($hwnd)
            $readWindowOk = $true
            $visibleEdits = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]

            foreach ($edit in $edits) {
                try {
                    $bounds = $edit.Current.BoundingRectangle
                    if ($bounds.Width -lt 80 -or $bounds.Height -lt 15) {
                        continue
                    }
                    if ($bounds.Top -lt ($rect.Top + 90)) {
                        continue
                    }
                    if ($edit.Current.IsOffscreen) {
                        continue
                    }
                    $visibleEdits.Add($edit)
                } catch {
                }
            }

            $idInput = $null
            $passwordInput = $null
            foreach ($edit in $visibleEdits) {
                $name = [string]$edit.Current.Name
                $automationId = [string]$edit.Current.AutomationId
                if ($edit.Current.IsPassword -or $name -match "password|Password|pass|Pass" -or $automationId -match "password|Password|pass|Pass|txtPassword") {
                    $passwordInput = $edit
                    $sawPasswordField = $true
                    break
                }
            }

            foreach ($edit in $visibleEdits) {
                if ($edit -eq $passwordInput) {
                    continue
                }

                $name = [string]$edit.Current.Name
                $automationId = [string]$edit.Current.AutomationId
                if ($name -match "ID|id|user|User|login|Login" -or $automationId -match "id|ID|user|User|login|Login|txtId") {
                    $idInput = $edit
                    break
                }
            }

            if (!$idInput -and $visibleEdits.Count -ge 2) {
                $idInput = $visibleEdits[0]
                if (!$passwordInput) {
                    $passwordInput = $visibleEdits[1]
                }
            }

            if ($idInput -and $passwordInput) {
                if (!(Test-WindowOnAllowedHost -HandleValue $hwnd)) {
                    Write-Log "[ERROR] Window left the allowed host before ID input; aborting without typing"
                    return $false
                }
                if (!(Set-AutomationElementText -Element $idInput -Text $UserId -WindowHandle $hwnd)) {
                    throw "ID field set failed"
                }
                Start-Sleep -Milliseconds 200
                if (!(Test-WindowOnAllowedHost -HandleValue $hwnd)) {
                    Write-Log "[ERROR] Window left the allowed host before password input; aborting without typing password"
                    return $false
                }
                if (!(Set-AutomationElementText -Element $passwordInput -Text $Password -WindowHandle $hwnd)) {
                    throw "password field set failed"
                }
                Write-Log "[OK] Lms login fields prefilled through UI automation. IdLength=$($UserId.Length) PasswordLength=$($Password.Length)"
                return $true
            }
        } catch {
            Write-Log "[WARN] UI automation prefill attempt failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds 1
    }

    if (!$readWindowOk) {
        Write-Log "[ERROR] UI automation could not read the Lms window at all; login state unknown"
        return $false
    }

    if (!$sawPasswordField) {
        Write-Log "[OK] No login form found on the allowed Lms page; assuming already logged in (login state NOT verified)"
        return $true
    }

    try {
        if (!(Test-WindowOnAllowedHost -HandleValue $hwnd)) {
            Write-Log "[ERROR] Window is not on the allowed host; skipping coordinate fallback"
            return $false
        }
        $focused = [LmsWindowTools]::FocusWindow($hwnd)
        Start-Sleep -Milliseconds 300
        if (!(Test-ForegroundIs -HandleValue $hwnd)) {
            Write-Log "[ERROR] Coordinate fallback: could not bring the Lms window to the foreground (FocusWindow=$focused); not typing"
            return $false
        }
        if (!([LmsWindowTools]::TryClickWindowRatio($hwnd, 0.53, 0.405))) {
            Write-Log "[ERROR] Coordinate fallback: ID field click failed; not typing"
            return $false
        }
        Start-Sleep -Milliseconds 150
        if (!(Test-ForegroundIs -HandleValue $hwnd)) {
            Write-Log "[ERROR] Coordinate fallback: foreground changed before ID input; not typing"
            return $false
        }
        Set-TextViaClipboard -Text $UserId -WindowHandle $hwnd
        Start-Sleep -Milliseconds 300
        if (!(Test-WindowOnAllowedHost -HandleValue $hwnd)) {
            Write-Log "[ERROR] Window left the allowed host before coordinate password input; aborting"
            return $false
        }
        if (!([LmsWindowTools]::TryClickWindowRatio($hwnd, 0.53, 0.505))) {
            Write-Log "[ERROR] Coordinate fallback: password field click failed; not typing password"
            return $false
        }
        Start-Sleep -Milliseconds 150
        if (!(Test-ForegroundIs -HandleValue $hwnd)) {
            Write-Log "[ERROR] Coordinate fallback: foreground changed before password input; not typing password"
            return $false
        }
        Set-TextViaClipboard -Text $Password -WindowHandle $hwnd
        Write-Log "[OK] Lms login fields prefilled through coordinate fallback. IdLength=$($UserId.Length) PasswordLength=$($Password.Length)"
        return $true
    } catch {
        Write-Log "[ERROR] Coordinate fallback failed: $($_.Exception.Message)"
    }

    return $false
}

Write-Log "=============================================="
Write-Log "Lms prefill started"
Write-Log "Url: $Url"
Write-Log "CredentialPath: $CredentialPath"
Write-Log "=============================================="

if ($SetupCredential) {
    try {
        $credential = Get-Credential -Message "Enter the Lms ExtraNet ID and password. They will only be used for automatic prefill."
        if ($credential) {
            $credential | Export-Clixml -LiteralPath $CredentialPath
            Write-Log "[OK] Credential saved"
            exit 0
        }

        Write-Log "[ERROR] Credential setup was cancelled"
        exit 1
    } catch {
        Write-Log "[ERROR] Failed to save credential: $($_.Exception.Message)"
        exit 1
    }
}

if (!(Test-AllowedUrl -Url $Url)) {
    Write-Log "[ERROR] -Url is not an allowed https Lms address: $Url (allowed hosts: $($allowedHosts -join ', '))"
    exit 1
}

# Do not open ExtraNet on configured holidays / vacation days.
if (-not $IgnoreHoliday) {
    $today = (Get-Date).Date
    $holidayReason = Get-HolidayReason -Date $today
    if ($holidayReason) {
        Write-Log "[SKIP] Today is a configured holiday: $($today.ToString('yyyy-MM-dd')) $holidayReason"
        exit 0
    }
}

if (!(Test-Path -LiteralPath $CredentialPath)) {
    Write-Log "[ERROR] Credential file not found. Run this script with -SetupCredential first."
    exit 1
}

try {
    $credential = Import-Clixml -LiteralPath $CredentialPath
    $userId = $credential.UserName
    $password = ConvertTo-PlainText -SecureString $credential.Password
} catch {
    Write-Log "[ERROR] Failed to load credential: $($_.Exception.Message)"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($password)) {
    Write-Log "[ERROR] Credential is empty"
    exit 1
}

$dedupeMutex = $null
$dedupeMutexAcquired = $false
try {
    $dedupeMutex = [System.Threading.Mutex]::new($false, "Local\CodexAutomationOpenLmsPrefill")
    $dedupeMutexAcquired = $dedupeMutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (!$dedupeMutexAcquired) {
        Write-Log "[INFO] Another Lms launch is already in progress; skipping duplicate launch"
        exit 0
    }
} catch {
    Write-Log "[WARN] Failed to enter duplicate-launch guard: $($_.Exception.Message)"
}

if (Test-RecentOpen -Path $recentOpenFile -WindowMinutes $DedupeWindowMinutes) {
    exit 0
}

if (!(Test-Path -LiteralPath $chromePath)) {
    Write-Log "[ERROR] Chrome not found: $chromePath"
    exit 1
}

if ($RemoteDebuggingPort -le 0) {
    $RemoteDebuggingPort = Get-FreeTcpPort
}

$baselineWindowHandles = @{}
foreach ($window in @(Get-ChromeWindows)) {
    $baselineWindowHandles[[string]$window.HandleValue] = $true
}

$chromeAlreadyRunning = $false
if (!$UseIsolatedProfile) {
    $chromeAlreadyRunning = [bool](Get-Process -Name "chrome" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

$canPrefill = $true
$useUiFallback = $false
try {
    if ($UseIsolatedProfile) {
        New-Item -ItemType Directory -Path $chromeProfileDir -Force | Out-Null
        $chromeArgs = @(
            "--new-window",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--remote-debugging-port=$RemoteDebuggingPort",
            "--user-data-dir=$chromeProfileDir",
            $Url
        )
        Write-Log "[INFO] Opening isolated Chrome profile for guaranteed prefill"
    } elseif ($chromeAlreadyRunning) {
        $canPrefill = Test-CdpAvailable -Port $RemoteDebuggingPort
        if ($canPrefill) {
            $chromeArgs = @(
                "--new-window",
                "--profile-directory=$ProfileDirectory",
                $Url
            )
            Write-Log "[INFO] Opening existing Chrome profile with extensions/cookies; remote debugging port is available for prefill"
        } else {
            $canPrefill = $false
            $useUiFallback = !$DisableUiFallback
            $chromeArgs = @(
                "--new-window",
                "--profile-directory=$ProfileDirectory",
                $Url
            )
            if ($useUiFallback) {
                Write-Log "[WARN] Existing Chrome cannot be attached on port $RemoteDebuggingPort; opening original Chrome profile and using UI fallback"
            } else {
                Write-Log "[WARN] Existing Chrome cannot be attached on port $RemoteDebuggingPort and UI fallback is disabled"
            }
        }
    } else {
        # 2026-09-29: this branch used --remote-debugging-port on the default profile.
        # Recent Chrome ignores that flag for the default user data dir, and the
        # CDP/websocket calls have no timeout, so the script hung with an empty form.
        # Use the same UI fallback that the daily 12:50 run already uses.
        $canPrefill = $false
        $useUiFallback = !$DisableUiFallback
        $chromeArgs = @(
            "--new-window",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
            "--profile-directory=$ProfileDirectory",
            $Url
        )
        Write-Log "[INFO] Chrome not running; opening default Chrome profile and using UI fallback"
    }

    Start-Process -FilePath $chromePath -ArgumentList $chromeArgs | Out-Null
    Write-RecentOpen -Path $recentOpenFile -Url $Url
    if ($dedupeMutexAcquired) {
        $dedupeMutex.ReleaseMutex()
        $dedupeMutex.Dispose()
        $dedupeMutexAcquired = $false
    }
    if ($UseIsolatedProfile) {
        Write-Log "[OK] Chrome opened. Port=$RemoteDebuggingPort Profile=$chromeProfileDir"
    } elseif ($chromeAlreadyRunning) {
        if ($canPrefill) {
            Write-Log "[OK] Existing Chrome profile opened. Port=$RemoteDebuggingPort Profile=$ProfileDirectory"
        } elseif ($useUiFallback) {
            Write-Log "[OK] Existing Chrome profile opened. UI fallback will prefill login fields"
        } else {
            Write-Log "[ERROR] Prefill unexpectedly unavailable after Chrome launch decision"
        }
    } else {
        Write-Log "[OK] Default Chrome profile opened. UI fallback will prefill login fields"
    }
} catch {
    Write-Log "[ERROR] Failed to open Chrome: $($_.Exception.Message)"
    exit 1
}

if (!$canPrefill) {
    if ($useUiFallback) {
        if (Invoke-LmsUiPrefill -UserId $userId -Password $password -BaselineHandles $baselineWindowHandles -TimeoutSeconds $TimeoutSeconds) {
            exit 0
        }

        exit 1
    }

    exit 0
}

$pageTarget = Wait-ForCdpPageTarget -Port $RemoteDebuggingPort -TimeoutSeconds $TimeoutSeconds
if (!$pageTarget) {
    Write-Log "[ERROR] Chrome page target was not available"
    exit 1
}

$idJson = Protect-JavaScriptString -Value $userId
$passwordJson = Protect-JavaScriptString -Value $password
$allowedHostsJson = ConvertTo-Json -InputObject @($allowedHosts) -Compress
$script = @"
(function () {
  const allowedHosts = $allowedHostsJson;
  if (location.protocol !== 'https:' || allowedHosts.indexOf(location.hostname) < 0) {
    return { ok: false, reason: 'page host not allowed: ' + location.protocol + '//' + location.hostname };
  }
  const userId = $idJson;
  const password = $passwordJson;
  const idInput = document.querySelector('input#txtId, input[name="txtId"], input[type="text"]');
  const passwordInput = document.querySelector('input#txtPassword, input[name="txtPassword"], input[type="password"]');

  function setNativeValue(input, value) {
    const prototype = Object.getPrototypeOf(input);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value') ||
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    descriptor.set.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  if (!idInput || !passwordInput) {
    return { ok: false, reason: 'login inputs not found', title: document.title, url: location.href };
  }

  setNativeValue(idInput, userId);
  setNativeValue(passwordInput, password);
  passwordInput.focus();

  return {
    ok: idInput.value === userId && passwordInput.value === password,
    title: document.title,
    url: location.href,
    idLength: idInput.value.length,
    passwordLength: passwordInput.value.length
  };
})()
"@

try {
    $result = Invoke-PageCommand -Port $RemoteDebuggingPort -Method "Runtime.evaluate" -Params @{
        expression = $script
        returnByValue = $true
        awaitPromise = $true
    }

    $value = $result.result.result.value
    if ($value.ok) {
        Write-Log "[OK] Lms login fields prefilled. IdLength=$($value.idLength) PasswordLength=$($value.passwordLength)"
        exit 0
    }

    Write-Log "[ERROR] Lms login fields were not prefilled: $($value.reason)"
    exit 1
} catch {
    Write-Log "[ERROR] Failed to prefill Lms login fields: $($_.Exception.Message)"
    exit 1
}
