param(
    [switch]$DryRun,
    # 시간 가드 무시 (근무 중 수동 종료가 꼭 필요할 때만 명시적으로 사용)
    [switch]$Force
)

# 2026-10-17 QA 반영:
#  - 시간 가드: 평일 19:09~23:59 에만 자동 종료. 그 외(근무 중 실행, 다음 날 지연 실행)는 -Force 없이는 종료하지 않음.
#    (작업의 '예약 시간을 놓치면 가능한 빨리 실행' 설정 때문에 다음 날 아침/근무 중에 실행될 수 있음)
#  - AutoHotkey 는 remote_support.ahk 를 실행 중인 인스턴스만 종료 (다른 AHK 는 건드리지 않음)
#  - Lms Chrome 창 닫기를 PostMessage(비동기)로 변경 — 응답 없는 창에서 스크립트가 멈추지 않게
#  - 종료 실패가 하나라도 있으면 exit 1 (작업 스케줄러에서 실패로 보이게)
#  - 연장 근무 기록(logs\workday_overtime_yyyyMMdd.flag)이 있으면 종료하지 않음 ('연장 퇴근'에서 -Force 로 호출)
#  - v6: 창 닫기 요청(PostMessage) 거절은 실패로 집계, 수락 후에도 창 핸들이 제한 시간 안에 사라지는지 확인 (Lms·휴대폰 연결 창)
$windowCloseVerifySeconds = 10
$closeWindowStartHour = 19; $closeWindowStartMinute = 9
$closeWindowEndHour = 23; $closeWindowEndMinute = 59
$workAhkScriptName = "remote_support.ahk"
$script:closeErrors = 0

# 로그 파일 경로
$logFile = "C:\Scripts\logs\close_apps.log"

# 로그 폴더 생성
if (!(Test-Path "C:\Scripts\logs")) {
    New-Item -ItemType Directory -Path "C:\Scripts\logs" | Out-Null
}

# 로그 함수
function Write-Log {
    param($message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $message"
    Add-Content -Path $logFile -Value $logMessage -Encoding UTF8
}

function Wait-ProcessExitById {
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [int]$TimeoutSeconds = 12
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (!(Get-Process -Id $Id -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return !(Get-Process -Id $Id -ErrorAction SilentlyContinue)
}

function Stop-ProcessesByName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Write-Log "Trying to close $Label..."

    $processes = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Write-Log "[SKIP] $Label not running"
        return
    }

    foreach ($proc in $processes) {
        try {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would close $Label (PID: $($proc.Id))"
                continue
            }

            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            if (Wait-ProcessExitById -Id $proc.Id -TimeoutSeconds 12) {
                Write-Log "[OK] $Label closed (PID: $($proc.Id))"
            } else {
                Write-Log "[WARN] $Label still visible after first close request; retrying (PID: $($proc.Id))"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                if (Wait-ProcessExitById -Id $proc.Id -TimeoutSeconds 8) {
                    Write-Log "[OK] $Label closed after retry (PID: $($proc.Id))"
                } else {
                    Write-Log "[ERROR] $Label still running after retry (PID: $($proc.Id))"
                    $script:closeErrors++
                }
            }
        } catch {
            if (!(Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
                Write-Log "[OK] $Label already exited (PID: $($proc.Id))"
            } else {
                Write-Log "[ERROR] Failed to close $Label (PID: $($proc.Id)): $($_.Exception.Message)"
                $script:closeErrors++
            }
        }
    }
}

# 로그 시작
Write-Log "=============================================="
Write-Log "Program Close Started. DryRun=$DryRun"
Write-Log "=============================================="

$holidayFile = "C:\Scripts\hiworks_holidays.txt"

function Get-HiworksHolidayReason {
    param([datetime]$Date)

    if (!(Test-Path -LiteralPath $holidayFile)) {
        return $null
    }

    $dateText = $Date.ToString("yyyy-MM-dd")
    $lines = Get-Content -LiteralPath $holidayFile -Encoding UTF8
    foreach ($line in $lines) {
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

    $null
}

function Initialize-CloseAppsWindowTools {
    if (-not ("CloseAppsWindowTools" -as [type])) {
        Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class CloseAppsWindowInfo {
    public long HandleValue;
    public int ProcessId;
    public string Title;
}

public class CloseAppsWindowTools {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    public static bool WindowExists(long handleValue) {
        return IsWindow(new IntPtr(handleValue));
    }

    private const uint WM_CLOSE = 0x0010;

    public static CloseAppsWindowInfo[] GetVisibleWindows() {
        var windows = new List<CloseAppsWindowInfo>();
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

            windows.Add(new CloseAppsWindowInfo {
                HandleValue = hWnd.ToInt64(),
                ProcessId = (int)processId,
                Title = title.ToString()
            });

            return true;
        }, IntPtr.Zero);

        return windows.ToArray();
    }

    public static void CloseWindow(long handleValue) {
        SendMessage(new IntPtr(handleValue), WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool PostCloseWindow(long handleValue) {
        return PostMessage(new IntPtr(handleValue), WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }
}
"@
    }
}

# 닫기 요청 후 창 핸들이 사라졌는지 확인. 사라지면 $true
function Wait-WindowGone {
    param([long]$HandleValue, [int]$TimeoutSeconds = $windowCloseVerifySeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not [CloseAppsWindowTools]::WindowExists($HandleValue)) { return $true }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return (-not [CloseAppsWindowTools]::WindowExists($HandleValue))
}

function Close-PhoneLinkWindows {
    Write-Log "Trying to close leftover Phone Link windows..."

    $closedCount = 0
    $targetTitles = @("휴대폰 화면", "휴대폰과 연결")

    try {
        Initialize-CloseAppsWindowTools
        $windows = @([CloseAppsWindowTools]::GetVisibleWindows() | Where-Object { $targetTitles -contains $_.Title })

        foreach ($window in $windows) {
            $ownerName = "unknown"
            try {
                $ownerName = (Get-Process -Id $window.ProcessId -ErrorAction Stop).ProcessName
            } catch {}

            if ($DryRun) {
                Write-Log "[DRYRUN] Would send close to Phone Link window: $($window.Title) (owner: $ownerName, PID: $($window.ProcessId))"
                $closedCount++
                continue
            }

            # PostMessage: 멈춘 창이어도 스크립트가 대기하지 않음. 요청 후 창 소멸까지 확인
            if (-not [CloseAppsWindowTools]::PostCloseWindow([long]$window.HandleValue)) {
                Write-Log "[ERROR] Close request refused for Phone Link window: $($window.Title) (owner: $ownerName, PID: $($window.ProcessId))"
                $script:closeErrors++
            } elseif (Wait-WindowGone -HandleValue ([long]$window.HandleValue)) {
                Write-Log "[OK] Phone Link window closed: $($window.Title) (owner: $ownerName, PID: $($window.ProcessId))"
            } else {
                Write-Log "[ERROR] Phone Link window still open ${windowCloseVerifySeconds}s after close request: $($window.Title)"
                $script:closeErrors++
            }
            $closedCount++
        }
    } catch {
        Write-Log "[ERROR] Failed to close Phone Link windows: $($_.Exception.Message)"
        $script:closeErrors++
    }

    if ($closedCount -eq 0) {
        Write-Log "[SKIP] Phone Link window not found"
    }
}

function Close-LmsChromeWindow {
    Write-Log "Trying to close Lms Chrome window..."

    $closedCount = 0

    try {
        $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/list" -TimeoutSec 2 -ErrorAction Stop)
        foreach ($target in $targets) {
            if ($target.type -eq "page" -and $target.url -match "extra\.lms\.co\.kr") {
                try {
                    if ($DryRun) {
                        Write-Log "[DRYRUN] Would close Lms Chrome target via remote debugging: $($target.url)"
                        $closedCount++
                        continue
                    }

                    Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/close/$($target.id)" -TimeoutSec 2 -ErrorAction Stop | Out-Null
                    Write-Log "[OK] Closed Lms Chrome target via remote debugging: $($target.url)"
                    $closedCount++
                } catch {
                    Write-Log "[WARN] Failed to close Lms Chrome target via remote debugging: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "[INFO] Chrome remote debugging on port 9222 is not available; trying window-title close"
    }

    Initialize-CloseAppsWindowTools

    try {
        $windows = @([CloseAppsWindowTools]::GetVisibleWindows())
        $lmsWindows = @(
            $windows | Where-Object {
                try {
                    $process = Get-Process -Id $_.ProcessId -ErrorAction Stop
                    $process.ProcessName -eq "chrome" -and $_.Title -match "ExtraNet|Lms|lms|extra\.lms"
                } catch {
                    $false
                }
            }
        )

        foreach ($window in $lmsWindows) {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would send close to Lms Chrome window: $($window.Title)"
                $closedCount++
                continue
            }

            # PostMessage: 응답 없는 Chrome 창이어도 스크립트가 대기하지 않음. 요청 후 창 소멸까지 확인
            if (-not [CloseAppsWindowTools]::PostCloseWindow([long]$window.HandleValue)) {
                Write-Log "[ERROR] Close request refused for Lms Chrome window: $($window.Title)"
                $script:closeErrors++
            } elseif (Wait-WindowGone -HandleValue ([long]$window.HandleValue)) {
                Write-Log "[OK] Lms Chrome window closed: $($window.Title)"
            } else {
                Write-Log "[ERROR] Lms Chrome window still open ${windowCloseVerifySeconds}s after close request: $($window.Title)"
                $script:closeErrors++
            }
            $closedCount++
        }
    } catch {
        Write-Log "[ERROR] Failed to close Lms Chrome window by title: $($_.Exception.Message)"
        $script:closeErrors++
    }

    if ($closedCount -eq 0) {
        Write-Log "[SKIP] Lms Chrome window not found"
    }
}

$now = Get-Date
$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
if ($weekday -notcontains $now.DayOfWeek.ToString()) {
    Write-Log "[SKIP] Today is not a weekday: $($now.DayOfWeek)"
    exit 0
}

$holidayReason = Get-HiworksHolidayReason -Date $now.Date
if ($holidayReason) {
    Write-Log "[SKIP] Today is configured holiday: $($now.ToString('yyyy-MM-dd')) $holidayReason"
    exit 0
}

$closeWindowStart = $now.Date.AddHours($closeWindowStartHour).AddMinutes($closeWindowStartMinute)
$closeWindowEnd = $now.Date.AddHours($closeWindowEndHour).AddMinutes($closeWindowEndMinute).AddSeconds(59)
if ($now -lt $closeWindowStart -or $now -gt $closeWindowEnd) {
    if ($Force) {
        Write-Log "[WARN] Outside close window ($($closeWindowStart.ToString('HH:mm'))~$($closeWindowEnd.ToString('HH:mm'))) at $($now.ToString('HH:mm:ss')), but -Force given; closing"
    } else {
        Write-Log "[SKIP] Outside close window ($($closeWindowStart.ToString('HH:mm'))~$($closeWindowEnd.ToString('HH:mm'))): $($now.ToString('HH:mm:ss')). Not closing work apps. Use -Force for a manual close."
        exit 0
    }
}
$overtimeFlag = Join-Path "C:\Scripts\logs" ("workday_overtime_{0}.flag" -f $now.ToString("yyyyMMdd"))
if ((Test-Path -LiteralPath $overtimeFlag) -and -not $Force) {
    Write-Log "[SKIP] Overtime mode is on today ($overtimeFlag). Work apps stay open; use the '연장 퇴근' shortcut when done."
    exit 0
}
Write-Log "Closing Hiworks and related apps now."
# 0. 퇴근 메시지는 19:00 작업과 내부 재시도에서 처리
Write-Log "Skipping Hiworks end message send here; the end-message task handles retries before close."

# 1. 하이웍스 메신저 종료
Stop-ProcessesByName -Name "HiworksMessenger" -Label "Hiworks Messenger"

# 2. LDPlayer 종료
Stop-ProcessesByName -Name "dnplayer" -Label "LDPlayer"

# 3. AnySupport 종료
Stop-ProcessesByName -Name "KoinoSupporter" -Label "AnySupport"

# 4. 휴대폰 연결 앱 종료
Stop-ProcessesByName -Name "PhoneExperienceHost" -Label "YourPhone (PhoneExperienceHost)"

Stop-ProcessesByName -Name "YourPhoneAppProxy" -Label "YourPhone (YourPhoneAppProxy)"

# 4-1. 프로세스 종료 후에도 남는 휴대폰 창(휴대폰 화면 등) 닫기 - 클릭하면 앱이 재실행되므로 창 자체를 닫음
Close-PhoneLinkWindows

# 5. Lms Chrome 창만 종료
Close-LmsChromeWindow

# 6. AutoHotkey 종료 — 업무용(remote_support.ahk) 인스턴스만
Write-Log "Trying to close AutoHotkey ($workAhkScriptName only)..."
$processes = @()
try {
    $ahkIds = @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction Stop |
        Where-Object { [string]$_.CommandLine -like "*$workAhkScriptName*" } |
        ForEach-Object { [int]$_.ProcessId })
    foreach ($ahkOther in @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction Stop |
        Where-Object { [string]$_.CommandLine -notlike "*$workAhkScriptName*" })) {
        Write-Log "[SKIP] Leaving non-work AutoHotkey alive (PID: $($ahkOther.ProcessId))"
    }
    if ($ahkIds.Count -gt 0) {
        $processes = @(Get-Process -Id $ahkIds -ErrorAction SilentlyContinue)
    }
} catch {
    Write-Log "[ERROR] Could not inspect AutoHotkey command lines; not closing any AutoHotkey: $($_.Exception.Message)"
    $script:closeErrors++
}

if ($processes) {
    foreach ($proc in $processes) {
        try {
            if ($DryRun) {
                Write-Log "[DRYRUN] Would close AutoHotkey (PID: $($proc.Id))"
                continue
            }

            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            if (Wait-ProcessExitById -Id $proc.Id -TimeoutSeconds 12) {
                Write-Log "[OK] AutoHotkey closed (PID: $($proc.Id))"
            } else {
                Write-Log "[WARN] AutoHotkey still visible after first close request; retrying (PID: $($proc.Id))"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                if (Wait-ProcessExitById -Id $proc.Id -TimeoutSeconds 8) {
                    Write-Log "[OK] AutoHotkey closed after retry (PID: $($proc.Id))"
                } else {
                    Write-Log "[ERROR] AutoHotkey still running after retry (PID: $($proc.Id))"
                    $script:closeErrors++
                }
            }
        } catch {
            if (!(Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
                Write-Log "[OK] AutoHotkey already exited (PID: $($proc.Id))"
            } else {
                Write-Log "[ERROR] Failed to close AutoHotkey: $($_.Exception.Message)"
                $script:closeErrors++
            }
        }
    }
} else {
    Write-Log "[SKIP] Work AutoHotkey not running"
}


if ($script:closeErrors -gt 0) {
    Write-Log "[ERROR] Close finished with $($script:closeErrors) failure(s)"
    Write-Log ""
    exit 1
}
Write-Log "All programs closed!"
Write-Log ""
exit 0


