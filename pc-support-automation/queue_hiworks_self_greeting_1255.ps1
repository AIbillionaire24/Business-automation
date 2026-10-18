# 파일명은 다른 스크립트(launch_apps.ps1 등)가 경로로 참조하므로 1255 그대로 둔다.
# 2026-10-17 v1: 첫 시도 12:50(+지터 0~4분), 실패 시 13:00까지 60초 간격 재시도, 당일 발송 기록, 중복 실행 방지.
# 2026-10-17 v2: 발송기 별도 프로세스 + 시도당 제한 시간, 빈 기록 파일 처리, 문구 선택 제한 시간.
# 2026-10-17 v3 (QA v2 반영):
#   - 시간 초과 시 프로세스 트리를 스냅샷 → 스크립트 호스트만 자식부터 종료 → 종료 확인. 확인 실패면 재시도 중단.
#     (taskkill /T 는 발송기가 띄운 하이웍스 메신저까지 죽일 수 있어 쓰지 않음)
#   - 시간 초과는 "전송 여부 불명"으로 보고 자동 재발송 보류 + 당일 보류 기록. 일반 실패 코드만 재시도.
#   - 잠금 획득 후 당일 기록 재검사, AbandonedMutex 외 예외는 실패 처리, 종료 시 잠금 해제.
# 2026-10-17 v4 (QA v2 잔여 2번):
#   - UIA 가 전송 직전에 남기는 단계 기록(hiworks_start_send_stage.txt)으로 결과를 3가지로 구분.
#       0                         → 성공
#       실패 + 이번 시도에 단계 기록 있음 → 전송 여부 불명 → 보류 (재발송 안 함)
#       실패 + 단계 기록 없음         → 전송 전 실패 → 재시도 (시간 초과도 종료 확인됐으면 재시도)
#   - UIA 에 단계 기록 패치가 없으면 모든 실패를 '불명'으로 보고 보류 (보수적 동작).
#   - 당일 발송 확인은 발송기 자체 기록(hiworks_start_message_yyyyMMdd.sent)으로 일원화.
# 2026-10-17 v5 (QA v3 반영):
#   - 전송 직전 관문: UIA 패치(v2)의 Write-SendStage 가 HIWORKS_SEND_DEADLINE(13:00) 을 전송 직전에 검사
#   - 프로세스 조회 실패는 '살아 있음(확인 불가)'으로 취급 (공통 블록), 매 시도 전 남은 발송 자동화 정리·확인
#   - 발송기를 띄운 뒤 생긴 예외는 일반 재시도가 아니라 보류(exit 4)
#   - 패치 지원 판정을 문자열 검색이 아닌 구문 트리(함수 정의 1 + 호출 2 + 관문 코드)로
#   - 보류 기록 쓰기 실패 시 보조 경로(%TEMP%)에도 기록, 보류 기록을 못 읽으면 '보류 중'으로 취급
# 2026-10-17 v6 (QA v5 반영):
#   - 프로세스 상태 3분류(same/gone/unknown), 동일성 불명 PID 에는 종료 요청 안 함 (공통 블록 v6)
#   - 패치 지원 판정: 구문 오류 0 + 관문 구현 승인 해시 + 전송 직전 호출 위치 (공통 블록)
#   - 보류 기록을 두 경로 모두 못 써도: 오늘 전송 직전 기록이 있는데 성공 기록이 없으면 보류로 판단
$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$logFile = Join-Path $logDir "hiworks_self_greeting_queue.log"
$greetingLauncherPath = "C:\Scripts\send_hiworks_self_greeting.ps1"
$uiaScriptPath = "C:\Scripts\send_hiworks_self_greeting_uia.ps1"
$sendStageFile = Join-Path $logDir "hiworks_start_send_stage.txt"         # UIA 가 전송 직전에 기록 (패치 필요)
$holdMarkerFile = Join-Path $logDir "hiworks_self_greeting_hold.txt"        # 전송 여부 불명으로 보류한 날짜(yyyy-MM-dd)
$holdMarkerFallback = Join-Path $env:TEMP "hiworks_self_greeting_hold.txt"  # 위 경로에 못 쓸 때 보조 기록

# ---- 시각 설정 ----
$firstAttemptHour = 12; $firstAttemptMinute = 50   # 첫 시도 기준 시각
$jitterMaxMinutes = 4        # 0~4분 랜덤 지연 (정각 고정 회피). 12:50 고정을 원하면 0
$queueEarliestHour = 12; $queueEarliestMinute = 40 # 이보다 일찍 시작된 큐는 스킵
$deadlineHour = 13; $deadlineMinute = 0            # 이 시각 이후로는 시도하지 않음
$retryDelaySeconds = 60
$attemptTimeoutSeconds = 180   # 시도 1회 최대 시간 (마감까지 남은 시간이 더 짧으면 그쪽 적용) — 가정값
$minAttemptSeconds = 30        # 마감까지 이보다 적게 남으면 새 시도를 시작하지 않음
$killVerifySeconds = 10        # 강제 종료 후 종료 확인 대기 한도
$scriptHostNames = @('powershell.exe', 'pwsh.exe', 'conhost.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe')

# 발송기 결과 코드 (큐 내부용)
$RC_TIMEOUT_KILLED = 124   # 시간 초과 → 종료 확인됨 (전송 여부는 단계 기록으로 판단)
$RC_KILL_FAILED    = 125   # 시간 초과 → 종료 확인 실패 (이전 발송기 생존 가능)

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

# 파일 없음 → "" / 읽기 실패 → $null (호출자가 구분)
function Read-DateMarker {
    param([string]$Path)
    try {
        if (!(Test-Path -LiteralPath $Path)) { return "" }
        return ([string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)).Trim()
    } catch {
        Write-Log "[WARN] Could not read marker ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Write-DateMarker {
    param([string]$Path, [string]$Value)
    try {
        Set-Content -LiteralPath $Path -Value $Value -Encoding UTF8
        return $true
    } catch {
        Write-Log "[WARN] Could not write marker ${Path}: $($_.Exception.Message)"
        return $false
    }
}

# 보류 기록: 주 경로 실패 시 보조 경로에도 기록. 둘 다 실패하면 오류 로그
function Set-HoldToday {
    param([string]$Today)
    $okMain = Write-DateMarker -Path $holdMarkerFile -Value $Today
    if ($okMain) { return }
    $okFallback = Write-DateMarker -Path $holdMarkerFallback -Value $Today
    if (-not $okFallback) {
        Write-Log "[ERROR] Could not record today's HOLD anywhere. A same-day re-run might retry — check Hiworks before re-running."
    }
}

# 발송기(send_hiworks_self_greeting.ps1)가 성공 시 남기는 당일 기록과 같은 경로
function Get-LauncherStampPath {
    param([datetime]$Date)
    Join-Path $logDir ("hiworks_start_message_{0}.sent" -f $Date.ToString("yyyyMMdd"))
}

# 오늘 이미 끝난 상태(발송 완료 / 보류)면 이유 문자열, 아니면 $null
function Get-DoneTodayReason {
    param([string]$Today)
    $stamp = Get-LauncherStampPath -Date ([datetime]::ParseExact($Today, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture))
    if (Test-Path -LiteralPath $stamp) { return "already sent today ($stamp)" }
    # 보조 방어: 오늘 전송 직전 단계까지 갔는데 성공 기록이 없음 → 전송 여부 불명 → 보류
    try {
        if (Test-Path -LiteralPath $sendStageFile) {
            $stageDate = (Get-Item -LiteralPath $sendStageFile).LastWriteTime.Date
            if ($stageDate -eq [datetime]::ParseExact($Today, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)) {
                return "send stage was reached earlier today without a success stamp ($sendStageFile); treating as held — check Hiworks manually"
            }
        }
    } catch {
        return "send stage file unreadable ($sendStageFile); treating as held — check Hiworks manually"
    }
    foreach ($hp in @($holdMarkerFile, $holdMarkerFallback)) {
        $v = Read-DateMarker -Path $hp
        if ($null -eq $v) { return "hold marker unreadable ($hp); treating as held — check Hiworks manually" }
        if ($v -eq $Today) { return "held today because a previous attempt's send status is unknown ($Today, $hp) — check Hiworks manually" }
    }
    $null
}

# ---- 잠금 + 종료 ----
$mutex = $null
$hasLock = $false
function Exit-Queue {
    param([int]$Code)
    if ($hasLock -and $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($mutex) { try { $mutex.Dispose() } catch { } }
    exit $Code
}

# ==== 프로세스 확인·종료 공통 블록 (2026-10-17 v6) — 출근 큐·퇴근 발송기·연장 스크립트에 동일하게 포함 ====
# 원칙
#  - 프로세스 상태는 'same'(같은 프로세스 생존) / 'gone'(없음·다른 프로세스) / 'unknown'(조회 실패) 셋으로 구분
#  - 'unknown' 은 종료됨으로 보지 않고, 동일성이 확인되지 않았으므로 종료 요청 대상으로도 쓰지 않는다 (PID 재사용 보호)
# 필요 변수: $killVerifySeconds, $scriptHostNames, Write-Log
function Get-ProcTree {
    param([int]$RootPid)
    # 전체 조회 실패는 예외로 올려 보낸다 (호출자가 '확인 불가'로 처리)
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Select-Object ProcessId, ParentProcessId, Name, CreationDate)
    $root = $all | Where-Object { $_.ProcessId -eq $RootPid } | Select-Object -First 1
    if (-not $root) { return }
    $tree = New-Object System.Collections.Generic.List[object]
    $tree.Add($root)
    $seen = @{}
    $seen[[int]$RootPid] = $true
    $i = 0
    while ($i -lt $tree.Count) {
        $parent = $tree[$i]; $i++
        foreach ($c in $all) {
            # PID 재사용 방지: 부모보다 늦게 생성된 프로세스만 자식으로 인정
            if ($c.ParentProcessId -eq $parent.ProcessId -and
                -not $seen.ContainsKey([int]$c.ProcessId) -and
                $c.CreationDate -ge $parent.CreationDate) {
                $seen[[int]$c.ProcessId] = $true
                $tree.Add($c)
            }
        }
    }
    $tree
}

# 스냅샷 항목의 현재 상태: 'same' | 'gone' | 'unknown'
function Get-ProcState {
    param([object]$Member)
    try {
        $cur = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$Member.ProcessId)" -ErrorAction Stop
    } catch {
        Write-Log "[WARN] Process query failed for $($Member.Name)#$($Member.ProcessId): $($_.Exception.Message)"
        return 'unknown'
    }
    if ($cur -and $cur.CreationDate -eq $Member.CreationDate) { return 'same' }
    return 'gone'
}

# 대상 종료 후 확인. 전부 'gone' 이 확인되면 $true. 'same' 이 남거나 'unknown' 이 하나라도 있으면 $false
# 종료 요청은 동일성이 확인된('same') 대상에게만 보낸다.
function Stop-AndVerify {
    param([object[]]$Targets, [string]$What)
    if (@($Targets).Count -eq 0) { return $true }
    Write-Log "Stopping ${What}: $((@($Targets) | ForEach-Object { "$($_.Name)#$($_.ProcessId)" }) -join ', ')"
    foreach ($t in @($Targets)) {
        $st = Get-ProcState -Member $t
        if ($st -ne 'same') {
            if ($st -eq 'unknown') { Write-Log "[WARN] Not sending stop to $($t.Name)#$($t.ProcessId): identity unknown" }
            continue
        }
        try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop }
        catch { Write-Log "[WARN] Stop-Process $($t.Name)#$($t.ProcessId): $($_.Exception.Message)" }
    }
    $limit = (Get-Date).AddSeconds($killVerifySeconds)
    $remaining = @()
    do {
        $remaining = @(@($Targets) | Where-Object { (Get-ProcState -Member $_) -ne 'gone' })
        if ($remaining.Count -eq 0) {
            Write-Log "Stopped and verified: $What"
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $limit)
    Write-Log "[ERROR] Not verified as stopped ($What): $(($remaining | ForEach-Object { "$($_.Name)#$($_.ProcessId)" }) -join ', ')"
    return $false
}

# RootPid 의 트리에서 스크립트 호스트만 자식부터 종료·확인. 메신저 등 다른 자식은 남긴다.
function Stop-ProcTreeVerified {
    param([int]$RootPid)
    $tree = @()
    try {
        $tree = @(Get-ProcTree -RootPid $RootPid)
    } catch {
        Write-Log "[ERROR] Process tree snapshot failed: $($_.Exception.Message)"
        return $false   # 자식·동일성을 알 수 없음 → 종료 요청 없이 확인 불가로 반환
    }
    if ($tree.Count -eq 0) {
        Write-Log "Root PID $RootPid already gone at snapshot"
        return $true    # 남은 자식은 호출자가 Clear-MessagingAutomation 으로 확인
    }
    foreach ($o in @($tree | Where-Object { $scriptHostNames -notcontains ([string]$_.Name).ToLower() })) {
        Write-Log "[INFO] Leaving non-script child alive: $($o.Name) PID $($o.ProcessId)"
    }
    $targets = @($tree | Where-Object { $scriptHostNames -contains ([string]$_.Name).ToLower() })
    [array]::Reverse($targets)
    return (Stop-AndVerify -Targets $targets -What "process tree of PID $RootPid")
}

# 실행 중인 발송 자동화(발송기·UIA) 프로세스. 조회 실패는 예외로 올려 보낸다.
function Get-MessagingAutomationProcesses {
    @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
        Where-Object {
            $_.ProcessId -ne $PID -and (
                [string]$_.CommandLine -like '*send_hiworks_self_greeting_uia.ps1*' -or
                [string]$_.CommandLine -like '*send_hiworks_self_greeting.ps1*')
        } |
        Select-Object ProcessId, ParentProcessId, Name, CreationDate)
}

# 남아 있는 발송 자동화를 정리·확인. 없거나 정리 확인되면 $true, 조회 실패·정리 실패면 $false
function Clear-MessagingAutomation {
    param([string]$Why = 'leftover messaging automation')
    $stray = @()
    try {
        $stray = @(Get-MessagingAutomationProcesses)
    } catch {
        Write-Log "[ERROR] Could not inspect running messaging automation: $($_.Exception.Message)"
        return $false
    }
    if ($stray.Count -eq 0) { return $true }
    Write-Log "[WARN] Found $($stray.Count) $Why process(es)"
    return (Stop-AndVerify -Targets $stray -What $Why)
}

# ---- UIA 전송 직전 관문(패치 v2) 검증 ----
# 승인된 Write-SendStage 구현의 정규화 해시(각 줄 앞뒤 공백 제거·빈 줄 제외) + 구문 오류 0
# + 전송 동작 바로 앞 호출 2곳까지 확인해야 '지원'으로 본다.
$approvedSendStageHash = '00071c967024b41d1d5ec085faa1bce13e816d65aa2dd4547ce66686be1d6c41'
function Get-NormalizedTextHash {
    param([string]$Text)
    $norm = (($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}
function Test-UiaSendStageSupport {
    param([string]$Path)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if (@($errs).Count -gt 0) { return $false }
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-SendStage' }, $true))
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-SendStage' }, $true))
    if ($defs.Count -ne 1 -or $calls.Count -ne 2) { return $false }
    if ((Get-NormalizedTextHash -Text $defs[0].Extent.Text) -ne $approvedSendStageHash) { return $false }
    $text = $ast.Extent.Text
    $uiaOk = [regex]::IsMatch($text, "Write-SendStage -Method 'uia'\s*\r?\n\s*\`$invokePattern = \`$null")
    $coordOk = [regex]::IsMatch($text, "Write-SendStage -Method 'coordinate'\s*\r?\n\s*Click-Point -X \`$sendX -Y \`$sendY")
    return ($uiaOk -and $coordOk)
}
# ==== 공통 블록 끝 ====

# ---- 발송기 실행 (별도 프로세스 + 제한 시간) ----
function Invoke-GreetingLauncher {
    param([datetime]$Deadline, [string]$MessageFile)

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$greetingLauncherPath`"")
    if ($MessageFile) { $argList += @('-MessageFile', "`"$MessageFile`"") }

    $remainingSeconds = ($Deadline - (Get-Date)).TotalSeconds
    $timeoutSeconds = [Math]::Max(1, [Math]::Min($attemptTimeoutSeconds, $remainingSeconds))

    $script:launcherStarted = $false
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    $script:launcherStarted = $true
    $null = $proc.Handle   # PS 5.1 에서 ExitCode 를 받으려면 핸들을 먼저 잡아야 함

    if ($proc.WaitForExit([int]($timeoutSeconds * 1000))) {
        $proc.WaitForExit()
        if ($null -eq $proc.ExitCode) { return 1 }   # 종료 코드를 못 받으면 실패로 간주
        return [int]$proc.ExitCode
    }

    Write-Log "[ERROR] Launcher exceeded $([int]$timeoutSeconds)s (PID $($proc.Id))"
    $treeStopped = Stop-ProcTreeVerified -RootPid $proc.Id
    # 부모가 먼저 죽어 고아가 된 UIA 까지 한 번 더 확인
    $orphansCleared = Clear-MessagingAutomation -Why 'orphaned messaging automation after timeout'
    if ($treeStopped -and $orphansCleared) { return $RC_TIMEOUT_KILLED }
    return $RC_KILL_FAILED
}


Write-Log "=============================================="
Write-Log "Hiworks self greeting queue started"

if (!(Test-Path $greetingLauncherPath)) {
    Write-Log "[ERROR] Greeting launcher not found: $greetingLauncherPath"
    exit 1
}

$now = Get-Date
$todayText = $now.ToString("yyyy-MM-dd")

$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
if ($weekday -notcontains $now.DayOfWeek.ToString()) {
    Write-Log "[SKIP] Today is not a weekday: $($now.DayOfWeek)"
    exit 0
}

$holidayReason = Get-HiworksHolidayReason -Date $now.Date
if ($holidayReason) {
    Write-Log "[SKIP] Today is configured holiday: $todayText $holidayReason"
    exit 0
}

# ---- 중복 방지 1: 오늘 이미 끝났으면 종료 ----
$doneReason = Get-DoneTodayReason -Today $todayText
if ($doneReason) {
    Write-Log "[SKIP] $doneReason"
    exit 0
}

# ---- 중복 방지 2: 큐가 두 개 동시에 돌지 않게 ----
$mutex = New-Object System.Threading.Mutex($false, "Local\HiworksSelfGreetingQueue")
try {
    $hasLock = $mutex.WaitOne(0)
} catch {
    $ex = $_.Exception
    while ($ex -and -not ($ex -is [System.Threading.AbandonedMutexException])) { $ex = $ex.InnerException }
    if ($ex) {
        $hasLock = $true   # 이전 큐가 비정상 종료해 남은 잠금 → 획득으로 처리
        Write-Log "[WARN] Acquired abandoned queue lock"
    } else {
        Write-Log "[ERROR] Lock acquisition failed: $($_.Exception.Message)"
        Exit-Queue 1
    }
}
if (-not $hasLock) {
    Write-Log "[SKIP] Another greeting queue is already running"
    Exit-Queue 0
}

# 잠금 획득 후 재검사 (검사~잠금 사이에 다른 큐가 끝냈을 수 있음)
$doneReason = Get-DoneTodayReason -Today $todayText
if ($doneReason) {
    Write-Log "[SKIP] $doneReason (after lock)"
    Exit-Queue 0
}

# ---- UIA 단계 기록 패치 여부 ----
# 판정 함수 Test-UiaSendStageSupport 는 공통 블록에 있음 (구문 오류 0 + 승인 해시 + 전송 직전 위치)
$stageSupported = $false
try {
    $stageSupported = Test-UiaSendStageSupport -Path $uiaScriptPath
} catch {
    Write-Log "[WARN] Could not inspect UIA script for send-stage support: $($_.Exception.Message)"
}
if ($stageSupported) {
    Write-Log "Send-stage tracking: enabled"
} else {
    Write-Log "[WARN] Send-stage tracking: NOT available in UIA script. Any failure will be held (no auto-resend). Run Patch-UiaSendStage.ps1."
}

# ---- 시간 창 계산 ----
$jitter = Get-Random -Minimum 0 -Maximum ($jitterMaxMinutes + 1)
$target = $now.Date.AddHours($firstAttemptHour).AddMinutes($firstAttemptMinute + $jitter)
$earliest = $now.Date.AddHours($queueEarliestHour).AddMinutes($queueEarliestMinute)
$deadline = $now.Date.AddHours($deadlineHour).AddMinutes($deadlineMinute)
Write-Log "Jitter +${jitter}m -> first attempt $($target.ToString('HH:mm')), deadline $($deadline.ToString('HH:mm'))"

if ($now -lt $earliest -or $now -ge $deadline) {
    Write-Log "[SKIP] Current time is outside the greeting window ($($earliest.ToString('HH:mm'))~$($deadline.ToString('HH:mm'))): $($now.ToString('HH:mm:ss'))"
    Exit-Queue 0
}

$delaySeconds = [Math]::Max(0, [int][Math]::Ceiling(($target - $now).TotalSeconds))
Write-Log "Waiting $delaySeconds seconds until $($target.ToString('HH:mm:ss'))"
if ($delaySeconds -gt 0) {
    Start-Sleep -Seconds $delaySeconds
}

# 문구는 첫 시도 직전에 고른다 (실패해도 기존 흐름은 계속)
$startMessageFile = "C:\Scripts\hiworks_start_message.txt"
$pickerPath = "C:\Scripts\hiworks-message.ps1"
$pickerTimeoutSeconds = 30
try {
    # 문구 선택도 별도 프로세스 + 제한 시간 (멈춰도 발송 흐름은 계속)
    $pickerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$pickerPath`"", '-Type', 'start', '-WriteTo', "`"$startMessageFile`"")
    Remove-Item -LiteralPath $startMessageFile -Force -ErrorAction SilentlyContinue   # 전날 문구가 남아 쓰이지 않게
    $picker = Start-Process -FilePath 'powershell.exe' -ArgumentList $pickerArgs -WindowStyle Hidden -PassThru
    $null = $picker.Handle
    if (-not $picker.WaitForExit($pickerTimeoutSeconds * 1000)) {
        try { $picker.Kill() } catch { }
        throw "message picker exceeded ${pickerTimeoutSeconds}s"
    }
    if ($picker.ExitCode -ne 0) { throw "message picker exit code $($picker.ExitCode)" }
    if (!(Test-Path -LiteralPath $startMessageFile)) { throw "message file not created" }
    Write-Log "Start message prepared: $((Get-Content -LiteralPath $startMessageFile -Raw -Encoding UTF8) -replace "`r?`n", ' / ')"
} catch {
    Write-Log "[WARN] Message picker failed; launcher default will be used: $($_.Exception.Message)"
    $startMessageFile = $null
}

# ---- 전송 직전 관문 조건 (발송기·UIA 자식 프로세스가 환경변수로 물려받음) ----
$env:HIWORKS_SEND_DEADLINE = $deadline.ToString("o")   # UIA 는 이 시각 이후 전송 버튼을 누르지 않음
$env:HIWORKS_SEND_ABORT_FLAG = ""                      # 출근 인사에는 중단 기록 없음
Write-Log "Send gate: deadline $($env:HIWORKS_SEND_DEADLINE)"

# ---- 13:00 까지 재시도 ----
$attempt = 0
$exitCode = 1
while ((($deadline - (Get-Date)).TotalSeconds) -ge $minAttemptSeconds) {
    $attempt++
    Write-Log "Greeting launcher attempt ${attempt} (deadline $($deadline.ToString('HH:mm')))"

    $msgArg = $null
    if ($startMessageFile -and (Test-Path -LiteralPath $startMessageFile)) { $msgArg = $startMessageFile }

    # 이전 시도의 단계 기록 제거 (못 지워도 아래 시각 비교로 이번 시도 것만 인정)
    if (Test-Path -LiteralPath $sendStageFile) {
        try { Remove-Item -LiteralPath $sendStageFile -Force -ErrorAction Stop }
        catch { Write-Log "[WARN] Could not clear send-stage file: $($_.Exception.Message)" }
    }
    $attemptStart = (Get-Date).AddSeconds(-2)

    # 이전 시도·다른 실행이 남긴 발송기/UIA 가 있으면 정리·확인 후에만 시도 (동시 화면 조작 방지)
    if (!(Clear-MessagingAutomation -Why 'leftover messaging automation before attempt')) {
        Set-HoldToday -Today $todayText
        Write-Log "[HOLD] Leftover messaging automation could not be stopped/verified; not starting attempt ${attempt}. Check Hiworks and PowerShell processes."
        Exit-Queue 4
    }

    $script:launcherStarted = $false
    try {
        $exitCode = Invoke-GreetingLauncher -Deadline $deadline -MessageFile $msgArg
    } catch {
        if ($script:launcherStarted) {
            # 발송기가 이미 떠 있는 상태에서 예외 → 상태를 모름 → 재시도하지 않음
            Set-HoldToday -Today $todayText
            Write-Log "[HOLD] Error after the launcher started: $($_.Exception.Message). Not retrying — check Hiworks manually."
            Exit-Queue 4
        }
        Write-Log "[WARN] Launcher start failed (not started): $($_.Exception.Message)"
        $exitCode = 1
    }
    Write-Log "Greeting launcher attempt ${attempt} finished with exit code: $exitCode"

    if ($exitCode -eq 0) {
        Write-Log "Greeting launcher succeeded on attempt ${attempt}"
        Exit-Queue 0
    }

    # 이번 시도에서 전송 직전 단계까지 갔는지
    $reachedSendStage = $false
    try {
        if (Test-Path -LiteralPath $sendStageFile) {
            $reachedSendStage = ((Get-Item -LiteralPath $sendStageFile).LastWriteTime -ge $attemptStart)
        }
    } catch {
        $reachedSendStage = $true   # 확인 불가 → 불명으로 취급
        Write-Log "[WARN] Could not read send-stage file; treating as unknown: $($_.Exception.Message)"
    }

    if (-not $stageSupported -or $reachedSendStage) {
        # 전송 버튼을 눌렀을 수 있음 (또는 판단 근거 없음) → 자동 재발송하지 않음
        Set-HoldToday -Today $todayText
        $why = if ($reachedSendStage) { "reached send stage" } else { "send-stage tracking unavailable" }
        Write-Log "[HOLD] Attempt ${attempt} failed (exit $exitCode) after ${why}; send status unknown. Auto-resend held for today — check Hiworks manually."
        Exit-Queue 3
    }

    if ($exitCode -eq $RC_KILL_FAILED) {
        # 이전 발송기가 살아 있을 수 있음 → 동시 화면 조작 방지를 위해 중단
        Set-HoldToday -Today $todayText
        Write-Log "[HOLD] Attempt ${attempt} could not be stopped/verified. Retries stopped to avoid overlapping UI automation — check Hiworks and running PowerShell processes."
        Exit-Queue 4
    }

    Write-Log "Attempt ${attempt} failed before send stage (exit $exitCode); safe to retry"
    $nextAttempt = (Get-Date).AddSeconds($retryDelaySeconds)
    if (($deadline - $nextAttempt).TotalSeconds -lt $minAttemptSeconds) {
        Write-Log "[ERROR] Not retrying because next attempt would reach deadline: $($nextAttempt.ToString('HH:mm:ss'))"
        break
    }
    Write-Log "Retrying greeting launcher in $retryDelaySeconds seconds"
    Start-Sleep -Seconds $retryDelaySeconds
}

Write-Log "[ERROR] Greeting failed by deadline after $attempt attempt(s). Last exit code: $exitCode"
Exit-Queue $exitCode
