param(
    [switch]$DryRun,
    [string]$SendMessage = "",
    [string]$MessageFile = "",
    [string]$MessageLabel = "start",
    [string]$TargetChatTitle = "동료B2",
    [string]$TargetSearchQuery = "동료B2",
    [string]$TargetSearchResult = "동료B2",
    [string]$ExpectedAccountName = "",   # 검사 비활성 (send_hiworks_self_greeting.ps1 주석 참고)
    [int]$MainX = 120,
    [int]$MainY = 70,
    [int]$MainWidth = 350,
    [int]$MainHeight = 794,
    [int]$ChatX = 500,
    [int]$ChatY = 90,
    [int]$ChatWidth = 420,
    [int]$ChatHeight = 640,
    [int]$MaxOpenChatAttempts = 4,
    [int]$ChatOpenTimeoutMs = 18000,
    [switch]$NoScreenshots
)

$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$safeMessageLabel = $MessageLabel -replace '[^\w-]', '_'
$logFile = Join-Path $logDir ("hiworks_{0}_message_uia.log" -f $safeMessageLabel)
$hiworksPath = "C:\Program Files (x86)\Hiworks\Messenger\HiworksMessenger.exe"
$processName = "HiworksMessenger"
$mainWindowTitle = "하이웍스 메신저"
# 하이웍스를 새로 띄운 직후에는 같은 제목('하이웍스 메신저')·같은 좌표의 임시 창(로그인 단계로 추정)이
# 먼저 떴다가 몇 초 뒤 사라지고 진짜 메인창이 새 핸들로 뜬다. (2026-09-28 드라이런에서 확인)
# 같은 핸들이 이 시간 동안 유지돼야 메인창으로 인정한다.
$mainWindowStableMs = 2000
$mainWindowAcquireSeconds = 75
$script:hiworksStartedByScript = $false
$script:hiworksStartWaited = $false
$chatTitle = $TargetChatTitle
$searchQuery = $TargetSearchQuery
$searchResultQuery = if ([string]::IsNullOrWhiteSpace($TargetSearchResult)) { $TargetSearchQuery } else { $TargetSearchResult }
$defaultMessage = "안녕하세요~`r`n업무 시작합니다!^^"
$message = $defaultMessage

if (![string]::IsNullOrWhiteSpace($MessageFile)) {
    if (!(Test-Path -LiteralPath $MessageFile)) {
        throw "메시지 파일을 찾지 못했습니다: $MessageFile"
    }
    $message = Get-Content -LiteralPath $MessageFile -Raw -Encoding UTF8
} elseif (![string]::IsNullOrEmpty($SendMessage)) {
    $message = $SendMessage
}

$message = $message.TrimEnd("`r", "`n")

if ([string]::IsNullOrWhiteSpace($message)) {
    throw "전송할 메시지가 비어 있습니다."
}

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

# --- send stage marker v2 (added 2026-10-17 by Patch-UiaSendStage.ps1) ---
# Called right before the send action. It is also the final send gate:
#   HIWORKS_SEND_DEADLINE   (ISO 8601): do not send at/after this time
#   HIWORKS_SEND_ABORT_FLAG (file path): do not send if this file exists
# A gate refusal throws BEFORE the stage file is written, so callers see "failed before send".
# The stage file lets callers tell "failed before send" (safe to retry) from "failed after send" (hold).
# If writing the stage file fails, Set-Content throws BEFORE the send action, so nothing is sent unmarked.
$sendStageFile = Join-Path $logDir ("hiworks_{0}_send_stage.txt" -f $safeMessageLabel)
function Write-SendStage {
    param([string]$Method)
    $gateDeadline = [Environment]::GetEnvironmentVariable("HIWORKS_SEND_DEADLINE")
    if (-not [string]::IsNullOrWhiteSpace($gateDeadline)) {
        $limit = [DateTimeOffset]::Parse($gateDeadline, [Globalization.CultureInfo]::InvariantCulture)
        if ([DateTimeOffset]::Now -ge $limit) {
            throw "Send gate: deadline $gateDeadline has passed; not sending"
        }
    }
    $gateAbort = [Environment]::GetEnvironmentVariable("HIWORKS_SEND_ABORT_FLAG")
    if (-not [string]::IsNullOrWhiteSpace($gateAbort) -and (Test-Path -LiteralPath $gateAbort)) {
        throw "Send gate: abort flag present ($gateAbort); not sending"
    }
    Set-Content -LiteralPath $sendStageFile -Value ("{0}|{1}|pid={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Method, $PID) -Encoding UTF8
    Write-Log "Send stage recorded ($Method): $sendStageFile"
}
# --- end send stage marker ---

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("HiworksAutoNative" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HiworksAutoNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@
}

function Get-WindowTextValue {
    param([IntPtr]$Hwnd)
    $builder = [System.Text.StringBuilder]::new(512)
    [void][HiworksAutoNative]::GetWindowText($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowClassValue {
    param([IntPtr]$Hwnd)
    $builder = [System.Text.StringBuilder]::new(512)
    [void][HiworksAutoNative]::GetClassName($Hwnd, $builder, $builder.Capacity)
    $builder.ToString()
}

function Get-WindowRectObject {
    param([IntPtr]$Hwnd)
    $rect = New-Object HiworksAutoNative+RECT
    [void][HiworksAutoNative]::GetWindowRect($Hwnd, [ref]$rect)
    [PSCustomObject]@{
        Left = $rect.Left
        Top = $rect.Top
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
    }
}

function Get-ProcessNameMap {
    # PID -> 프로세스 이름 스냅샷. 전체 프로세스 목록을 한 번만 읽는다.
    $map = @{}
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $map[[string]$proc.Id] = $proc.ProcessName
        } catch {
        } finally {
            $proc.Dispose()
        }
    }
    $map
}

function Get-TopLevelWindows {
    # 2026-09-28: 창마다 Get-Process -Id 를 부르던 것을 PID 맵 1회 조회로 바꿨다.
    # Get-Process -Id 는 호출마다 전체 프로세스 목록을 다시 읽어서, 최상위 창 수백 개를 돌면
    # 열거 1회가 3~30초까지 늘었다. 9/28 퇴근 발송이 120초 제한에 걸린 직접 원인.
    $enumStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $windows = New-Object System.Collections.Generic.List[object]
    $processNames = Get-ProcessNameMap
    [HiworksAutoNative]::EnumWindows({
        param([IntPtr]$hwnd, [IntPtr]$lParam)
        $windowPid = [uint32]0
        [void][HiworksAutoNative]::GetWindowThreadProcessId($hwnd, [ref]$windowPid)
        $pidKey = [string]$windowPid
        $windowProcessName = $processNames[$pidKey]
        if ($null -eq $windowProcessName) {
            # 스냅샷 이후 새로 뜬 프로세스(재시작 직후 하이웍스 등)는 개별 조회로 보완한다.
            $process = Get-Process -Id $windowPid -ErrorAction SilentlyContinue
            $windowProcessName = if ($process) { $process.ProcessName } else { "" }
            $processNames[$pidKey] = $windowProcessName
        }
        $rect = Get-WindowRectObject -Hwnd $hwnd
        $windows.Add([PSCustomObject]@{
            Hwnd = $hwnd
            Pid = $windowPid
            ProcessName = $windowProcessName
            Title = Get-WindowTextValue -Hwnd $hwnd
            ClassName = Get-WindowClassValue -Hwnd $hwnd
            Visible = [HiworksAutoNative]::IsWindowVisible($hwnd)
            Minimized = [HiworksAutoNative]::IsIconic($hwnd)
            Rect = $rect
        })
        $true
    }, [IntPtr]::Zero) | Out-Null
    $enumStopwatch.Stop()
    if ($enumStopwatch.ElapsedMilliseconds -ge 1500) {
        Write-Log ("[PERF] Top-level window enumeration took {0}ms ({1} windows)" -f $enumStopwatch.ElapsedMilliseconds, $windows.Count)
    }
    $windows
}

function Get-WindowObjectByHwnd {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) {
        return $null
    }

    $windowPid = [uint32]0
    [void][HiworksAutoNative]::GetWindowThreadProcessId($Hwnd, [ref]$windowPid)
    $process = Get-Process -Id $windowPid -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Hwnd = $Hwnd
        Pid = $windowPid
        ProcessName = if ($process) { $process.ProcessName } else { "" }
        Title = Get-WindowTextValue -Hwnd $Hwnd
        ClassName = Get-WindowClassValue -Hwnd $Hwnd
        Visible = [HiworksAutoNative]::IsWindowVisible($Hwnd)
        Minimized = [HiworksAutoNative]::IsIconic($Hwnd)
        Rect = Get-WindowRectObject -Hwnd $Hwnd
    }
}

function Get-HiworksWindows {
    Get-TopLevelWindows |
        Where-Object { $_.ProcessName -eq $processName } |
        Sort-Object @{ Expression = { -not $_.Visible } }, @{ Expression = { $_.Rect.Area }; Descending = $true }
}

function Assert-CoordinateTargetWindow {
    param(
        [object]$Window,
        [string]$Stage
    )

    if ($null -eq $Window -or $null -eq $Window.Hwnd -or $Window.Hwnd -eq [IntPtr]::Zero) {
        throw "${Stage}: Hiworks window handle is missing; aborting coordinate fallback."
    }

    $freshWindow = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
    if ($null -eq $freshWindow -or !$freshWindow.Visible -or $freshWindow.ProcessName -ne $processName) {
        throw "${Stage}: Hiworks window handle is stale or no longer owned by $processName; aborting coordinate fallback. window=$(Format-Window -Window $freshWindow)"
    }

    if ($freshWindow.Rect.Width -lt 250 -or $freshWindow.Rect.Height -lt 250) {
        throw "${Stage}: Hiworks window rectangle is not usable for coordinate fallback. window=$(Format-Window -Window $freshWindow)"
    }

    $freshWindow
}

function Assert-PointInsideWindow {
    param(
        [object]$Window,
        [int]$X,
        [int]$Y,
        [string]$Stage
    )

    if ($X -lt $Window.Rect.Left -or $X -gt $Window.Rect.Right -or $Y -lt $Window.Rect.Top -or $Y -gt $Window.Rect.Bottom) {
        throw "${Stage}: coordinate is outside Hiworks window; aborting click. x=$X y=$Y window=$(Format-Window -Window $Window)"
    }
}

function Format-Window {
    param([object]$Window)
    if (!$Window) {
        return "<null>"
    }
    "hwnd={0} pid={1} proc='{2}' title='{3}' class='{4}' visible={5} x={6} y={7} w={8} h={9}" -f `
        $Window.Hwnd, $Window.Pid, $Window.ProcessName, $Window.Title, $Window.ClassName, $Window.Visible, `
        $Window.Rect.Left, $Window.Rect.Top, $Window.Rect.Width, $Window.Rect.Height
}

function Normalize-TitleText {
    param([string]$Text)
    if ($null -eq $Text) {
        return ""
    }
    ($Text -replace '\s+', '').Trim()
}

function Test-TitleTextMatch {
    param(
        [string]$Candidate,
        [string]$Expected
    )

    $candidateNorm = Normalize-TitleText -Text $Candidate
    $expectedNorm = Normalize-TitleText -Text $Expected

    if ([string]::IsNullOrWhiteSpace($candidateNorm) -or [string]::IsNullOrWhiteSpace($expectedNorm)) {
        return $false
    }

    if ($candidateNorm -like "*$expectedNorm*") {
        return $true
    }

    if ($expectedNorm -like "*,*") {
        $expectedParts = $expectedNorm -split ',' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
        if ($expectedParts.Count -gt 1) {
            foreach ($part in $expectedParts) {
                if ($candidateNorm -notlike "*$part*") {
                    return $false
                }
            }
            return $true
        }
    }

    $false
}

function Save-Screenshot {
    param([string]$Step)
    if ($NoScreenshots) {
        return $null
    }

    try {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        $safeStep = $Step -replace '[^\w-]', '_'
        $path = Join-Path $logDir ("hiworks_{0}_{1}_{2}.png" -f $safeMessageLabel, $stamp, $safeStep)
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size)
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        Write-Log "Screenshot[$Step]: $path"
        return $path
    } catch {
        Write-Log "Screenshot[$Step] failed: $($_.Exception.Message)"
        return $null
    }
}

function Wait-For {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutMs = 8000,
        [int]$IntervalMs = 200
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        $result = & $Condition
        if ($result) {
            return $result
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
    $null
}

function Show-And-Focus {
    param([IntPtr]$Hwnd)
    $hwndTopMost = [IntPtr]::new(-1)
    $hwndNoTopMost = [IntPtr]::new(-2)
    $swpNoMoveNoSize = 0x0001 -bor 0x0002

    if ([HiworksAutoNative]::IsIconic($Hwnd)) {
        [void][HiworksAutoNative]::ShowWindow($Hwnd, 9)
        Start-Sleep -Milliseconds 300
    } else {
        [void][HiworksAutoNative]::ShowWindow($Hwnd, 5)
        Start-Sleep -Milliseconds 120
    }

    [void][HiworksAutoNative]::ShowWindow($Hwnd, 9)
    Start-Sleep -Milliseconds 180
    [void][HiworksAutoNative]::SetWindowPos($Hwnd, $hwndTopMost, 0, 0, 0, 0, $swpNoMoveNoSize)
    Start-Sleep -Milliseconds 120
    [void][HiworksAutoNative]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 220
    [void][HiworksAutoNative]::SetWindowPos($Hwnd, $hwndNoTopMost, 0, 0, 0, 0, $swpNoMoveNoSize)
    Start-Sleep -Milliseconds 180
}

function Ensure-ForegroundWindow {
    param(
        [object]$Window,
        [string]$Stage
    )

    if (!$Window -or $Window.Hwnd -eq [IntPtr]::Zero) {
        throw "${Stage}: expected Hiworks window is missing before coordinate input."
    }

    Show-And-Focus -Hwnd $Window.Hwnd
    $foreground = Wait-For -TimeoutMs 1800 -IntervalMs 100 -Condition {
        $candidate = Get-WindowObjectByHwnd -Hwnd ([HiworksAutoNative]::GetForegroundWindow())
        if ($candidate -and $candidate.ProcessName -eq $processName -and $candidate.Hwnd -eq $Window.Hwnd) {
            return $candidate
        }
        $null
    }

    if (!$foreground) {
        $active = Get-WindowObjectByHwnd -Hwnd ([HiworksAutoNative]::GetForegroundWindow())
        throw "${Stage}: foreground window is not the expected Hiworks window; refusing coordinate input. expected=$(Format-Window -Window $Window) active=$(Format-Window -Window $active)"
    }

    $foreground
}

function Test-WindowUsable {
    param(
        [object]$Window,
        [int]$MinWidth = 250,
        [int]$MinHeight = 250
    )

    [bool](
        $Window -and
        $Window.Visible -and
        !$Window.Minimized -and
        $Window.Rect.Left -gt -30000 -and
        $Window.Rect.Top -gt -30000 -and
        $Window.Rect.Width -ge $MinWidth -and
        $Window.Rect.Height -ge $MinHeight
    )
}

function Move-WindowFixed {
    param(
        [object]$Window,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    if (!$Window -or $Window.Hwnd -eq [IntPtr]::Zero) {
        throw "Window handle is empty before move."
    }

    $hwndInsertAfter = [IntPtr]::Zero
    $swpShowWindow = 0x0040
    $moved = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (!(Test-HiworksWindowAlive -Window $Window)) {
            # 사라진 핸들에 복원을 5번 반복하면 30초를 버린다. 바로 알리고 호출 쪽에서 창을 다시 찾게 한다.
            throw ("Window handle no longer exists: {0}" -f (Format-Window -Window $Window))
        }
        Show-And-Focus -Hwnd $Window.Hwnd
        [void][HiworksAutoNative]::ShowWindow($Window.Hwnd, 9)
        Start-Sleep -Milliseconds 300
        [void][HiworksAutoNative]::ShowWindow($Window.Hwnd, 1)
        Start-Sleep -Milliseconds 200
        [void][HiworksAutoNative]::SetWindowPos($Window.Hwnd, $hwndInsertAfter, $X, $Y, $Width, $Height, $swpShowWindow)
        Start-Sleep -Milliseconds 250
        [void][HiworksAutoNative]::MoveWindow($Window.Hwnd, $X, $Y, $Width, $Height, $true)
        Start-Sleep -Milliseconds 550
        Show-And-Focus -Hwnd $Window.Hwnd

        $moved = Wait-For -TimeoutMs 3000 -IntervalMs 200 -Condition {
            $candidate = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
            if (Test-WindowUsable -Window $candidate -MinWidth 250 -MinHeight 250) {
                return $candidate
            }
            $null
        }

        if ($moved) {
            Write-Log ("Window fixed: {0}" -f (Format-Window -Window $moved))
            return $moved
        }

        $current = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
        Write-Log ("Window restore attempt {0} did not produce usable coordinates: {1}" -f $attempt, (Format-Window -Window $current))
    }

    $current = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
    throw ("Window restore failed after retries: {0}" -f (Format-Window -Window $current))
}
function Test-HiworksWindowAlive {
    param([object]$Window)
    if (!$Window -or $Window.Hwnd -eq [IntPtr]::Zero) {
        return $false
    }
    $current = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
    [bool]($current -and $current.Pid -ne 0 -and $current.ProcessName -eq $processName)
}

function Find-MainWindowCandidate {
    Get-HiworksWindows |
        Where-Object { $_.Visible -and $_.Title -like "*$mainWindowTitle*" } |
        Sort-Object @{ Expression = { $_.Rect.Area }; Descending = $true } |
        Select-Object -First 1
}

function Wait-StableMainWindow {
    param([int]$TimeoutMs = 60000)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $lastHwnd = [IntPtr]::Zero
    $firstSeenMs = 0
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        $candidate = Find-MainWindowCandidate
        if ($candidate) {
            if ($candidate.Hwnd -ne $lastHwnd) {
                $lastHwnd = $candidate.Hwnd
                $firstSeenMs = $stopwatch.ElapsedMilliseconds
            } elseif (($stopwatch.ElapsedMilliseconds - $firstSeenMs) -ge $mainWindowStableMs) {
                return $candidate
            }
        } else {
            $lastHwnd = [IntPtr]::Zero
        }
        Start-Sleep -Milliseconds 500
    }
    $null
}

function Get-FixedMainWindowAfterStart {
    param([string]$Reason)
    $deadline = (Get-Date).AddSeconds($mainWindowAcquireSeconds)
    for ($try = 1; $try -le 3; $try++) {
        $remainingMs = [int][Math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
        $window = Wait-StableMainWindow -TimeoutMs $remainingMs
        if (!$window) {
            break
        }
        Write-Log ("Main window stable after {0} (try {1}): {2}" -f $Reason, $try, (Format-Window -Window $window))
        try {
            return Move-MainWindowFixed -Window $window
        } catch {
            if (Test-HiworksWindowAlive -Window $window) {
                throw
            }
            Write-Log "[WARN] Main window disappeared during restore; re-acquiring: $($_.Exception.Message)"
        }
        if ((Get-Date) -gt $deadline) {
            break
        }
    }
    throw "하이웍스 메신저 $Reason 후 ${mainWindowAcquireSeconds}초 안에 안정된 메인창을 찾지 못했습니다."
}

function Move-MainWindowFixed {
    param([object]$Window)
    Move-WindowFixed -Window $Window -X $MainX -Y $MainY -Width $MainWidth -Height $MainHeight
}

function Move-ChatWindowFixed {
    param([object]$Window)
    Move-WindowFixed -Window $Window -X $ChatX -Y $ChatY -Width $ChatWidth -Height $ChatHeight
}

function Click-Point {
    param([int]$X, [int]$Y)
    [void][HiworksAutoNative]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 80
    [HiworksAutoNative]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function DoubleClick-Point {
    param([int]$X, [int]$Y)
    Click-Point -X $X -Y $Y
    Start-Sleep -Milliseconds 120
    Click-Point -X $X -Y $Y
}

function Send-NativeCtrlKey {
    param([byte]$VirtualKey)
    [HiworksAutoNative]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event($VirtualKey, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event(0x11, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
}

function Send-EnterKey {
    [HiworksAutoNative]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [HiworksAutoNative]::keybd_event(0x0D, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
}

function Send-AltF4 {
    [HiworksAutoNative]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event(0x73, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event(0x73, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [HiworksAutoNative]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 250
}

function Send-TextToActiveWindow {
    param([string]$Text)
    if ($null -eq $Text) {
        throw "붙여넣을 텍스트가 null입니다."
    }

    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 250
    Send-NativeCtrlKey -VirtualKey 0x41
    Send-NativeCtrlKey -VirtualKey 0x56
    Start-Sleep -Milliseconds 450
}

function Get-RootElement {
    param([IntPtr]$Hwnd)
    [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
}

function Is-UsableRect {
    param($Rect)
    -not [double]::IsInfinity($Rect.X) -and
    -not [double]::IsInfinity($Rect.Y) -and
    $Rect.Width -gt 0 -and
    $Rect.Height -gt 0
}

function Get-VisibleDescendants {
    param([System.Windows.Automation.AutomationElement]$Root)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $all.Count; $i++) {
        $element = $all.Item($i)
        $rect = $element.Current.BoundingRectangle
        if (Is-UsableRect $rect) {
            $items.Add($element)
        }
    }
    $items
}

function Test-ChatUi {
    param([object]$Window)
    try {
        if (!$Window -or !$Window.Visible -or $Window.Rect.Width -lt 280 -or $Window.Rect.Height -lt 300) {
            return $false
        }

        $root = Get-RootElement -Hwnd $Window.Hwnd
        $elements = Get-VisibleDescendants -Root $root
        $lowerY = $Window.Rect.Top + ($Window.Rect.Height * 0.48)

        $inputElement = $elements |
            Where-Object {
                (
                    ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and $_.Current.ClassName -like "*RichTextBox*") -or
                    ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and $_.Current.BoundingRectangle.Height -gt 20)
                ) -and
                $_.Current.BoundingRectangle.Y -gt $lowerY -and
                $_.Current.BoundingRectangle.Width -gt 100
            } |
            Select-Object -First 1

        $sendButton = $elements |
            Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
                ($_.Current.Name -eq "전송" -or $_.Current.Name -like "*전송*")
            } |
            Select-Object -First 1

        [bool]($inputElement -and $sendButton)
    } catch {
        Write-Log ("Chat UI probe failed for {0}: {1}" -f (Format-Window -Window $Window), $_.Exception.Message)
        $false
    }
}

function Test-UsableChatWindow {
    param(
        [object]$Window,
        [string]$Stage
    )

    if (!$Window -or !$Window.Visible -or $Window.Rect.Width -lt 280 -or $Window.Rect.Height -lt 300) {
        return $false
    }

    $hasChatUi = Test-ChatUi -Window $Window
    if (!$hasChatUi) {
        Write-Log ("Ignoring unusable chat candidate at {0}: {1}" -f $Stage, (Format-Window -Window $Window))
        return $false
    }

    return $true
}

function Close-StaleTargetChatWindows {
    param([object]$MainWindow)

    $staleWindows = @(
        Get-TopLevelWindows |
            Where-Object {
                $_.Visible -and
                $_.ProcessName -eq $processName -and
                $_.Hwnd -ne $MainWindow.Hwnd -and
                (Is-TargetTitle -Title $_.Title) -and
                !(Test-ChatUi -Window $_)
            }
    )

    foreach ($window in $staleWindows) {
        Write-Log ("Closing stale target chat window before reopen: {0}" -f (Format-Window -Window $window))
        try {
            $root = Get-RootElement -Hwnd $window.Hwnd
            $windowPattern = $null
            if ($root.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$windowPattern)) {
                $windowPattern.Close()
            }
        } catch {
            Write-Log "WindowPattern close failed for stale chat: $($_.Exception.Message)"
        }
        [void][HiworksAutoNative]::SendMessage($window.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 500
        $stillOpen = Get-WindowObjectByHwnd -Hwnd $window.Hwnd
        if ($stillOpen -and $stillOpen.Visible -and $stillOpen.ProcessName -eq $processName) {
            Write-Log ("Stale target chat still open after close request; sending Alt+F4: {0}" -f (Format-Window -Window $stillOpen))
            Show-And-Focus -Hwnd $stillOpen.Hwnd
            Send-AltF4
            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-ChatInputAndSendButton {
    param([object]$Window)
    $root = Get-RootElement -Hwnd $Window.Hwnd
    $elements = Get-VisibleDescendants -Root $root
    $lowerY = $Window.Rect.Top + ($Window.Rect.Height * 0.48)

    $inputElement = $elements |
        Where-Object {
            (
                ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and $_.Current.ClassName -like "*RichTextBox*") -or
                ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and $_.Current.BoundingRectangle.Height -gt 20)
            ) -and
            $_.Current.BoundingRectangle.Y -gt $lowerY -and
            $_.Current.BoundingRectangle.Width -gt 100
        } |
        Sort-Object { $_.Current.BoundingRectangle.Y } -Descending |
        Select-Object -First 1

    $sendButton = $elements |
        Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            ($_.Current.Name -eq "전송" -or $_.Current.Name -like "*전송*")
        } |
        Sort-Object { $_.Current.BoundingRectangle.Y } -Descending |
        Select-Object -First 1

    [PSCustomObject]@{
        Input = $inputElement
        SendButton = $sendButton
    }
}

function Ensure-HiworksProcess {
    $process = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($process) {
        return
    }

    if (!(Test-Path -LiteralPath $hiworksPath)) {
        throw "Hiworks executable not found: $hiworksPath"
    }

    Write-Log "Starting Hiworks Messenger"
    Start-Process -FilePath $hiworksPath | Out-Null
    $script:hiworksStartedByScript = $true
    $process = Wait-For -TimeoutMs 45000 -IntervalMs 500 -Condition {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (!$process) {
        throw "Hiworks process did not start within 45 seconds."
    }
}

function Restart-HiworksMessengerForAutomation {
    if (!(Test-Path -LiteralPath $hiworksPath)) {
        throw "Hiworks executable not found: $hiworksPath"
    }

    Write-Log "[WARN] Restarting Hiworks Messenger because the main window is unusable for automation."
    $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to stop Hiworks before restart (PID=$($process.Id)): $($_.Exception.Message)"
        }
    }

    $stopped = Wait-For -TimeoutMs 15000 -IntervalMs 500 -Condition {
        if (!(Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            return $true
        }
        $false
    }
    if (!$stopped) {
        Write-Log "[WARN] Existing Hiworks process still detected after restart stop request; starting another instance anyway."
    }

    Start-Process -FilePath $hiworksPath | Out-Null
    $script:hiworksStartedByScript = $true
    $script:hiworksStartWaited = $true
    # 2026-09-28: 처음 보이는 창을 바로 잡지 않는다. 임시 창이 사라지면 핸들이 무효가 되기 때문.
    return Get-FixedMainWindowAfterStart -Reason "restart"
}

function Get-MainWindow {
    $process = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($process -and $process.MainWindowHandle -ne 0) {
        $mainByHandle = Get-WindowObjectByHwnd -Hwnd $process.MainWindowHandle
        if ($mainByHandle -and $mainByHandle.Visible -and $mainByHandle.Title -like "*$mainWindowTitle*") {
            if (!(Test-WindowUsable -Window $mainByHandle -MinWidth 250 -MinHeight 250)) {
                Write-Log ("Main window handle is unusable before restore; restarting instead: {0}" -f (Format-Window -Window $mainByHandle))
                return Restart-HiworksMessengerForAutomation
            }
            try {
                return Move-MainWindowFixed -Window $mainByHandle
            } catch {
                Write-Log "Main window handle restore failed; trying window enumeration: $($_.Exception.Message)"
            }
        }
    }

    $window = Get-HiworksWindows |
        Where-Object {
            $_.Visible -and
            $_.Title -like "*$mainWindowTitle*"
        } |
        Sort-Object @{ Expression = { $_.Rect.Area }; Descending = $true } |
        Select-Object -First 1

    if ($window) {
        if (!(Test-WindowUsable -Window $window -MinWidth 250 -MinHeight 250)) {
            Write-Log ("Enumerated main window is unusable before restore; restarting instead: {0}" -f (Format-Window -Window $window))
            return Restart-HiworksMessengerForAutomation
        }
        try {
            return Move-MainWindowFixed -Window $window
        } catch {
            Write-Log "Enumerated main window restore failed; launching executable fallback: $($_.Exception.Message)"
        }
    }

    if ($script:hiworksStartedByScript -and !$script:hiworksStartWaited) {
        # 방금 이 스크립트가 띄운 메신저는 아직 로딩 중일 뿐이다. 재시작하면 로딩을 처음부터 다시 한다.
        $script:hiworksStartWaited = $true
        Write-Log "Hiworks was just started by this script; waiting for its main window instead of restarting."
        try {
            return Get-FixedMainWindowAfterStart -Reason "start"
        } catch {
            Write-Log "[WARN] $($_.Exception.Message) Falling back to restart."
        }
    }

    Write-Log "Main window not found or unusable; restarting Hiworks Messenger."
    return Restart-HiworksMessengerForAutomation
}

function Test-CoworkerDirectorySearchResult {
    param([object]$MainWindow)

    try {
        $root = Get-RootElement -Hwnd $MainWindow.Hwnd
        $elements = Get-VisibleDescendants -Root $root
        $searchNorm = Normalize-TitleText -Text $searchQuery
        foreach ($element in $elements) {
            $name = Normalize-TitleText -Text $element.Current.Name
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if ($name -like "*고객사*" -or $name -like "*부서*" -or $name -like "*지원실*") {
                Write-Log ("Coworker directory marker detected after search: '{0}'" -f $element.Current.Name)
                return $true
            }

            if (![string]::IsNullOrWhiteSpace($searchNorm) -and $name -like "*실장*" -and $name -like "*$searchNorm*") {
                Write-Log ("Coworker contact result detected after search: '{0}'" -f $element.Current.Name)
                return $true
            }
        }
    } catch {
        Write-Log "Coworker directory detection failed: $($_.Exception.Message)"
    }

    $false
}

function Get-HiworksAccountName {
    param([object]$MainWindow)

    try {
        $root = Get-RootElement -Hwnd $MainWindow.Hwnd
        $elements = Get-VisibleDescendants -Root $root
        $topLimit = $MainWindow.Rect.Top + 140
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($element in $elements) {
            $name = ($element.Current.Name).Trim()
            $rect = $element.Current.BoundingRectangle
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            if ($rect.Y -lt $MainWindow.Rect.Top -or $rect.Y -gt $topLimit) {
                continue
            }
            if ($name -eq "hiworks") {
                continue
            }
            if ($name -match '하이웍스|유아|초등|중등|중고등|CS') {
                $candidates.Add([PSCustomObject]@{
                    Name = $name
                    X = $rect.X
                    Y = $rect.Y
                })
            }
        }

        $candidate = $candidates |
            Sort-Object Y, X |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.Name
        }
    } catch {
        Write-Log "Account name lookup failed: $($_.Exception.Message)"
    }

    $null
}

function Assert-ExpectedAccountName {
    param([object]$MainWindow)

    if ([string]::IsNullOrWhiteSpace($ExpectedAccountName)) {
        return
    }

    $detectedAccount = Get-HiworksAccountName -MainWindow $MainWindow
    if ([string]::IsNullOrWhiteSpace($detectedAccount)) {
        Write-Log "[WARN] Could not detect Hiworks account name; continuing because account text is not exposed to UIA."
        return
    }

    Write-Log "Detected Hiworks account: $detectedAccount"
    if ((Normalize-TitleText -Text $detectedAccount) -ne (Normalize-TitleText -Text $ExpectedAccountName)) {
        throw "하이웍스 로그인 계정이 예상과 다릅니다. expected='$ExpectedAccountName' actual='$detectedAccount'"
    }
}

function Set-SearchTextWithUiaOrCoordinates {
    param(
        [object]$MainWindow,
        [string]$Text,
        [int]$ChatTabVariant = 0
    )

    Show-And-Focus -Hwnd $MainWindow.Hwnd
    $mainRect = Get-WindowRectObject -Hwnd $MainWindow.Hwnd
    Select-ChatTab -MainWindow $MainWindow -Variant $ChatTabVariant

    try {
        $root = Get-RootElement -Hwnd $MainWindow.Hwnd
        $elements = Get-VisibleDescendants -Root $root
        $searchBox = $elements |
            Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                $_.Current.BoundingRectangle.Width -gt 160 -and
                $_.Current.BoundingRectangle.Height -lt 55 -and
                $_.Current.BoundingRectangle.Y -gt ($mainRect.Top + 100) -and
                $_.Current.BoundingRectangle.Y -lt ($mainRect.Top + 260)
            } |
            Sort-Object { $_.Current.BoundingRectangle.Y } |
            Select-Object -First 1

        if ($searchBox) {
            $rect = $searchBox.Current.BoundingRectangle
            Write-Log ("Search box by UIA: x={0}, y={1}, w={2}, h={3}" -f [int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height)
            try {
                $searchBox.SetFocus()
            } catch {
            }
            Click-Point -X ([int]($rect.X + ($rect.Width / 2))) -Y ([int]($rect.Y + ($rect.Height / 2)))
            Send-TextToActiveWindow -Text $Text
            Start-Sleep -Milliseconds 1200
            if (Test-CoworkerDirectorySearchResult -MainWindow $MainWindow) {
                Write-Log "[WARN] Coworker directory result detected after chat tab selection; retrying chat tab selection"
                Select-ChatTab -MainWindow $MainWindow -Variant (($ChatTabVariant + 1) % 4)
                try {
                    $searchBox.SetFocus()
                } catch {
                }
                Click-Point -X ([int]($rect.X + ($rect.Width / 2))) -Y ([int]($rect.Y + ($rect.Height / 2)))
                Send-TextToActiveWindow -Text $Text
                Start-Sleep -Milliseconds 1200
            }
            if (Test-CoworkerDirectorySearchResult -MainWindow $MainWindow) {
                throw "채팅 탭 선택 실패: 동료 탭 검색 결과가 보여서 메시지 발송을 중단합니다."
            }
            return $rect
        }

        Write-Log "Search box was not visible to UIA; using coordinate search"
    } catch {
        Write-Log "UIA search failed; using coordinate search: $($_.Exception.Message)"
    }

    $searchWindow = Assert-CoordinateTargetWindow -Window $MainWindow -Stage "search-coordinate"
    $mainRect = $searchWindow.Rect
    $searchX = [int]($mainRect.Left + ($mainRect.Width / 2))
    $searchY = [int]($mainRect.Top + 185)
    Assert-PointInsideWindow -Window $searchWindow -X $searchX -Y $searchY -Stage "search-coordinate"
    Write-Log ("Search box by coordinates: main={0}; search x={1}, y={2}" -f (Format-Window -Window $searchWindow), $searchX, $searchY)
    Click-Point -X $searchX -Y $searchY
    Send-TextToActiveWindow -Text $Text
    Start-Sleep -Milliseconds 1400
    if (Test-CoworkerDirectorySearchResult -MainWindow $searchWindow) {
        Write-Log "[WARN] Coworker directory result detected after coordinate search; retrying chat tab selection"
        Select-ChatTab -MainWindow $searchWindow -Variant (($ChatTabVariant + 1) % 4)
        $searchWindow = Assert-CoordinateTargetWindow -Window $searchWindow -Stage "search-coordinate-retry"
        Assert-PointInsideWindow -Window $searchWindow -X $searchX -Y $searchY -Stage "search-coordinate-retry"
        Click-Point -X $searchX -Y $searchY
        Send-TextToActiveWindow -Text $Text
        Start-Sleep -Milliseconds 1400
    }
    if (Test-CoworkerDirectorySearchResult -MainWindow $searchWindow) {
        throw "채팅 탭 선택 실패: 동료 탭 검색 결과가 보여서 메시지 발송을 중단합니다."
    }

    [PSCustomObject]@{
        X = $mainRect.Left + 10
        Y = $searchY - 18
        Width = $mainRect.Width - 20
        Height = 36
    }
}

function Select-ChatTab {
    param(
        [object]$MainWindow,
        [int]$Variant = 0
    )

    $freshMain = Assert-CoordinateTargetWindow -Window $MainWindow -Stage "select-chat-tab"
    $mainRect = $freshMain.Rect
    $variantOffsets = @(
        ,@(70, 78, 86)
        ,@(62, 70, 78)
        ,@(78, 88, 96)
        ,@(68, 82, [Math]::Round($mainRect.Width * 0.22))
    )
    $offsets = $variantOffsets[[Math]::Abs($Variant % $variantOffsets.Count)]
    $yOffsets = @(145, 140, 153)
    $points = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $offsets.Count; $i++) {
        $points.Add([PSCustomObject]@{
            X = [int]($mainRect.Left + $offsets[$i])
            Y = [int]($mainRect.Top + $yOffsets[[Math]::Min($i, $yOffsets.Count - 1)])
        })
    }

    foreach ($point in $points) {
        Assert-PointInsideWindow -Window $freshMain -X $point.X -Y $point.Y -Stage "select-chat-tab"
        Write-Log ("Selecting chat tab by coordinates: variant={0}, x={1}, y={2}" -f $Variant, $point.X, $point.Y)
        Click-Point -X $point.X -Y $point.Y
        Start-Sleep -Milliseconds 350
    }

    Start-Sleep -Milliseconds 700
}

function Find-SearchResultElement {
    param(
        [object]$MainWindow,
        $SearchRect
    )

    try {
        $root = Get-RootElement -Hwnd $MainWindow.Hwnd
        $elements = Get-VisibleDescendants -Root $root
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($element in $elements) {
            $name = $element.Current.Name
            $rect = $element.Current.BoundingRectangle
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            if ($rect.Y -le ($SearchRect.Y + 35) -or $rect.Y -ge ($MainWindow.Rect.Bottom - 20)) {
                continue
            }

            $score = $null
            $nameNorm = Normalize-TitleText -Text $name
            $chatNorm = Normalize-TitleText -Text $chatTitle
            $searchNorm = Normalize-TitleText -Text $searchResultQuery

            $isMultiPersonTarget = $chatNorm -like "*,*"
            if (Test-TitleTextMatch -Candidate $name -Expected $chatTitle) {
                $score = 0
            } elseif (!$isMultiPersonTarget -and $chatNorm -like "*$nameNorm*" -and $nameNorm.Length -ge 2) {
                $score = 1
            } elseif (!$isMultiPersonTarget -and $nameNorm -like "*$searchNorm*") {
                $score = 2
            } elseif ($isMultiPersonTarget -and $nameNorm -like "*$searchNorm*") {
                Write-Log ("Ignoring partial search result for multi-person target: name='{0}', target='{1}'" -f $name, $chatTitle)
            }

            if ($null -ne $score) {
                $candidates.Add([PSCustomObject]@{
                    Element = $element
                    Name = $name
                    Score = $score
                    Y = $rect.Y
                })
            }
        }

        $result = $candidates |
            Sort-Object Score, Y |
            Select-Object -First 1

        if ($result) {
            return $result.Element
        }
    } catch {
        Write-Log "Search result UIA lookup failed: $($_.Exception.Message)"
    }

    $null
}

function Select-SearchResult {
    param(
        [object]$MainWindow,
        $SearchRect,
        [hashtable]$BeforeHwnds
    )

    Show-And-Focus -Hwnd $MainWindow.Hwnd
    $nameElement = Find-SearchResultElement -MainWindow $MainWindow -SearchRect $SearchRect
    $gestures = New-Object System.Collections.Generic.List[object]

    if ($nameElement) {
        $nameRect = $nameElement.Current.BoundingRectangle
        $clickX = [int]($nameRect.X + [Math]::Min(70, [Math]::Max(10, $nameRect.Width / 2)))
        $clickY = [int]($nameRect.Y + ($nameRect.Height / 2))
        Write-Log ("Search result by UIA: name='{0}', x={1}, y={2}, w={3}, h={4}" -f $nameElement.Current.Name, [int]$nameRect.X, [int]$nameRect.Y, [int]$nameRect.Width, [int]$nameRect.Height)
        $gestures.Add([PSCustomObject]@{ Name = "uia-result-double"; X = $clickX; Y = $clickY; Double = $true; Enter = $false })
        $gestures.Add([PSCustomObject]@{ Name = "uia-result-click"; X = $clickX; Y = $clickY; Double = $false; Enter = $false })
    } else {
        $coordinateWindow = Assert-CoordinateTargetWindow -Window $MainWindow -Stage "select-search-result"
        $mainRect = $coordinateWindow.Rect
        if ((Normalize-TitleText -Text $chatTitle) -like "*,*") {
            throw "다인 채팅방 '$chatTitle' 검색 결과를 확인하지 못했습니다. 안전을 위해 좌표 fallback을 사용하지 않습니다."
        }

        Write-Log "Search result not visible to UIA; using verified single-person coordinate open sequence"
        $gestures.Add([PSCustomObject]@{ Name = "coordinate-enter"; X = 0; Y = 0; Double = $false; Enter = $true })
        $gestures.Add([PSCustomObject]@{ Name = "coordinate-name-double"; X = [int]($mainRect.Left + 150); Y = [int]($mainRect.Top + 230); Double = $true; Enter = $false })
        $gestures.Add([PSCustomObject]@{ Name = "coordinate-preview-click"; X = [int]($mainRect.Left + 150); Y = [int]($mainRect.Top + 264); Double = $false; Enter = $false })
        $gestures.Add([PSCustomObject]@{ Name = "coordinate-avatar-click"; X = [int]($mainRect.Left + 60); Y = [int]($mainRect.Top + 240); Double = $false; Enter = $false })
        $gestures.Add([PSCustomObject]@{ Name = "coordinate-right-double"; X = [int]($mainRect.Left + 220); Y = [int]($mainRect.Top + 240); Double = $true; Enter = $false })
    }

    foreach ($gesture in $gestures) {
        Show-And-Focus -Hwnd $MainWindow.Hwnd
        if ($gesture.Enter) {
            if ($gesture.Name -like "coordinate-*") {
                $coordinateWindow = Assert-CoordinateTargetWindow -Window $MainWindow -Stage $gesture.Name
            }
            Write-Log ("Selecting search result gesture: {0}" -f $gesture.Name)
            Send-EnterKey
        } elseif ($gesture.Double) {
            if ($gesture.Name -like "coordinate-*") {
                $coordinateWindow = Assert-CoordinateTargetWindow -Window $MainWindow -Stage $gesture.Name
                Assert-PointInsideWindow -Window $coordinateWindow -X $gesture.X -Y $gesture.Y -Stage $gesture.Name
            }
            Write-Log ("Selecting search result gesture: {0}, x={1}, y={2}" -f $gesture.Name, $gesture.X, $gesture.Y)
            DoubleClick-Point -X $gesture.X -Y $gesture.Y
        } else {
            if ($gesture.Name -like "coordinate-*") {
                $coordinateWindow = Assert-CoordinateTargetWindow -Window $MainWindow -Stage $gesture.Name
                Assert-PointInsideWindow -Window $coordinateWindow -X $gesture.X -Y $gesture.Y -Stage $gesture.Name
            }
            Write-Log ("Selecting search result gesture: {0}, x={1}, y={2}" -f $gesture.Name, $gesture.X, $gesture.Y)
            Click-Point -X $gesture.X -Y $gesture.Y
        }

        Start-Sleep -Milliseconds 900
        if ($BeforeHwnds) {
            $opened = Find-ChatWindowCandidate -MainWindow $MainWindow -BeforeHwnds $BeforeHwnds
            if ($opened) {
                Write-Log ("Search result opened chat after gesture '{0}': {1}" -f $gesture.Name, (Format-Window -Window $opened))
                return
            }
        }
    }
}

function Is-TargetTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $false
    }
    if (![string]::IsNullOrWhiteSpace($chatTitle)) {
        return (Test-TitleTextMatch -Candidate $Title -Expected $chatTitle)
    }

    $searchNorm = Normalize-TitleText -Text $searchResultQuery
    (Normalize-TitleText -Text $Title) -like "*$searchNorm*"
}

function Find-ChatWindowCandidate {
    param(
        [object]$MainWindow,
        [hashtable]$BeforeHwnds
    )

    $foreground = Get-WindowObjectByHwnd -Hwnd ([HiworksAutoNative]::GetForegroundWindow())
    if ($foreground -and $foreground.Visible -and $foreground.Hwnd -ne $MainWindow.Hwnd -and $foreground.ProcessName -eq $processName) {
        $isTargetTitle = Is-TargetTitle -Title $foreground.Title
        $isNewBlankHiworksWindow = [string]::IsNullOrWhiteSpace($foreground.Title) -and !$BeforeHwnds.ContainsKey([string]$foreground.Hwnd)
        if ($isTargetTitle -or $isNewBlankHiworksWindow) {
            if (Test-UsableChatWindow -Window $foreground -Stage "foreground") {
                Write-Log ("Chat candidate from foreground: {0}" -f (Format-Window -Window $foreground))
                return $foreground
            }
        }
    }

    $windows = Get-TopLevelWindows | Where-Object { $_.Visible -and $_.ProcessName -eq $processName -and $_.Rect.Width -ge 250 -and $_.Rect.Height -ge 250 }

    $titleMatches = @(
        $windows |
        Where-Object { $_.Hwnd -ne $MainWindow.Hwnd -and (Is-TargetTitle -Title $_.Title) } |
        Sort-Object @{ Expression = { $_.Rect.Area }; Descending = $true }
    )
    foreach ($titleMatch in $titleMatches) {
        if (Test-UsableChatWindow -Window $titleMatch -Stage "title") {
            Write-Log ("Chat candidate from title: {0}" -f (Format-Window -Window $titleMatch))
            return $titleMatch
        }
    }

    $hiworksMatches = @(
        $windows |
        Where-Object {
            $_.Hwnd -ne $MainWindow.Hwnd -and
            $_.ProcessName -eq $processName -and
            ((Is-TargetTitle -Title $_.Title) -or [string]::IsNullOrWhiteSpace($_.Title)) -and
            ($_.Rect.Width -ge 280 -and $_.Rect.Width -le 900) -and
            ($_.Rect.Height -ge 300 -and $_.Rect.Height -le 900)
        } |
        Sort-Object @{ Expression = { $BeforeHwnds.ContainsKey([string]$_.Hwnd) } }, @{ Expression = { $_.Rect.Area }; Descending = $true }
    )
    foreach ($hiworksMatch in $hiworksMatches) {
        if (Test-UsableChatWindow -Window $hiworksMatch -Stage "top-level") {
            Write-Log ("Chat candidate from Hiworks top-level window: {0}" -f (Format-Window -Window $hiworksMatch))
            return $hiworksMatch
        }
    }

    if (Test-ChatUi -Window $MainWindow) {
        Write-Log "Main window itself now exposes chat UI; using it as chat target."
        return $MainWindow
    }

    $null
}

function Open-TargetChatFromMain {
    $mainWindow = Get-MainWindow
    Write-Log ("Main window ready: {0}" -f (Format-Window -Window $mainWindow))
    Assert-ExpectedAccountName -MainWindow $mainWindow
    Save-Screenshot -Step "main_fixed" | Out-Null

    $beforeHwnds = @{}
    Get-TopLevelWindows | ForEach-Object { $beforeHwnds[[string]$_.Hwnd] = $true }

    $attemptLimit = [Math]::Max(1, $MaxOpenChatAttempts)
    $openTimeout = [Math]::Max(1000, $ChatOpenTimeoutMs)
    for ($searchAttempt = 1; $searchAttempt -le $attemptLimit; $searchAttempt++) {
        Write-Log "Opening target chat attempt ${searchAttempt}/${attemptLimit}"
        $searchRect = Set-SearchTextWithUiaOrCoordinates -MainWindow $mainWindow -Text $searchQuery -ChatTabVariant ($searchAttempt - 1)
        Save-Screenshot -Step ("after_search_{0}" -f $searchAttempt) | Out-Null
        Select-SearchResult -MainWindow $mainWindow -SearchRect $searchRect -BeforeHwnds $beforeHwnds
        Start-Sleep -Milliseconds 900

        $openedWindow = Wait-For -TimeoutMs $openTimeout -IntervalMs 400 -Condition {
            Find-ChatWindowCandidate -MainWindow $mainWindow -BeforeHwnds $beforeHwnds
        }

        if ($openedWindow) {
            if ($openedWindow.Hwnd -eq $mainWindow.Hwnd) {
                return Move-MainWindowFixed -Window $openedWindow
            }
            return Move-ChatWindowFixed -Window $openedWindow
        }

        Write-Log "Target chat did not open on attempt ${searchAttempt}; retrying chat tab selection and search."
    }

    Save-Screenshot -Step "chat_not_found" | Out-Null
    $visibleWindows = Get-TopLevelWindows |
        Where-Object { $_.Visible -and $_.Rect.Width -gt 200 -and $_.Rect.Height -gt 200 } |
        Sort-Object @{ Expression = { $_.ProcessName } }, @{ Expression = { $_.Rect.Left } }
    foreach ($window in $visibleWindows) {
        Write-Log ("Visible window after search: {0}" -f (Format-Window -Window $window))
    }

    $null
}

function Ensure-TargetChatWindow {
    $mainWindow = Get-MainWindow
    Assert-ExpectedAccountName -MainWindow $mainWindow
    Close-StaleTargetChatWindows -MainWindow $mainWindow
    $existing = Find-ChatWindowCandidate -MainWindow $mainWindow -BeforeHwnds @{}
    if ($existing) {
        if ($existing.Hwnd -eq $mainWindow.Hwnd) {
            return Move-MainWindowFixed -Window $existing
        }
        return Move-ChatWindowFixed -Window $existing
    }

    Write-Log "Chat window not found; opening from main window"
    $chatWindow = Open-TargetChatFromMain
    if ($chatWindow) {
        return $chatWindow
    }

    throw "'$chatTitle' 채팅창을 열지 못했습니다."
}

function Normalize-MessageTextForCompare {
    param([string]$Text)
    if ($null -eq $Text) {
        return ""
    }

    ($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n", " ", "`t")
}

function Get-ElementTextValue {
    param([System.Windows.Automation.AutomationElement]$Element)

    if (!$Element) {
        return ""
    }

    try {
        $textPattern = $null
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) {
            return $textPattern.DocumentRange.GetText(-1)
        }
    } catch {
        Write-Log "TextPattern read failed: $($_.Exception.Message)"
    }

    try {
        $valuePattern = $null
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
            return $valuePattern.Current.Value
        }
    } catch {
        Write-Log "ValuePattern read failed: $($_.Exception.Message)"
    }

    ""
}

function Assert-MessageTextInInput {
    param(
        [System.Windows.Automation.AutomationElement]$InputElement,
        [string]$ExpectedMessage
    )

    $expected = Normalize-MessageTextForCompare -Text $ExpectedMessage
    $actual = Normalize-MessageTextForCompare -Text (Get-ElementTextValue -Element $InputElement)

    if ([string]::IsNullOrWhiteSpace($actual)) {
        throw "메시지 입력 확인 실패: 입력창 텍스트를 읽었지만 비어 있습니다."
    }

    if (!$actual.Contains($expected)) {
        throw "메시지 입력 확인 실패: 입력창에 기대한 메시지가 들어있지 않습니다. expectedLength=$($expected.Length) actualLength=$($actual.Length)"
    }

    Write-Log "[OK] Message text verified in chat input. length=$($expected.Length)"
}

function Assert-MessageClearedFromInput {
    param(
        [System.Windows.Automation.AutomationElement]$InputElement,
        [string]$ExpectedMessage
    )

    $expected = Normalize-MessageTextForCompare -Text $ExpectedMessage
    $actual = Normalize-MessageTextForCompare -Text (Get-ElementTextValue -Element $InputElement)

    if (![string]::IsNullOrWhiteSpace($actual) -and $actual.Contains($expected)) {
        throw "메시지 전송 확인 실패: 전송 후에도 입력창에 기대 메시지가 남아 있습니다."
    }

    Write-Log "[OK] Message input cleared or no longer exposes sent text."
}

function Assert-TargetChatWindowUsable {
    param(
        [object]$Window,
        [string]$Stage
    )

    if (!$Window -or $Window.Hwnd -eq [IntPtr]::Zero) {
        throw "채팅창 핸들이 비어 있습니다. Stage=$Stage"
    }

    $current = Get-WindowObjectByHwnd -Hwnd $Window.Hwnd
    if (!$current -or $current.Pid -eq 0 -or [string]::IsNullOrWhiteSpace($current.ProcessName)) {
        throw "채팅창 핸들이 더 이상 유효하지 않습니다. Stage=$Stage hwnd=$($Window.Hwnd)"
    }

    if ($current.ProcessName -ne $processName) {
        throw "하이웍스 채팅창이 아닌 창을 대상으로 잡았습니다. Stage=$Stage window=$(Format-Window -Window $current)"
    }

    if (!$current.Visible -or $current.Minimized -or $current.Rect.Width -lt 280 -or $current.Rect.Height -lt 300) {
        throw "채팅창이 보이지 않거나 크기가 비정상입니다. Stage=$Stage window=$(Format-Window -Window $current)"
    }

    $isMainWindow = $current.Title -like "*$mainWindowTitle*"
    if ($isMainWindow) {
        if (!(Test-ChatUi -Window $current)) {
            throw "메인창을 채팅창으로 오인했습니다. Stage=$Stage window=$(Format-Window -Window $current)"
        }
    } elseif (!(Is-TargetTitle -Title $current.Title)) {
        throw "대상 채팅방이 아닌 창을 대상으로 잡았습니다. Stage=$Stage target='$chatTitle' window=$(Format-Window -Window $current)"
    }

    return $current
}

function Get-CoordinateInputRegion {
    param($WindowRect)

    $left = [int]($WindowRect.Left + 14)
    $top = [int]($WindowRect.Bottom - 95)
    $width = [int]([Math]::Max(120, $WindowRect.Width - 102))
    $height = 78

    [PSCustomObject]@{
        Left = $left
        Top = $top
        Width = $width
        Height = $height
        Right = $left + $width
        Bottom = $top + $height
    }
}

function Capture-ScreenRegionBitmap {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Width,
        [int]$Height
    )

    if ($Width -le 0 -or $Height -le 0) {
        throw "화면 캡처 영역이 비정상입니다. left=$Left top=$Top width=$Width height=$Height"
    }

    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($Left, $Top, 0, 0, $bitmap.Size)
    } finally {
        $graphics.Dispose()
    }

    $bitmap
}

function Compare-BitmapChange {
    param(
        [System.Drawing.Bitmap]$Before,
        [System.Drawing.Bitmap]$After,
        [int]$Stride = 3,
        [int]$ColorDeltaThreshold = 45
    )

    if (!$Before -or !$After -or $Before.Width -ne $After.Width -or $Before.Height -ne $After.Height) {
        throw "비교할 화면 캡처 크기가 서로 다릅니다."
    }

    $changed = 0
    $total = 0
    $sumDelta = 0

    for ($y = 0; $y -lt $Before.Height; $y += $Stride) {
        for ($x = 0; $x -lt $Before.Width; $x += $Stride) {
            $beforePixel = $Before.GetPixel($x, $y)
            $afterPixel = $After.GetPixel($x, $y)
            $delta = [Math]::Abs([int]$beforePixel.R - [int]$afterPixel.R) +
                [Math]::Abs([int]$beforePixel.G - [int]$afterPixel.G) +
                [Math]::Abs([int]$beforePixel.B - [int]$afterPixel.B)

            if ($delta -ge $ColorDeltaThreshold) {
                $changed++
            }

            $sumDelta += $delta
            $total++
        }
    }

    [PSCustomObject]@{
        ChangedSamples = $changed
        TotalSamples = $total
        ChangedRatio = if ($total -gt 0) { $changed / $total } else { 0 }
        AverageDelta = if ($total -gt 0) { $sumDelta / $total } else { 0 }
    }
}

function Assert-ScreenRegionChanged {
    param(
        [System.Drawing.Bitmap]$Before,
        [System.Drawing.Bitmap]$After,
        [string]$Stage,
        [int]$MinChangedSamples = 35,
        [double]$MinChangedRatio = 0.006
    )

    $diff = Compare-BitmapChange -Before $Before -After $After
    Write-Log ("Screen region change check [{0}]: changed={1}/{2} ratio={3:N4} avgDelta={4:N2}" -f $Stage, $diff.ChangedSamples, $diff.TotalSamples, $diff.ChangedRatio, $diff.AverageDelta)

    if ($diff.ChangedSamples -lt $MinChangedSamples -or $diff.ChangedRatio -lt $MinChangedRatio) {
        throw "좌표 fallback 검증 실패[$Stage]: 입력 영역 변화가 너무 작아 실제 입력/전송으로 인정하지 않습니다."
    }
}

function Send-HiworksMessageByCoordinates {
    param([object]$ChatWindow)

    $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "coordinate-start"

    if ($ChatWindow.Title -notlike "*$mainWindowTitle*") {
        $ChatWindow = Move-ChatWindowFixed -Window $ChatWindow
        $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "coordinate-after-move"
    }

    Show-And-Focus -Hwnd $ChatWindow.Hwnd
    $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "coordinate-before-input"
    $rect = Get-WindowRectObject -Hwnd $ChatWindow.Hwnd
    $inputRegion = Get-CoordinateInputRegion -WindowRect $rect
    $inputX = [int]($inputRegion.Left + [Math]::Min(100, [Math]::Max(40, $inputRegion.Width * 0.35)))
    $inputY = [int]($inputRegion.Top + [Math]::Min(34, [Math]::Max(20, $inputRegion.Height / 2)))
    $sendX = [int]($rect.Right - 34)
    $sendY = [int]($rect.Bottom - 58)

    Write-Log ("Coordinate send target: title='{0}', x={1}, y={2}, w={3}, h={4}" -f $ChatWindow.Title, $rect.Left, $rect.Top, $rect.Width, $rect.Height)
    Write-Log ("Coordinate send input: x={0}, y={1}; send: x={2}, y={3}" -f $inputX, $inputY, $sendX, $sendY)
    Write-Log ("Coordinate verification region: x={0}, y={1}, w={2}, h={3}" -f $inputRegion.Left, $inputRegion.Top, $inputRegion.Width, $inputRegion.Height)

    if ($DryRun) {
        Write-Log "[OK] Dry run completed by coordinate fallback without sending"
        Save-Screenshot -Step "dryrun_coordinate" | Out-Null
        return
    }

    if ($ChatWindow.Title -like "*$mainWindowTitle*") {
        throw "Coordinate fallback refused on main Hiworks window."
    }

    Write-Log "[WARN] UIA input verification unavailable; sending by coordinates after target window validation"

    $beforePaste = $null
    $afterPaste = $null
    $afterSend = $null

    Click-Point -X $inputX -Y $inputY
    Start-Sleep -Milliseconds 250
    $activeAfterInputClick = Get-WindowObjectByHwnd -Hwnd ([HiworksAutoNative]::GetForegroundWindow())
    if (!$activeAfterInputClick -or $activeAfterInputClick.Hwnd -ne $ChatWindow.Hwnd) {
        throw ("Coordinate fallback focus check failed before paste. active={0}" -f (Format-Window -Window $activeAfterInputClick))
    }

    try {
        $beforePaste = Capture-ScreenRegionBitmap -Left $inputRegion.Left -Top $inputRegion.Top -Width $inputRegion.Width -Height $inputRegion.Height
        Send-TextToActiveWindow -Text $message
        Start-Sleep -Milliseconds 450
        $afterPaste = Capture-ScreenRegionBitmap -Left $inputRegion.Left -Top $inputRegion.Top -Width $inputRegion.Width -Height $inputRegion.Height
        Save-Screenshot -Step "after_paste_coordinate" | Out-Null
        Assert-ScreenRegionChanged -Before $beforePaste -After $afterPaste -Stage "coordinate-paste"

        $activeAfterPaste = Get-WindowObjectByHwnd -Hwnd ([HiworksAutoNative]::GetForegroundWindow())
        if (!$activeAfterPaste -or $activeAfterPaste.Hwnd -ne $ChatWindow.Hwnd) {
            throw ("Coordinate fallback focus check failed after paste. active={0}" -f (Format-Window -Window $activeAfterPaste))
        }

        Write-SendStage -Method 'coordinate'
        Click-Point -X $sendX -Y $sendY
        Start-Sleep -Milliseconds 900
        $afterSend = Capture-ScreenRegionBitmap -Left $inputRegion.Left -Top $inputRegion.Top -Width $inputRegion.Width -Height $inputRegion.Height
        Save-Screenshot -Step "after_send_coordinate" | Out-Null
        Assert-ScreenRegionChanged -Before $afterPaste -After $afterSend -Stage "coordinate-send"
        Write-Log "[OK] Message send action completed by coordinate fallback with screen-region verification"
    } finally {
        if ($beforePaste) {
            $beforePaste.Dispose()
        }
        if ($afterPaste) {
            $afterPaste.Dispose()
        }
        if ($afterSend) {
            $afterSend.Dispose()
        }
    }
}

function Send-HiworksMessage {
    param([object]$ChatWindow)

    $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "send-start"

    if ($ChatWindow.Hwnd -ne [IntPtr]::Zero -and $ChatWindow.Title -notlike "*$mainWindowTitle*") {
        $ChatWindow = Move-ChatWindowFixed -Window $ChatWindow
        $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "send-after-move"
    }

    Show-And-Focus -Hwnd $ChatWindow.Hwnd
    $ChatWindow = Get-WindowObjectByHwnd -Hwnd $ChatWindow.Hwnd
    $ChatWindow = Assert-TargetChatWindowUsable -Window $ChatWindow -Stage "send-before-uia"
    Write-Log ("Chat window ready: {0}" -f (Format-Window -Window $ChatWindow))
    Save-Screenshot -Step "chat_fixed" | Out-Null

    $parts = $null
    try {
        $parts = Get-ChatInputAndSendButton -Window $ChatWindow
    } catch {
        Write-Log "Chat UI lookup failed; using coordinate send fallback: $($_.Exception.Message)"
        Send-HiworksMessageByCoordinates -ChatWindow $ChatWindow
        return
    }

    if (!$parts.Input -or !$parts.SendButton) {
        Write-Log "Chat input or send button not found by UIA; using coordinate send fallback"
        Send-HiworksMessageByCoordinates -ChatWindow $ChatWindow
        return
    }

    $inputRect = $parts.Input.Current.BoundingRectangle
    $sendRect = $parts.SendButton.Current.BoundingRectangle
    $inputX = [int]($inputRect.X + ($inputRect.Width / 2))
    $inputY = [int]($inputRect.Y + ($inputRect.Height / 2))
    Write-Log ("Input element: x={0}, y={1}, w={2}, h={3}, class='{4}'" -f [int]$inputRect.X, [int]$inputRect.Y, [int]$inputRect.Width, [int]$inputRect.Height, $parts.Input.Current.ClassName)
    Write-Log ("Send button: x={0}, y={1}, w={2}, h={3}, name='{4}'" -f [int]$sendRect.X, [int]$sendRect.Y, [int]$sendRect.Width, [int]$sendRect.Height, $parts.SendButton.Current.Name)

    if ($DryRun) {
        Write-Log "[OK] Dry run completed without sending"
        Save-Screenshot -Step "dryrun_uia" | Out-Null
        return
    }

    try {
        $parts.Input.SetFocus()
    } catch {
    }
    Click-Point -X $inputX -Y $inputY
    Start-Sleep -Milliseconds 250
    Send-TextToActiveWindow -Text $message
    Save-Screenshot -Step "after_paste_uia" | Out-Null
    Assert-MessageTextInInput -InputElement $parts.Input -ExpectedMessage $message

    Write-SendStage -Method 'uia'
    $invokePattern = $null
    if ($parts.SendButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        $invokePattern.Invoke()
    } else {
        $sendX = [int]($sendRect.X + ($sendRect.Width / 2))
        $sendY = [int]($sendRect.Y + ($sendRect.Height / 2))
        Click-Point -X $sendX -Y $sendY
    }
    Start-Sleep -Milliseconds 900
    Save-Screenshot -Step "after_send_uia" | Out-Null
    Assert-MessageClearedFromInput -InputElement $parts.Input -ExpectedMessage $message
    Write-Log "[OK] Message send action completed"
}

try {
    Write-Log "=============================================="
    Write-Log "Hiworks UIA message sender started. Label=$MessageLabel DryRun=$DryRun"
    Write-Log "Target chat title: $chatTitle / search: $searchQuery / result: $searchResultQuery"
    Write-Log "Expected account: $ExpectedAccountName"
    Write-Log "Fixed layout: main=($MainX,$MainY,$MainWidth,$MainHeight), chat=($ChatX,$ChatY,$ChatWidth,$ChatHeight)"
    Write-Log "Message length: $($message.Length)"
    Ensure-HiworksProcess
    $chatWindow = Ensure-TargetChatWindow
    Send-HiworksMessage -ChatWindow $chatWindow
    exit 0
} catch {
    Write-Log "[ERROR] $($_.Exception.Message)"
    Save-Screenshot -Step "error" | Out-Null
    exit 1
}








