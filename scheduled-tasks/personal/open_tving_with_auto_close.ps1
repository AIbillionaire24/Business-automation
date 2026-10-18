param(
    [string]$Url = "https://www.tving.com/live/C01582",
    [int]$DurationMinutes = 100,
    [int]$WindowWaitSeconds = 60,
    [bool]$AutoClickSound = $true,
    [int]$SoundClickDelaySeconds = 10,
    [int]$SoundClickAttempts = 8,
    [int]$SoundClickEverySeconds = 6,
    [double]$SoundClickXRatio = 0.15,
    [double]$SoundClickYRatio = 0.69,
    [string]$ChromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe",
    [string]$TitlePattern = "TVING|티빙|JTBC|모두가 자신의 무가치함과 싸우고 있다",
    [string]$LogFile = ""
)

$ErrorActionPreference = "Continue"

$logDir = Join-Path $env:LOCALAPPDATA "CodexAutomation"
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $logDir "open_tving_with_auto_close.log"
}

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogFile -Value "[$timestamp] $Message" -Encoding UTF8
}

if (!(Test-Path -LiteralPath $ChromePath)) {
    Write-Log "[ERROR] Chrome not found: $ChromePath"
    exit 1
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WindowInfo {
    public IntPtr Handle { get; set; }
    public long HandleValue { get { return Handle.ToInt64(); } }
    public int ProcessId { get; set; }
    public string Title { get; set; }
}

public struct WindowRect {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class WindowTools {
    private const uint WM_CLOSE = 0x0010;
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
    private static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out WindowRect lpRect);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    public static WindowInfo[] GetWindows() {
        var windows = new List<WindowInfo>();
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

            windows.Add(new WindowInfo {
                Handle = hWnd,
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

    public static bool TryClickWindowRatio(long handleValue, double xRatio, double yRatio) {
        var handle = new IntPtr(handleValue);
        ShowWindow(handle, SW_RESTORE);
        SetForegroundWindow(handle);

        WindowRect rect;
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
    [WindowTools]::GetWindows() | Where-Object {
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

Write-Log "=============================================="
Write-Log "TVING auto-close launch started"
Write-Log "Url: $Url"
Write-Log "DurationMinutes: $DurationMinutes"
Write-Log "TitlePattern: $TitlePattern"
Write-Log "AutoClickSound: $AutoClickSound"
Write-Log "=============================================="

$baselineHandles = @{}
foreach ($window in @(Get-ChromeWindows)) {
    $baselineHandles[[string]$window.HandleValue] = $true
}

try {
    Start-Process -FilePath $ChromePath -ArgumentList @("--new-window", $Url) | Out-Null
    Write-Log "[OK] Chrome open requested"
} catch {
    Write-Log "[ERROR] Failed to open Chrome: $($_.Exception.Message)"
    exit 1
}

$targetWindows = @()
$deadline = (Get-Date).AddSeconds($WindowWaitSeconds)
while ((Get-Date) -lt $deadline -and @($targetWindows).Count -eq 0) {
    Start-Sleep -Seconds 2
    $currentWindows = @(Get-ChromeWindows)
    $newWindows = @($currentWindows | Where-Object { !$baselineHandles.ContainsKey([string]$_.HandleValue) })
    $matchingNewWindows = @($newWindows | Where-Object { $_.Title -match $TitlePattern })

    if (@($matchingNewWindows).Count -gt 0) {
        $targetWindows = $matchingNewWindows
        break
    }

    if (@($newWindows).Count -gt 0) {
        $targetWindows = $newWindows
    }
}

if (@($targetWindows).Count -eq 0) {
    $fallbackWindows = @(Get-ChromeWindows | Where-Object { $_.Title -match $TitlePattern })
    if (@($fallbackWindows).Count -gt 0) {
        $targetWindows = $fallbackWindows
        Write-Log "[WARN] Falling back to title-matched existing Chrome windows"
    }
}

if (@($targetWindows).Count -eq 0) {
    Write-Log "[ERROR] Could not identify the TVING Chrome window to close later"
    exit 1
}

$targetHandles = @($targetWindows | Select-Object -ExpandProperty HandleValue -Unique)
Write-Log "[OK] Target Chrome window(s): $(Get-WindowSummary -Windows $targetWindows)"

if ($AutoClickSound) {
    Write-Log "[INFO] Waiting $SoundClickDelaySeconds seconds before sound click attempts"
    Start-Sleep -Seconds $SoundClickDelaySeconds

    for ($attempt = 1; $attempt -le $SoundClickAttempts; $attempt++) {
        foreach ($handle in $targetHandles) {
            try {
                if ([WindowTools]::TryClickWindowRatio([long]$handle, $SoundClickXRatio, $SoundClickYRatio)) {
                    Write-Log "[OK] Sent sound-enable click attempt $attempt to Chrome window handle $handle"
                } else {
                    Write-Log "[WARN] Sound-enable click attempt $attempt failed for Chrome window handle $handle"
                }
            } catch {
                Write-Log "[WARN] Sound-enable click attempt $attempt failed for Chrome window handle $handle`: $($_.Exception.Message)"
            }
        }

        if ($attempt -lt $SoundClickAttempts) {
            Start-Sleep -Seconds $SoundClickEverySeconds
        }
    }
}

$closeAt = (Get-Date).AddMinutes($DurationMinutes)
Write-Log "[INFO] Waiting until $($closeAt.ToString('yyyy-MM-dd HH:mm:ss')) before closing target window(s)"
while ((Get-Date) -lt $closeAt) {
    $remainingSeconds = [Math]::Max(1, [int](($closeAt - (Get-Date)).TotalSeconds))
    Start-Sleep -Seconds ([Math]::Min(30, $remainingSeconds))
}

$closed = 0
foreach ($handle in $targetHandles) {
    try {
        if ([WindowTools]::CloseWindow([long]$handle)) {
            $closed++
            Write-Log "[OK] Sent close message to Chrome window handle $handle"
        } else {
            Write-Log "[WARN] Failed to send close message to Chrome window handle $handle"
        }
    } catch {
        Write-Log "[WARN] Failed to close Chrome window handle $handle`: $($_.Exception.Message)"
    }
}

if ($closed -eq 0) {
    $fallbackWindows = @(Get-ChromeWindows | Where-Object { $_.Title -match $TitlePattern })
    foreach ($window in $fallbackWindows) {
        try {
            if ([WindowTools]::CloseWindow([long]$window.HandleValue)) {
                $closed++
                Write-Log "[OK] Sent fallback close message to Chrome window: $($window.Title)"
            }
        } catch {
            Write-Log "[WARN] Fallback close failed for $($window.Title): $($_.Exception.Message)"
        }
    }
}

Write-Log "TVING auto-close launch completed. ClosedWindows=$closed"
