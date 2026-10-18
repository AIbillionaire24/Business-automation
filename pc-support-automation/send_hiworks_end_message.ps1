param(
    [switch]$DryRun,
    [switch]$Force,
    # 연장 근무 후 수동 퇴근(workday_overtime.ps1 -Action Finish)에서 호출.
    # 시간창·지터·연장 기록 검사를 건너뛰고 즉시 보낸다. 당일 발송 기록 검사는 유지(중복 방지).
    [switch]$Manual
)

# 2026-10-17 변경:
#  - 연장 근무 기록(logs\workday_overtime_yyyyMMdd.flag)이 있으면 자동 발송을 건너뜀 (시작 시, 지터 후, 매 시도 전)
#  - -Manual: 연장 퇴근 시 즉시 발송
#  - QA 지적 7번: 시간 초과 시 프로세스 트리 종료를 '확인'까지 하고, 확인 실패면 재시도 중단(exit 4).
#    매 시도 전에 남아 있는 발송 자동화 프로세스(이전 시도의 UIA 등)를 찾아 정리·확인. 정리 못 하면 시도하지 않음.
#  - UIA 전송 단계 기록(Patch-UiaSendStage.ps1)의 로그 줄도 '전송 여부 불명' 판단에 사용
# 2026-10-17 v5 (QA v3 반영):
#  - 전송 직전 관문: 자동 발송은 연장 기록 경로(HIWORKS_SEND_ABORT_FLAG)와 마감(19:08)을 UIA 에 넘김
#    → 발송기가 이미 돌고 있을 때 '오늘 연장'을 눌러도 전송 버튼 직전에 멈춤. 수동(-Manual)은 연장 기록을 넘기지 않음
#  - 관문에 막힌 시도는 'gated' 로 구분 (연장이면 exit 0 건너뜀, 마감이면 실패)
#  - 프로세스 조회 실패는 '살아 있음(확인 불가)' (공통 블록)
#  - -Manual 에서 다른 발송이 진행 중이라 건너뛰면 exit 5 (수동 퇴근이 성공으로 오판하지 않게)
# 2026-10-17 v6 (QA v5 반영):
#  - '전송 여부 불명'을 당일 보류 기록(logs\hiworks_end_message_yyyyMMdd.hold)으로 남김 → 재실행·연장 퇴근 재클릭도 자동 재발송 안 함 (exit 6)
#    보류 해제는 workday_overtime.ps1 의 '연장 퇴근'에서 사용자가 하이웍스를 확인한 결과로만
#  - 판정 근거: UIA 로그 + 전송 직전 기록 파일(hiworks_end_send_stage.txt). 로그를 못 읽으면 'unknown'
#  - 시도마다 실패 직후 남은 발송 자동화 정리·확인 (내부 발송기 124 로 끝난 경우 포함)
#  - 오늘 전송 직전 기록이 있는데 성공 기록이 없으면 시작 시 보류
#  - 종료 코드: 0 성공·건너뜀 / 3 불명 보류 / 4 종료 미확인 보류 / 5 다른 발송 진행 중(수동) / 6 오늘 이미 보류 중
# v6.1 (QA v6 반영): 승인된 UIA 패치가 확인되지 않으면, 명확한 성공·관문 차단 외의 실패는 모두 보류
#   (단계 기록이 없다는 사실은 '기록 기능이 확인된 경우'에만 전송 전 실패의 근거가 됨)

$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$logFile = Join-Path $logDir "hiworks_end_message_task.log"
$senderPath = "C:\Scripts\send_hiworks_self_greeting.ps1"
$messageFile = "C:\Scripts\hiworks_end_message.txt"

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
        if ($null -eq $_) {
            '""'
        } elseif ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
}

$uiaLogFile = Join-Path $logDir "hiworks_end_message_uia.log"
$uiaScriptPath = "C:\Scripts\send_hiworks_self_greeting_uia.ps1"
$sendStageFile = Join-Path $logDir "hiworks_end_send_stage.txt"       # UIA 패치가 전송 직전에 기록
$endHoldFile = Join-Path $logDir ("hiworks_end_message_{0}.hold" -f (Get-Date).ToString("yyyyMMdd"))
$endHoldFallback = Join-Path $env:TEMP ("hiworks_end_message_{0}.hold" -f (Get-Date).ToString("yyyyMMdd"))
$killVerifySeconds = 10
$scriptHostNames = @('powershell.exe', 'pwsh.exe', 'conhost.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe')

function Test-OvertimeToday {
    $flag = Join-Path $logDir ("workday_overtime_{0}.flag" -f (Get-Date).ToString("yyyyMMdd"))
    return (Test-Path -LiteralPath $flag)
}

# UIA 로그에서 $Since 이후 발송 흔적을 찾는다. 반환: 'sent' | 'gated' | 'maybe' | 'none' | 'unknown'(로그 읽기 실패)
#   gated : 전송 직전 관문(연장 기록/마감)에 막혀 전송 버튼을 누르지 않음
#   sent  : "[OK] Message send action completed" 가 찍힘 -> 실제 발송 완료
#   maybe : 입력창 확인 후 전송 단계까지 들어감 -> 전송됐을 수 있음
# 종료 코드만 보고 재시도하면, 전송은 됐는데 뒤처리에서 실패/타임아웃 난 경우 중복 발송이 된다.
function Get-SendStateSince {
    param([datetime]$Since)

    if (!(Test-Path -LiteralPath $uiaLogFile)) {
        return 'none'
    }
    try {
        $lines = @(Get-Content -LiteralPath $uiaLogFile -Tail 400 -Encoding UTF8 -ErrorAction Stop)
    } catch {
        Write-Log "[WARN] UIA log unreadable: $($_.Exception.Message)"
        return 'unknown'
    }

    $floor = $Since.AddMilliseconds(-$Since.Millisecond)
    $state = 'none'
    foreach ($line in $lines) {
        if ($line -notmatch '^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (?<msg>.*)$') {
            continue
        }
        $lineTime = [datetime]::ParseExact($Matches.ts, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        if ($lineTime -lt $floor) {
            continue
        }
        $msg = $Matches.msg
        if ($msg.Contains('[OK] Message send action completed')) {
            return 'sent'
        }
        if ($msg.Contains('Send gate:')) {
            return 'gated'
        }
        if ($msg.Contains('[OK] Message text verified in chat input') -or $msg.Contains('sending by coordinates after target window validation') -or $msg.Contains('Send stage recorded')) {
            $state = 'maybe'
        }
    }
    $state
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

# ---- 보류 기록 ----
function Test-EndHeldToday {
    foreach ($hp in @($endHoldFile, $endHoldFallback)) {
        try { if (Test-Path -LiteralPath $hp) { return $hp } }
        catch { return "unreadable: $hp" }
    }
    $null
}
function Set-EndHold {
    param([string]$Reason)
    foreach ($hp in @($endHoldFile, $endHoldFallback)) {
        try {
            Set-Content -LiteralPath $hp -Value ("{0}|{1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Reason) -Encoding UTF8
            Write-Log "[HOLD] Recorded: $hp ($Reason)"
            return
        } catch {
            Write-Log "[WARN] Could not write hold ${hp}: $($_.Exception.Message)"
        }
    }
    Write-Log "[ERROR] Could not record HOLD anywhere; the stage file is the remaining guard"
}

# 이번 시도에서 전송 직전 단계까지 갔는지 (읽기 실패는 '갔다'로 취급)
function Test-StageReachedSince {
    param([datetime]$Since)
    try {
        if (!(Test-Path -LiteralPath $sendStageFile)) { return $false }
        return ((Get-Item -LiteralPath $sendStageFile).LastWriteTime -ge $Since.AddSeconds(-2))
    } catch {
        Write-Log "[WARN] Send-stage file unreadable; treating as reached: $($_.Exception.Message)"
        return $true
    }
}

# 실패한 시도의 결과 판정: 'success' | 'gated-overtime' | 'gated-deadline' | 'hold' | 'retry'
function Get-AttemptOutcome {
    param([datetime]$Since, [bool]$StageSupported, [bool]$ManualMode)
    $state = Get-SendStateSince -Since $Since
    if ($state -eq 'sent') { return 'success' }
    if ($state -eq 'gated') {
        if (!$ManualMode -and (Test-OvertimeToday)) { return 'gated-overtime' }
        return 'gated-deadline'
    }
    if (-not $StageSupported) { return 'hold' }                     # 단계 기록 기능 미확인 → '기록 없음'은 근거가 아님
    if (Test-StageReachedSince -Since $Since) { return 'hold' }      # 전송 직전 기록 있음 → 눌렀을 수 있음
    if ($state -eq 'maybe') { return 'hold' }
    return 'retry'                                                  # 승인된 패치 + 단계 기록 없음 + 흔적 없음 → 전송 전 실패
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
Write-Log "Hiworks end message task started. DryRun=$DryRun Force=$Force"

if (!(Test-Path $senderPath)) {
    Write-Log "[ERROR] Sender script not found: $senderPath"
    exit 1
}

if (!(Test-Path $messageFile)) {
    Write-Log "[ERROR] End message file not found: $messageFile"
    exit 1
}

$now = Get-Date
$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
$target = $now.Date.AddHours(19)
$earliest = $target

# ── 시간 지터 ────────────────────────────────────────────────────
# 19:00:00 정각 고정을 피한다. 초 단위로 흔들어 매일 시각이 달라지게 한다.
#
# 상한을 정하는 것은 'Close Apps 1910' 작업이다.
# 19:10 에 HiworksMessenger 가 강제 종료되므로, 지터 + 재시도 + 마지막
# 시도의 120초 hard timeout 이 전부 그 전에 끝나야 한다.
#
#   19:00 ─── 지터(0~2분) ─── 발송 ─── 재시도 창 ─── 마지막 시도(≤120초) ─── │ 19:10 종료
#
# $latest 를 지터만큼 밀어 재시도 예산을 보존하되,
# 종료 시각 앞 안전선($hardDeadline)을 넘지 않도록 자른다.
$closeAppsAt   = $now.Date.AddHours(19).AddMinutes(10)   # Close Apps 1910
$safetyMargin  = 120                                      # 종료 2분 전까지 끝낸다
$attemptBudget = 120                                      # 마지막 시도의 hard timeout
$hardDeadline  = $closeAppsAt.AddSeconds(-$safetyMargin).AddSeconds(-$attemptBudget)

$jitterSeconds = if ($DryRun -or $Force -or $Manual) { 0 } else { Get-Random -Minimum 0 -Maximum 121 }
$sendAt = $target.AddSeconds($jitterSeconds)
$latest = $sendAt.AddMinutes(4).AddSeconds(30)
if ($latest -gt $hardDeadline) { $latest = $hardDeadline }
if ($Manual) {
    # 수동 퇴근: 지금부터 6분 안에 끝낸다 (Close Apps 시각과 무관)
    $sendAt = $now
    $latest = $now.AddMinutes(6)
}
$stampFile = Join-Path $logDir ("hiworks_end_message_{0}.sent" -f $now.ToString("yyyyMMdd"))

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

    if (-not $Manual) {
        if ($now -lt $earliest -or $now -gt $latest) {
            Write-Log "[SKIP] Current time is outside the 19:00 end-message window: $($now.ToString('HH:mm:ss'))"
            exit 0
        }
        if (Test-OvertimeToday) {
            Write-Log "[SKIP] Overtime mode is on today; end message waits for the manual finish ('연장 퇴근')"
            exit 0
        }
    }
}

# 지터 대기는 뮤텍스를 잡기 전에 한다.
# 뮤텍스를 쥔 채로 몇 분 자면 다른 인스턴스가 5분 대기에 걸려 헛돈다.
# 자는 동안 다른 인스턴스가 먼저 보내면 아래 스탬프 검사에서 걸러진다.
if ($jitterSeconds -gt 0) {
    $wait = [TimeSpan]::FromSeconds($jitterSeconds)
    Write-Log ("Jitter {0:mm\:ss} -> send at {1}, retry window until {2} (Close Apps {3})" -f $wait, $sendAt.ToString('HH:mm:ss'), $latest.ToString('HH:mm:ss'), $closeAppsAt.ToString('HH:mm'))
    Start-Sleep -Seconds $jitterSeconds
} else {
    Write-Log ("Jitter 00:00 -> send now, retry window until {0}" -f $latest.ToString('HH:mm:ss'))
}

# 지터 대기 중에 '오늘 연장'을 켰을 수 있음
if (!$DryRun -and !$Force -and !$Manual -and (Test-OvertimeToday)) {
    Write-Log "[SKIP] Overtime mode was turned on during jitter; end message waits for the manual finish"
    exit 0
}

$mutex = $null
$hasMutex = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, "Local\HiworksEndMessageSender")
    try {
        $hasMutex = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
    } catch [System.Threading.AbandonedMutexException] {
        $hasMutex = $true
        Write-Log "[WARN] Previous end-message sender exited while holding the mutex; continuing with recovered lock."
    }
    if (!$hasMutex) {
        Write-Log "[SKIP] Another end message sender is already running."
        if ($Manual) { exit 5 }   # 수동 퇴근: '보내지 않음'을 성공으로 오판하지 않게
        exit 0
    }

    if (!$DryRun -and !$Force -and (Test-Path $stampFile)) {
        Write-Log "[SKIP] End message already sent today: $stampFile"
        exit 0
    }

    if (!$DryRun -and !$Force) {
        $heldBy = Test-EndHeldToday
        if ($heldBy) {
            Write-Log "[HOLD] Today's end message is on hold (send status unknown earlier): $heldBy. Not sending — confirm in Hiworks ('연장 퇴근' asks)."
            exit 6
        }
        try {
            if ((Test-Path -LiteralPath $sendStageFile) -and (Get-Item -LiteralPath $sendStageFile).LastWriteTime.Date -eq (Get-Date).Date) {
                Set-EndHold -Reason 'send stage reached earlier today without success stamp'
                Write-Log "[HOLD] Send stage was reached earlier today without a success stamp. Not sending."
                exit 6
            }
        } catch {
            Set-EndHold -Reason 'send stage file unreadable'
            exit 6
        }
    }

    $stageSupported = $false
    try { $stageSupported = Test-UiaSendStageSupport -Path $uiaScriptPath } catch { Write-Log "[WARN] Could not inspect UIA for send-stage support: $($_.Exception.Message)" }
    Write-Log "Send-stage tracking: $(if ($stageSupported) { 'enabled' } else { 'NOT available (unknown results will be held)' })"

    # 문구 변형. 실패해도 기존 hiworks_end_message.txt 를 그대로 쓴다.
    try {
        & "C:\Scripts\hiworks-message.ps1" -Type end -WriteTo $messageFile | Out-Null
        $picked = (Get-Content -LiteralPath $messageFile -Raw -Encoding UTF8) -replace "`r?`n", ' / '
        Write-Log "End message prepared: $picked"
    } catch {
        Write-Log "[WARN] Message picker failed; existing message file will be used: $($_.Exception.Message)"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $senderPath,
        "-MessageFile",
        $messageFile,
        "-MessageLabel",
        "end",
        "-TargetChatTitle",
        "동료B2",
        "-TargetSearchQuery",
        "동료B2",
        "-TargetSearchResult",
        "동료B2",
        "-MaxRuntimeSeconds",
        [string]$attemptBudget
    )
    if ($DryRun) {
        $arguments += "-DryRun"
    }

    # ---- 전송 직전 관문 조건 (발송기·UIA 자식 프로세스가 환경변수로 물려받음) ----
    if ($Manual) {
        $env:HIWORKS_SEND_DEADLINE = $latest.AddSeconds($attemptBudget).ToString("o")
        $env:HIWORKS_SEND_ABORT_FLAG = ""      # 수동 퇴근은 연장 기록이 있어도 보냄
    } elseif ($DryRun -or $Force) {
        $env:HIWORKS_SEND_DEADLINE = ""
        $env:HIWORKS_SEND_ABORT_FLAG = ""
    } else {
        $env:HIWORKS_SEND_DEADLINE = $closeAppsAt.AddSeconds(-$safetyMargin).ToString("o")   # 19:08
        $env:HIWORKS_SEND_ABORT_FLAG = Join-Path $logDir ("workday_overtime_{0}.flag" -f $now.ToString("yyyyMMdd"))
    }
    Write-Log "Send gate: deadline '$($env:HIWORKS_SEND_DEADLINE)', abort flag '$($env:HIWORKS_SEND_ABORT_FLAG)'"

    $maxAttempts = 3
    $retryDelaySeconds = 0
    $exitCode = 1

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if (!$DryRun -and !$Force -and (Test-Path $stampFile)) {
            Write-Log "[SKIP] End message already sent today before attempt ${attempt}: $stampFile"
            exit 0
        }

        if (!$DryRun -and !$Force) {
            $attemptNow = Get-Date
            if ($attemptNow -gt $latest) {
                Write-Log "[ERROR] Retry window expired before attempt ${attempt}: $($attemptNow.ToString('HH:mm:ss'))"
                exit $exitCode
            }
            if (!$Manual -and (Test-OvertimeToday)) {
                Write-Log "[SKIP] Overtime mode is on; not starting attempt ${attempt}"
                exit 0
            }
        }

        # 이전 시도의 발송기/UIA 가 남아 있으면 정리·확인 후에만 시도 (동시 화면 조작 방지)
        if (!(Clear-MessagingAutomation -Why 'leftover messaging automation before attempt')) {
            Set-EndHold -Reason 'leftover messaging automation could not be stopped/verified'
            Write-Log "[HOLD] Leftover messaging automation could not be stopped/verified; not starting attempt ${attempt}. Check Hiworks and PowerShell processes."
            exit 4
        }

        Write-Log "End message sender attempt ${attempt}/${maxAttempts} with ${attemptBudget}s hard timeout: $senderPath"
        if (Test-Path -LiteralPath $sendStageFile) {
            try { Remove-Item -LiteralPath $sendStageFile -Force -ErrorAction Stop }
            catch { Write-Log "[WARN] Could not clear send-stage file (time comparison still applies): $($_.Exception.Message)" }
        }
        $attemptStartedAt = Get-Date
        # 2026-09-28: Start-Process -Wait 를 쓰지 않는다.
        # -Wait 는 자식뿐 아니라 자손 프로세스가 모두 끝날 때까지 기다린다. UIA 스크립트가
        # 하이웍스를 재시작하면 메신저가 자손이 되어, 19:10 Close Apps 가 메신저를 끌 때까지
        # 여기서 묶였다(8/10~9/22 재시작한 날 전부 19:10 에 복귀). 그래서 재시도가 사실상 불가능했다.
        $childProcess = Start-Process -FilePath "powershell.exe" -ArgumentList (Join-ProcessArguments -Arguments $arguments) -WindowStyle Hidden -PassThru
        $null = $childProcess.Handle   # 종료 코드를 나중에 읽으려면 핸들을 미리 잡아 둔다
        $outerTimeoutSeconds = $attemptBudget + 30   # 안쪽 120초 타임아웃 + 정리 여유
        if ($childProcess.WaitForExit($outerTimeoutSeconds * 1000)) {
            $exitCode = $childProcess.ExitCode
            if ($null -eq $exitCode) {
                $exitCode = 1
            }
        } else {
            Write-Log "[ERROR] Sender did not exit within ${outerTimeoutSeconds}s; stopping PID $($childProcess.Id) and its script-host children (HiworksMessenger excluded)"
            if (!(Stop-ProcTreeVerified -RootPid $childProcess.Id) -or
                !(Clear-MessagingAutomation -Why 'orphaned messaging automation after timeout')) {
                Set-EndHold -Reason 'sender could not be stopped/verified after timeout'
                Write-Log "[HOLD] Sender tree could not be stopped/verified; stopping retries to avoid overlapping UI automation. Check the chat and PowerShell processes manually."
                exit 4
            }
            $exitCode = 124
        }
        $elapsedSeconds = [int]((Get-Date) - $attemptStartedAt).TotalSeconds
        Write-Log "End message sender attempt ${attempt} finished with exit code: $exitCode (elapsed ${elapsedSeconds}s)"

        if ($exitCode -ne 0) {
            # 실패 직후 바로 정리 (내부 발송기가 124 로 끝나며 UIA 를 남겼을 수 있음 — 마지막 시도 포함)
            if (!(Clear-MessagingAutomation -Why 'messaging automation left after failed attempt')) {
                Set-EndHold -Reason 'automation left after failed attempt could not be stopped/verified'
                Write-Log "[HOLD] Automation left after attempt ${attempt} could not be stopped/verified. Check manually."
                exit 4
            }
        }

        if ($exitCode -ne 0 -and !$DryRun) {
            $outcome = Get-AttemptOutcome -Since $attemptStartedAt -StageSupported $stageSupported -ManualMode ([bool]$Manual)
            Write-Log "Attempt ${attempt} outcome: $outcome"
            switch ($outcome) {
                'success' {
                    Write-Log "[WARN] Exit code was $exitCode but the UIA log shows the message was sent; treating as success."
                    $exitCode = 0
                }
                'gated-overtime' {
                    Write-Log "[SKIP] Send gate stopped attempt ${attempt} because overtime mode was turned on; nothing was sent"
                    exit 0
                }
                'gated-deadline' {
                    Write-Log "[ERROR] Send gate stopped attempt ${attempt} (deadline); nothing was sent"
                    exit $exitCode
                }
                'hold' {
                    Set-EndHold -Reason "attempt ${attempt} failed after reaching the send step (exit $exitCode)"
                    Write-Log "[HOLD] The send step may have run; not retrying to avoid a duplicate message. Check the chat manually."
                    exit 3
                }
                default { }   # retry
            }
        }

        if ($exitCode -eq 0) {
            if (!$DryRun) {
                Set-Content -Path $stampFile -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Encoding UTF8
                Write-Log "[OK] End message stamp saved: $stampFile"
            }
            Write-Log "End message sender succeeded on attempt ${attempt}"
            exit 0
        }

        if ($attempt -lt $maxAttempts) {
            if (!$Force -and !$DryRun) {   # 드라이런은 시간창과 무관하게 재시도 경로까지 시험한다
                $nextAttempt = (Get-Date).AddSeconds($retryDelaySeconds)
                if ($nextAttempt -gt $latest) {
                    Write-Log "[ERROR] Not retrying because next attempt would exceed window: $($nextAttempt.ToString('HH:mm:ss'))"
                    exit $exitCode
                }
            }

            if ($retryDelaySeconds -gt 0) {
                Write-Log "Retrying end message sender in $retryDelaySeconds seconds"
                Start-Sleep -Seconds $retryDelaySeconds
            } else {
                Write-Log "Retrying end message sender immediately"
            }
        }
    }

    Write-Log "[ERROR] End message sender failed after $maxAttempts attempts. Last exit code: $exitCode"
    exit $exitCode
} catch {
    Write-Log "[ERROR] Failed to run end message sender: $($_.Exception.Message)"
    exit 1
} finally {
    if ($hasMutex -and $mutex) {
        try {
            $mutex.ReleaseMutex()
        } catch {
        }
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}


