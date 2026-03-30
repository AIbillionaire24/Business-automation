# ============================================================
# launch_apps.ps1 — 업무 시작 시 앱 자동 실행
# Windows 작업 스케줄러에 등록하여 출근 시간에 자동 실행
# ============================================================

# 로그 파일 경로
$logFile = "C:\Scripts\logs\launch_apps.log"

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

# 1. 사내 메신저 실행
Write-Log "Trying to launch Company Messenger..."
$messengerPath = "C:\Program Files (x86)\YOUR_MESSENGER\Messenger.exe"  # ← 실제 경로로 변경
if (Test-Path $messengerPath) {
    $process = Get-Process -Name "Messenger" -ErrorAction SilentlyContinue  # ← 실제 프로세스명으로 변경
    if ($process) {
        Write-Log "[SKIP] Company Messenger is already running"
    } else {
        Start-Process -FilePath $messengerPath
        Write-Log "[OK] Company Messenger launched"
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "[ERROR] Company Messenger not found at: $messengerPath"
}

# 2. 모바일 에뮬레이터 실행 (모바일 앱 테스트용)
Write-Log "Trying to launch Mobile Emulator..."
$emulatorPath = "C:\Emulator\emulator.exe"  # ← 실제 경로로 변경
if (Test-Path $emulatorPath) {
    $process = Get-Process -Name "emulator" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] Mobile Emulator is already running"
    } else {
        Start-Process -FilePath $emulatorPath
        Write-Log "[OK] Mobile Emulator launched"
        Start-Sleep -Seconds 3
    }
} else {
    Write-Log "[ERROR] Mobile Emulator not found at: $emulatorPath"
}

# 3. 원격지원 도구 실행
Write-Log "Trying to launch Remote Support Tool..."
$remotePath = "C:\Program Files (x86)\YOUR_REMOTE_TOOL\RemoteTool.exe"  # ← 실제 경로로 변경
if (Test-Path $remotePath) {
    $process = Get-Process -Name "RemoteTool" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] Remote Support Tool is already running"
    } else {
        Start-Process -FilePath $remotePath
        Write-Log "[OK] Remote Support Tool launched"
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "[ERROR] Remote Support Tool not found at: $remotePath"
}

# 4. 휴대폰 연결 앱 실행
Write-Log "Trying to launch Phone Link..."
try {
    Start-Process "shell:AppsFolder\Microsoft.YourPhone_8wekyb3d8bbwe!App"
    Write-Log "[OK] Phone Link launched"
    Start-Sleep -Seconds 2
} catch {
    Write-Log "[ERROR] Failed to launch Phone Link: $($_.Exception.Message)"
}

# 5. 업무용 웹사이트 열기 (Chrome)
Write-Log "Opening work website..."
try {
    $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (Test-Path $chromePath) {
        Start-Process -FilePath $chromePath -ArgumentList "https://your-work-portal.example.com/"  # ← 실제 URL로 변경
        Write-Log "[OK] Work website opened"
        Start-Sleep -Seconds 2
    } else {
        Write-Log "[ERROR] Chrome not found"
    }
} catch {
    Write-Log "[ERROR] Failed to open website: $($_.Exception.Message)"
}

# 6. AutoHotkey 업무 자동화 스크립트 실행
Write-Log "Trying to launch AutoHotkey script..."
$ahkScriptPath = "C:\Scripts\remote_support.ahk"
$ahkExePath = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

if (Test-Path $ahkScriptPath) {
    $process = Get-Process -Name "AutoHotkey64","AutoHotkey32","AutoHotkey" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "[SKIP] AutoHotkey script is already running"
    } else {
        if (Test-Path $ahkExePath) {
            Start-Process -FilePath $ahkExePath -ArgumentList "`"$ahkScriptPath`""
            Write-Log "[OK] AutoHotkey script launched (v2)"
        } else {
            $ahkExePathV1 = "C:\Program Files\AutoHotkey\AutoHotkey.exe"
            if (Test-Path $ahkExePathV1) {
                Start-Process -FilePath $ahkExePathV1 -ArgumentList "`"$ahkScriptPath`""
                Write-Log "[OK] AutoHotkey script launched (v1)"
            } else {
                Write-Log "[ERROR] AutoHotkey not found"
            }
        }
    }
} else {
    Write-Log "[ERROR] AutoHotkey script not found at: $ahkScriptPath"
}

# 7. 알림용 앱 실행 (업무 시작 알림)
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

Write-Log "All programs launch completed!"
Write-Log ""
