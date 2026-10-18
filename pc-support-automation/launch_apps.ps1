# 2026-10-17 QA 반영:
#  - AutoHotkey 는 remote_support.ahk 를 실행 중인 인스턴스가 있을 때만 '이미 실행 중'으로 판단
#  - v1 AutoHotkey 대체 실행 제거 (remote_support.ahk 는 v2 전용 — v1 로 띄우면 정상 동작 안 함)
#  - 필수 단계 실패가 하나라도 있으면 exit 1 (작업 스케줄러에서 실패로 보이게)
#  - v5: 모든 Start-Process 를 -ErrorAction Stop + catch 로 (비종료 오류가 성공 로그로 끝나지 않게)
#  - 출근 큐는 별도 예약 작업 'Hiworks Greeting Queue 1248' 이 실행 (앱 실행 지연·오류·마커 모드와 분리)

# 로그 파일 경로
$logFile = "C:\Scripts\logs\launch_apps.log"
$script:launchErrors = 0

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

# 로그 시작
Write-Log "=============================================="
Write-Log "Program Launch Started"
Write-Log "=============================================="

$markerPath = "C:\Scripts\hiworks_marker_request.json"
if (Test-Path -LiteralPath $markerPath) {
    $markerLogFile = "C:\Scripts\logs\hiworks_marker_task.log"
    function Write-MarkerLog {
        param([string]$Message)
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $markerLogFile -Value "[$timestamp] $Message" -Encoding UTF8
        Write-Log "[MARKER] $Message"
    }

    $runId = Get-Date -Format "yyyyMMdd_HHmmss"
    $runningPath = "C:\Scripts\logs\hiworks_marker_request_$runId.running.json"
    $defaultResultPath = "C:\Scripts\logs\hiworks_marker_result_$runId.json"
    $resultPath = $defaultResultPath
    $exitCode = 1

    try {
        Write-MarkerLog "Marker request detected: $markerPath"
        $request = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($request.ResultPath) {
            $resultPath = [string]$request.ResultPath
        }

        Move-Item -LiteralPath $markerPath -Destination $runningPath -Force
        Write-MarkerLog "Marker request moved to: $runningPath"

        $scriptPath = [string]$request.Script
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or !(Test-Path -LiteralPath $scriptPath)) {
            throw "Marker script not found: $scriptPath"
        }

        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $scriptPath
        )

        if ($request.Arguments) {
            foreach ($argument in @($request.Arguments)) {
                $arguments += [string]$argument
            }
        }

        Write-MarkerLog "Running marker script: $scriptPath"
        & powershell.exe @arguments
        $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        Write-MarkerLog "Marker script exited with code: $exitCode"

        [PSCustomObject]@{
            RunId = $runId
            StartedBy = "Launch Apps 1250"
            Script = $scriptPath
            Arguments = @($request.Arguments)
            ExitCode = $exitCode
            CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            RunningRequestPath = $runningPath
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding UTF8

        Write-MarkerLog "Marker result saved: $resultPath"
        Write-MarkerLog "Normal launch flow skipped because marker mode was used."
        exit $exitCode
    } catch {
        Write-MarkerLog "[ERROR] Marker request failed: $($_.Exception.Message)"
        [PSCustomObject]@{
            RunId = $runId
            StartedBy = "Launch Apps 1250"
            ExitCode = 1
            Error = $_.Exception.Message
            CompletedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            RunningRequestPath = if (Test-Path -LiteralPath $runningPath) { $runningPath } else { $null }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        exit 1
    }
}

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
# 1. 하이웍스 메신저 실행
Write-Log "Trying to launch Hiworks Messenger..."
$hiworksPath = "C:\Program Files (x86)\Hiworks\Messenger\HiworksMessenger.exe"
if (Test-Path $hiworksPath) {
    $process = Get-Process -Name "HiworksMessenger" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] Hiworks Messenger is already running"
    } else {
        try {
            Start-Process -FilePath $hiworksPath -ErrorAction Stop
            Write-Log "[OK] Hiworks Messenger launched"
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "[ERROR] Failed to launch Hiworks Messenger: $($_.Exception.Message)"
            $script:launchErrors++
        }
    }
} else {
    Write-Log "[ERROR] Hiworks Messenger not found at: $hiworksPath"
    $script:launchErrors++
}

# 2. LDPlayer 실행
Write-Log "Trying to launch LDPlayer..."
$ldplayerPath = "C:\LDPlayer\LDPlayer9\dnplayer.exe"
if (Test-Path $ldplayerPath) {
    $process = Get-Process -Name "dnplayer" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] LDPlayer is already running"
    } else {
        try {
            Start-Process -FilePath $ldplayerPath -ErrorAction Stop
            Write-Log "[OK] LDPlayer launched"
            Start-Sleep -Seconds 3
        } catch {
            Write-Log "[ERROR] Failed to launch LDPlayer: $($_.Exception.Message)"
            $script:launchErrors++
        }
    }
} else {
    Write-Log "[ERROR] LDPlayer not found at: $ldplayerPath"
    $script:launchErrors++
}

# 3. AnySupport 실행
Write-Log "Trying to launch AnySupport..."
$anysupportPath = "C:\Program Files (x86)\Koino\AnySupport10\AutoPatcher.exe"
if (Test-Path $anysupportPath) {
    $process = Get-Process -Name "KoinoSupporter" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] AnySupport is already running"
    } else {
        try {
            Start-Process -FilePath $anysupportPath -ErrorAction Stop
            Write-Log "[OK] AnySupport launched"
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "[ERROR] Failed to launch AnySupport: $($_.Exception.Message)"
            $script:launchErrors++
        }
    }
} else {
    Write-Log "[ERROR] AnySupport not found at: $anysupportPath"
    $script:launchErrors++
}

# 4. 휴대폰 연결 앱 실행
Write-Log "Trying to launch YourPhone..."
try {
    Start-Process "shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App" -ErrorAction Stop
    Write-Log "[OK] YourPhone launched"
    Start-Sleep -Seconds 2
} catch {
    Write-Log "[ERROR] Failed to launch YourPhone: $($_.Exception.Message)"
    $script:launchErrors++
}

# 5. LMS 사이트 열기 및 로그인 칸 자동 입력은 전용 작업에서 처리
Write-Log "[SKIP] Lms prefill is handled by the dedicated 'Open Lms Extra Prefill Weekdays' task."

# 6. AutoHotkey 스크립트 실행
Write-Log "Trying to launch AutoHotkey script..."
$ahkScriptPath = "C:\Scripts\remote_support.ahk"
$ahkExePath = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

if (Test-Path $ahkScriptPath) {
    $workAhkRunning = $false
    try {
        $workAhkRunning = [bool](Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction Stop |
            Where-Object { [string]$_.CommandLine -like "*remote_support.ahk*" } |
            Select-Object -First 1)
    } catch {
        Write-Log "[WARN] Could not inspect AutoHotkey command lines: $($_.Exception.Message)"
    }

    if ($workAhkRunning) {
        Write-Log "[SKIP] remote_support.ahk is already running"
    } elseif (Test-Path $ahkExePath) {
        try {
            Start-Process -FilePath $ahkExePath -ArgumentList "`"$ahkScriptPath`"" -ErrorAction Stop
            Write-Log "[OK] AutoHotkey script launched (v2)"
        } catch {
            Write-Log "[ERROR] Failed to launch AutoHotkey script: $($_.Exception.Message)"
            $script:launchErrors++
        }
    } else {
        Write-Log "[ERROR] AutoHotkey v2 not found at: $ahkExePath (remote_support.ahk requires v2)"
        $script:launchErrors++
    }
} else {
    Write-Log "[ERROR] AutoHotkey script not found at: $ahkScriptPath"
    $script:launchErrors++
}


# 7. 하이웍스 출근 인사는 별도 예약 작업 'Hiworks Greeting Queue 1248' 이 처리 (12:50~13:00 발송)
Write-Log "[SKIP] Greeting queue runs as its own scheduled task (Hiworks Greeting Queue 1248)."

# 8. 퇴근 메시지는 19:00 작업 내부에서 최대 3회 재시도
Write-Log "Skipping Hiworks end message queue; Task Scheduler starts it at 19:00 with internal retries."

if ($script:launchErrors -gt 0) {
    Write-Log "[ERROR] Launch finished with $($script:launchErrors) failure(s)"
    Write-Log ""
    exit 1
}
Write-Log "All programs launch completed!"
Write-Log ""
exit 0

