$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$logFile = Join-Path $logDir "hiworks_end_message_queue.log"
$endLauncherPath = "C:\Scripts\send_hiworks_end_message.ps1"

if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] $Message" -Encoding UTF8
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
Write-Log "Hiworks end message queue started"

if (!(Test-Path $endLauncherPath)) {
    Write-Log "[ERROR] End message launcher not found: $endLauncherPath"
    exit 1
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

# 문구를 골라 기존 메시지 파일을 갱신한다 (실패해도 기존 파일 그대로 사용)
try {
    & "C:\Scripts\hiworks-message.ps1" -Type end -WriteTo "C:\Scripts\hiworks_end_message.txt" | Out-Null
    Write-Log "End message prepared: $((Get-Content -LiteralPath "C:\Scripts\hiworks_end_message.txt" -Raw -Encoding UTF8) -replace "`r?`n", ' / ')"
} catch {
    Write-Log "[WARN] Message picker failed; existing hiworks_end_message.txt will be used: $($_.Exception.Message)"
}

# 19:00 정각 고정을 피하려고 0~8분 흔든다 (19:00 이전 발송은 안 함)
$jitter = Get-Random -Minimum 0 -Maximum 9
$target = $now.Date.AddHours(19).AddMinutes($jitter)
Write-Log "Jitter ${jitter}m -> target $($target.ToString('HH:mm'))"
$latest = $now.Date.AddHours(19).AddMinutes(20)

if ($now -gt $latest) {
    Write-Log "[SKIP] Current time is after the 19:00 end-message window: $($now.ToString('HH:mm:ss'))"
    exit 0
}

$delaySeconds = [Math]::Max(0, [int][Math]::Ceiling(($target - $now).TotalSeconds))
Write-Log "Waiting $delaySeconds seconds until $($target.ToString('HH:mm:ss'))"

if ($delaySeconds -gt 0) {
    Start-Sleep -Seconds $delaySeconds
}

$afterWait = Get-Date
if ($afterWait -gt $latest) {
    Write-Log "[SKIP] Woke up after the 19:00 end-message window: $($afterWait.ToString('HH:mm:ss'))"
    exit 0
}

Write-Log "Running end message launcher"
$arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $endLauncherPath)
& powershell.exe @arguments
$exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
Write-Log "End message launcher finished with exit code: $exitCode"
exit $exitCode
