# ============================================================
# close_apps.ps1 — 업무 종료 시 앱 자동 종료
# Windows 작업 스케줄러에 등록하여 퇴근 시간에 자동 실행
# ============================================================

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

# 로그 시작
Write-Log "=============================================="
Write-Log "Program Close Started"
Write-Log "=============================================="

# 1. 사내 메신저 종료
Write-Log "Trying to close Company Messenger..."
$process = Get-Process -Name "Messenger" -ErrorAction SilentlyContinue  # ← 실제 프로세스명으로 변경
if ($process) {
    Stop-Process -Name "Messenger" -Force
    Write-Log "[OK] Company Messenger closed"
} else {
    Write-Log "[SKIP] Company Messenger not running"
}

# 2. 모바일 에뮬레이터 종료
Write-Log "Trying to close Mobile Emulator..."
$process = Get-Process -Name "emulator" -ErrorAction SilentlyContinue  # ← 실제 프로세스명으로 변경
if ($process) {
    Stop-Process -Name "emulator" -Force
    Write-Log "[OK] Mobile Emulator closed"
} else {
    Write-Log "[SKIP] Mobile Emulator not running"
}

# 3. 원격지원 도구 종료
Write-Log "Trying to close Remote Support Tool..."
$process = Get-Process -Name "RemoteTool" -ErrorAction SilentlyContinue  # ← 실제 프로세스명으로 변경
if ($process) {
    Stop-Process -Name "RemoteTool" -Force
    Write-Log "[OK] Remote Support Tool closed"
} else {
    Write-Log "[SKIP] Remote Support Tool not running"
}

# 4. 휴대폰 연결 앱 종료
Write-Log "Trying to close Phone Link (PhoneExperienceHost)..."
$process = Get-Process -Name "PhoneExperienceHost" -ErrorAction SilentlyContinue
if ($process) {
    Stop-Process -Name "PhoneExperienceHost" -Force
    Write-Log "[OK] PhoneExperienceHost closed"
} else {
    Write-Log "[SKIP] PhoneExperienceHost not running"
}

Write-Log "Trying to close Phone Link (YourPhoneAppProxy)..."
$process = Get-Process -Name "YourPhoneAppProxy" -ErrorAction SilentlyContinue
if ($process) {
    Stop-Process -Name "YourPhoneAppProxy" -Force
    Write-Log "[OK] YourPhoneAppProxy closed"
} else {
    Write-Log "[SKIP] YourPhoneAppProxy not running"
}

# 5. Chrome은 종료하지 않음 (세션 유지 → 다음 날 자동 로그인)
Write-Log "Keeping Chrome open (session maintained for work portal)"
Write-Log "[SKIP] Chrome - keeping browser open for next day auto-login"

# 6. AutoHotkey 종료
Write-Log "Trying to close AutoHotkey..."
$processes = Get-Process | Where-Object {
    $_.ProcessName -like "AutoHotkey*"
}

if ($processes) {
    foreach ($proc in $processes) {
        try {
            Stop-Process -Id $proc.Id -Force
            Write-Log "[OK] AutoHotkey closed (PID: $($proc.Id))"
        } catch {
            Write-Log "[ERROR] Failed to close AutoHotkey: $($_.Exception.Message)"
        }
    }
} else {
    Write-Log "[SKIP] AutoHotkey not running"
}

# 7. 알림용 앱 실행 (업무 종료 알림)
Write-Log "Trying to launch notification app..."
$notifyAppPath = "$env:LOCALAPPDATA\Programs\YOUR_APP\app.exe"  # ← 실제 경로로 변경
if (Test-Path $notifyAppPath) {
    $process = Get-Process -Name "app" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] Notification app is already running"
    } else {
        Start-Process -FilePath $notifyAppPath
        Write-Log "[OK] Notification app launched"
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "[ERROR] Notification app not found at: $notifyAppPath"
}

Write-Log "All programs closed!"
Write-Log ""
