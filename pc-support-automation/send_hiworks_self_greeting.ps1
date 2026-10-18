param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$SendMessage = "",
    [string]$MessageFile = "",
    [string]$MessageLabel = "start",
    [string]$TargetChatTitle = "동료B2",
    [string]$TargetSearchQuery = "동료B2",
    [string]$TargetSearchResult = "동료B2",
    # 계정 검사 비활성화 (2026-08-18)
    # 하이웍스가 계정명을 UIA 로 노출하지 않아 이 검사는 한 번도 실행된 적이 없다.
    # 로그 전량에서 "Could not detect Hiworks account name" 만 나오고 실제 비교는 못 했다.
    # 담당이 유아->초등으로 바뀌어 옛 값("유아 하이웍스CS")은 이미 틀렸고,
    # 하이웍스가 계정명을 노출하기 시작하는 순간 매일 throw 로 인사말이 멈춘다.
    # 확인되지 않은 이름을 추측해 넣는 대신 검사를 명시적으로 끈다.
    # (uia 850행: 빈 문자열이면 검사를 건너뛴다)
    # 실제 계정명이 로그에 찍히기 시작하면 check-hiworks-health.ps1 이 알려준다.
    [string]$ExpectedAccountName = "",
    [int]$MaxRuntimeSeconds = 0
)

$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$logFile = Join-Path $logDir "hiworks_self_greeting_task.log"
$uiaScriptPath = "C:\Scripts\send_hiworks_self_greeting_uia.ps1"

if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    ($Arguments | ForEach-Object {
        if ($null -eq $_ -or $_ -eq '') {
            # 빈 문자열을 그대로 두면 -join 에서 사라져 뒤 인자가 한 칸씩 밀린다.
            # (-ExpectedAccountName 이 다음 스위치를 값으로 먹어 바인딩 실패)
            '""'
        } elseif ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
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
Write-Log "=============================================="
Write-Log "Hiworks message task started. Label=$MessageLabel DryRun=$DryRun Force=$Force"

$now = Get-Date
$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
$stampFile = Join-Path $logDir ("hiworks_start_message_{0}.sent" -f $now.ToString("yyyyMMdd"))
$shouldUseStartStamp = ($MessageLabel -eq "start")
if (!$DryRun -and !$Force) {
    if ($weekday -notcontains $now.DayOfWeek.ToString()) {
        Write-Log "[SKIP] Today is not a weekday: $($now.DayOfWeek)"
        exit 0
    }

    $holidayReason = Get-HiworksHolidayReason -Date $now.Date
    if ($holidayReason) {
        Write-Log "[SKIP] Today is configured holiday: $($now.ToString('yyyy-MM-dd')) $holidayReason"
        exit 0
    }

    if ($shouldUseStartStamp -and (Test-Path -LiteralPath $stampFile)) {
        Write-Log "[SKIP] Start message already sent today: $stampFile"
        exit 0
    }
}

if (!(Test-Path $uiaScriptPath)) {
    Write-Log "[ERROR] UIAutomation script not found: $uiaScriptPath"
    exit 1
}

try {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $uiaScriptPath,
        "-MessageLabel",
        $MessageLabel,
        "-TargetChatTitle",
        $TargetChatTitle,
        "-TargetSearchQuery",
        $TargetSearchQuery,
        "-TargetSearchResult",
        $TargetSearchResult
    )
    # 계정 검사를 끈 상태(빈 문자열)면 인자 자체를 넘기지 않는다.
    # uia 쪽 기본값도 "" 라 결과는 같고, 빈 인자 전달 위험이 사라진다.
    if (![string]::IsNullOrWhiteSpace($ExpectedAccountName)) {
        $arguments += @("-ExpectedAccountName", $ExpectedAccountName)
    }
    if ($DryRun) {
        $arguments += "-DryRun"
    }
    if (![string]::IsNullOrWhiteSpace($MessageFile)) {
        $arguments += @("-MessageFile", $MessageFile)
    } elseif (![string]::IsNullOrEmpty($SendMessage)) {
        $arguments += @("-SendMessage", $SendMessage)
    }
    if ($MaxRuntimeSeconds -gt 0) {
        $arguments += @("-MaxOpenChatAttempts", "2", "-ChatOpenTimeoutMs", "9000")
    }

    Write-Log "Running UIAutomation script: $uiaScriptPath"
    $childProcess = Start-Process -FilePath "powershell.exe" -ArgumentList (Join-ProcessArguments -Arguments $arguments) -WindowStyle Hidden -PassThru
    if ($MaxRuntimeSeconds -gt 0) {
        Write-Log "UIAutomation hard timeout: ${MaxRuntimeSeconds}s"
        $completed = $childProcess.WaitForExit($MaxRuntimeSeconds * 1000)
        if (!$completed) {
            Write-Log "[ERROR] UIAutomation script timed out after ${MaxRuntimeSeconds}s; killing PID $($childProcess.Id)"
            Stop-Process -Id $childProcess.Id -Force -ErrorAction SilentlyContinue
            exit 124
        }
    } else {
        $childProcess.WaitForExit()
    }
    $childProcess.Refresh()
    $exitCode = $childProcess.ExitCode
    Write-Log "UIAutomation script exited with code: $exitCode"
    if ($exitCode -eq 0 -and !$DryRun -and $shouldUseStartStamp) {
        Set-Content -Path $stampFile -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
        Write-Log "[OK] Start message stamp saved: $stampFile"
    }
    exit $exitCode
} catch {
    Write-Log "[ERROR] Failed to run UIAutomation script: $($_.Exception.Message)"
    exit 1
}
