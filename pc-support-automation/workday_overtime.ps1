<#
  workday_overtime.ps1 — 연장 근무 처리 (2026-10-17)

  -Action Prompt   : 18:55 예약 작업. "오늘 연장 근무하시나요?" 알림창. 응답 없으면 아무것도 안 함(평소대로 19:00 퇴근 메시지 → 19:10 앱 종료)
  -Action On       : 바탕화면 '오늘 연장' 바로가기. 당일 연장 기록을 켬 → 19:00 퇴근 메시지·19:10/19:15 앱 종료가 건너뜀
  -Action Finish   : 바탕화면 '연장 퇴근' 바로가기. 확인 후 퇴근 메시지 전송 → 성공이면 업무 앱 종료
  -Action Reminder : 19:40 예약 작업. 연장 중이면 "끝나셨나요?" 알림창. 응답 없으면 아무것도 안 함 (연장한 날은 자동 종료하지 않음)

  연장 기록: C:\Scripts\logs\workday_overtime_yyyyMMdd.flag (퇴근 처리 후 .done 으로 바뀜)
  알림창은 포커스를 뺏지 않는다(원격 작업 중 타이핑이 알림창 버튼으로 들어가지 않게).

  v5 (QA v3 반영):
   - 수동 퇴근은 종료 코드 0 '그리고' 당일 퇴근 메시지 발송 기록(.sent)이 있을 때만 앱을 닫음
     (다른 발송이 진행 중이라 건너뛴 경우 exit 5 → 앱 유지)
   - 퇴근 메시지 처리 시간 초과 시 자식 트리와 남은 발송 자동화까지 종료·확인
   - 연장 기록 완료(.done)는 앱 종료까지 성공한 뒤에만
  v6 (QA v5 반영):
   - 퇴근 메시지가 '전송 여부 불명'으로 보류된 날(.hold)은 연장 퇴근에서 하이웍스 확인 결과를 물음
       [보내졌음] → 발송 기록 남기고 앱 종료 / [안 보내졌음] → 보류 해제 후 1회 재발송 / [취소]
   - 자식 스크립트가 끝난 뒤에도 남은 발송 자동화를 정리·확인
   - Prompt 는 18:50~19:00, Reminder 는 19:35~20:30 에만 표시 (늦게 실행된 작업이 엉뚱한 시각에 뜨지 않게)
  v6.1 (QA v6 반영): [보내졌음] 은 발송 기록을 먼저 저장·확인한 뒤에만 보류 해제. 저장 실패 시 보류 유지.
   ('한 번 다시 보내기'는 연장 퇴근의 상위 호출 1회이며, 그 안에서 발송기는 전송 전 실패만 최대 3회 재시도)
#>
param(
    [ValidateSet('Prompt', 'On', 'Finish', 'Reminder')]
    [string]$Action = 'Prompt',
    [int]$PromptTimeoutSeconds = 240,
    [int]$ReminderTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

$logDir = 'C:\Scripts\logs'
$logFile = Join-Path $logDir 'workday_overtime.log'
$endMessageScript = 'C:\Scripts\send_hiworks_end_message.ps1'
$closeAppsScript = 'C:\Scripts\close_apps.ps1'
$holidayFile = 'C:\Scripts\hiworks_holidays.txt'
$endMessageTimeoutSeconds = 480
$closeAppsTimeoutSeconds = 240
$killVerifySeconds = 10
$scriptHostNames = @('powershell.exe', 'pwsh.exe', 'conhost.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe')
$RC_CHILD_TIMEOUT_STOPPED = 124   # 시간 초과 → 종료 확인됨
$RC_CHILD_TIMEOUT_UNKNOWN = 125   # 시간 초과 → 종료 확인 실패

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "[$timestamp] [$Action] $Message" -Encoding UTF8
}

function Get-HiworksHolidayReason {
    param([datetime]$Date)

    if (!(Test-Path -LiteralPath $holidayFile)) {
        return $null
    }

    $dateText = $Date.ToString('yyyy-MM-dd')
    $lines = Get-Content -LiteralPath $holidayFile -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }
        if ($trimmed -match '^(?<date>\d{4}-\d{2}-\d{2})(?:\s+(?<reason>.*))?$') {
            if ($Matches.date -eq $dateText) {
                if ([string]::IsNullOrWhiteSpace($Matches.reason)) {
                    return 'configured holiday'
                }
                return $Matches.reason
            }
        }
    }
    $null
}

$today = (Get-Date).Date
$flagFile = Join-Path $logDir ('workday_overtime_{0}.flag' -f $today.ToString('yyyyMMdd'))
$doneFile = Join-Path $logDir ('workday_overtime_{0}.done' -f $today.ToString('yyyyMMdd'))
$endStampFile = Join-Path $logDir ('hiworks_end_message_{0}.sent' -f $today.ToString('yyyyMMdd'))
$endHoldFiles = @(
    (Join-Path $logDir ('hiworks_end_message_{0}.hold' -f $today.ToString('yyyyMMdd'))),
    (Join-Path $env:TEMP ('hiworks_end_message_{0}.hold' -f $today.ToString('yyyyMMdd')))
)
$endStageFile = Join-Path $logDir 'hiworks_end_send_stage.txt'
$RC_END_HELD_UNKNOWN = 3
$RC_END_KILL_UNVERIFIED = 4
$RC_END_BUSY = 5
$RC_END_HELD_TODAY = 6

function Test-EndHeld {
    foreach ($hp in $endHoldFiles) { if (Test-Path -LiteralPath $hp) { return $true } }
    try {
        if ((Test-Path -LiteralPath $endStageFile) -and (Get-Item -LiteralPath $endStageFile).LastWriteTime.Date -eq $today -and !(Test-Path -LiteralPath $endStampFile)) { return $true }
    } catch { return $true }
    return $false
}

function Test-InWindow {
    param([int]$FromH, [int]$FromM, [int]$ToH, [int]$ToM)
    $n = Get-Date
    return ($n -ge $today.AddHours($FromH).AddMinutes($FromM) -and $n -le $today.AddHours($ToH).AddMinutes($ToM))
}

function Test-Workday {
    $weekday = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    if ($weekday -notcontains $today.DayOfWeek.ToString()) { return $false }
    if (Get-HiworksHolidayReason -Date $today) { return $false }
    return $true
}

function Set-OvertimeFlag {
    param([string]$Source)
    Set-Content -LiteralPath $flagFile -Value ('{0}|{1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Source) -Encoding UTF8
    Write-Log "Overtime flag set by ${Source}: $flagFile"
}

function Complete-OvertimeFlag {
    if (Test-Path -LiteralPath $flagFile) {
        Move-Item -LiteralPath $flagFile -Destination $doneFile -Force
        Write-Log "Overtime flag closed: $doneFile"
    }
}

# 30일 지난 기록 정리 (실패해도 무시)
try {
    Get-ChildItem -LiteralPath $logDir -File -Filter 'workday_overtime_*.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^workday_overtime_\d{8}\.(flag|done)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

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

# ---------- 알림창 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('WorkdayNoActivateForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System.Windows.Forms;
public class WorkdayNoActivateForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE: 표시돼도 포커스를 가져가지 않음
            cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
            return cp;
        }
    }
}
'@
}

# 버튼 텍스트 중 하나, 또는 응답이 없으면 'timeout' 을 반환
# -Activate: 사용자가 직접 실행한 경우(바로가기)에만 포커스를 줌
function Show-Choice {
    param(
        [string]$Title,
        [string]$Message,
        [string[]]$Buttons,
        [int]$TimeoutSeconds,
        [switch]$Activate
    )

    if ($Activate) {
        $form = New-Object System.Windows.Forms.Form
        $form.TopMost = $true
    } else {
        $form = New-Object WorkdayNoActivateForm
    }
    $form.Text = $Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.ClientSize = New-Object System.Drawing.Size(440, 170)
    $form.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($area.Right - 460), ($area.Bottom - 210))

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.SetBounds(16, 12, 408, 100)
    $label.Text = $Message
    $form.Controls.Add($label)

    $script:choiceResult = 'timeout'
    $script:choiceRemaining = $TimeoutSeconds
    $script:choiceBaseText = $Message
    $script:choiceLabel = $label

    $x = 424
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $Buttons[$i]
        $btn.AutoSize = $true
        $btn.MinimumSize = New-Object System.Drawing.Size(96, 32)
        $btn.TabStop = $false   # 포커스가 버튼에 가지 않게 (Enter/Space 오입력 방지)
        $btn.Add_Click({
            $script:choiceResult = $this.Text
            $this.FindForm().Close()
        })
        $form.Controls.Add($btn)
        $btn.PerformLayout()
        $x -= [Math]::Max(96, $btn.PreferredSize.Width)
        $btn.Location = New-Object System.Drawing.Point($x, 122)
        $x -= 8
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:choiceRemaining--
        if ($script:choiceRemaining -le 0) {
            $this.Stop()
            $script:choiceLabel.FindForm().Close()
        } else {
            $script:choiceLabel.Text = "{0}`n`n({1}초 후 자동으로 닫힘)" -f $script:choiceBaseText, $script:choiceRemaining
        }
    })
    $label.Text = "{0}`n`n({1}초 후 자동으로 닫힘)" -f $Message, $TimeoutSeconds
    $timer.Start()

    try {
        if ($Activate) {
            [void]$form.ShowDialog()
        } else {
            [System.Windows.Forms.Application]::Run($form)
        }
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
    }
    return $script:choiceResult
}

# 자식 PowerShell 스크립트 실행 + 제한 시간. 종료 코드 반환 (시간 초과 124)
function Invoke-ChildScript {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds)

    $argLine = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Path`"") + $Arguments
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $null = $proc.Handle
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        $proc.WaitForExit()
        $code = if ($null -eq $proc.ExitCode) { 1 } else { [int]$proc.ExitCode }
        # 자식이 끝난 뒤에도 발송 자동화가 남았는지 확인 (내부 시간 초과 후 UIA 잔존 대비)
        if (!(Clear-MessagingAutomation -Why 'messaging automation left after child script')) {
            Write-Log "[ERROR] Messaging automation remains after $Path (exit $code) and could not be stopped/verified"
            return $RC_CHILD_TIMEOUT_UNKNOWN
        }
        return $code
    }
    Write-Log "[ERROR] $Path exceeded ${TimeoutSeconds}s (PID $($proc.Id)); stopping it and its automation children"
    $treeStopped = Stop-ProcTreeVerified -RootPid $proc.Id
    $orphansCleared = Clear-MessagingAutomation -Why 'messaging automation left after timeout'
    if ($treeStopped -and $orphansCleared) { return $RC_CHILD_TIMEOUT_STOPPED }
    return $RC_CHILD_TIMEOUT_UNKNOWN
}

function Clear-EndHold {
    foreach ($hp in $endHoldFiles) { Remove-Item -LiteralPath $hp -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $endStageFile -Force -ErrorAction SilentlyContinue
    foreach ($hp in $endHoldFiles) { if (Test-Path -LiteralPath $hp) { throw "보류 기록을 지우지 못함: $hp" } }
    if (Test-Path -LiteralPath $endStageFile) { throw "전송 단계 기록을 지우지 못함: $endStageFile" }
    Write-Log 'End hold cleared by user confirmation'
}

# 보류 상태: 사용자에게 하이웍스 확인 결과를 물음. 반환 'sent' | 'resend' | 'cancel'
function Request-EndHoldDecision {
    $c = Show-Choice -Title '퇴근 메시지 확인 필요' -Message "오늘 퇴근 메시지가 전송됐는지 자동으로 확인하지 못했습니다.`n하이웍스 채팅방을 직접 보고 선택해 주세요." -Buttons @('보내졌음', '안 보내졌음', '취소') -TimeoutSeconds 900 -Activate
    Write-Log "Hold decision: $c"
    switch ($c) {
        '보내졌음'    { return 'sent' }
        '안 보내졌음' { return 'resend' }
        default       { return 'cancel' }
    }
}

function Invoke-CloseAndComplete {
    Write-Log 'Finish: closing work apps (-Force)'
    $closeCode = Invoke-ChildScript -Path $closeAppsScript -Arguments @('-Force') -TimeoutSeconds $closeAppsTimeoutSeconds
    Write-Log "Finish: close_apps exit code $closeCode"
    if ($closeCode -ne 0) {
        [void](Show-Choice -Title '앱 종료 확인 필요' -Message ("퇴근 메시지는 처리됐지만 일부 업무 앱·창을 닫지 못했습니다 (코드 {0}).`n'연장 퇴근'을 다시 누르면 앱 종료만 다시 시도합니다 (메시지는 중복 발송되지 않음).`n로그: C:\Scripts\logs\close_apps.log" -f $closeCode) -Buttons @('확인') -TimeoutSeconds 900 -Activate)
        exit 3
    }
    Complete-OvertimeFlag   # 메시지·앱 종료 모두 성공한 뒤에만
    [void](Show-Choice -Title '퇴근 처리 완료' -Message '퇴근 메시지를 보내고 업무 앱을 닫았습니다.' -Buttons @('확인') -TimeoutSeconds 8 -Activate)
    exit 0
}

function Invoke-Finish {
    # 이미 보낸 날: 앱 종료만
    if (Test-Path -LiteralPath $endStampFile) {
        Write-Log 'Finish: end message already sent today; closing apps only'
        Invoke-CloseAndComplete
    }

    $resent = $false
    while ($true) {
        if (Test-EndHeld) {
            $d = Request-EndHoldDecision
            if ($d -eq 'cancel') { exit 0 }
            if ($d -eq 'sent') {
                # 1) 발송 기록을 먼저 저장·확인 (실패하면 보류 근거를 그대로 둔다)
                try {
                    Set-Content -LiteralPath $endStampFile -Value ('{0}|confirmed by user' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8 -ErrorAction Stop
                    if (!(Test-Path -LiteralPath $endStampFile)) { throw 'stamp file not found after write' }
                } catch {
                    Write-Log "[ERROR] Could not save the user-confirmed sent stamp; hold kept: $($_.Exception.Message)"
                    [void](Show-Choice -Title '기록 저장 실패' -Message "'보내졌음' 기록을 저장하지 못했습니다. 보류 상태를 그대로 둡니다 (자동 재발송 없음).`n잠시 뒤 '연장 퇴근'을 다시 눌러 주세요. 업무 앱은 닫지 않았습니다." -Buttons @('확인') -TimeoutSeconds 900 -Activate)
                    exit 2
                }
                Write-Log 'Finish: user confirmed the end message was sent; stamp written and verified'
                # 2) 그다음 보류 정리. 실패해도 발송 기록이 우선하므로 재발송되지 않음
                try { Clear-EndHold } catch { Write-Log "[WARN] Hold cleanup failed after stamp was saved (stamp takes precedence): $($_.Exception.Message)" }
                Invoke-CloseAndComplete
            }
            if ($resent) {
                # 한 번 다시 보냈는데 또 불명 → 더 반복하지 않음
                [void](Show-Choice -Title '퇴근 메시지 확인 필요' -Message "다시 보내기도 전송 여부를 확인하지 못했습니다. 하이웍스에서 직접 처리해 주세요.`n업무 앱은 닫지 않았습니다." -Buttons @('확인') -TimeoutSeconds 900 -Activate)
                exit 2
            }
            Clear-EndHold
            $resent = $true
        }

        Write-Log 'Finish: sending end message (-Manual)'
        $code = Invoke-ChildScript -Path $endMessageScript -Arguments @('-Manual') -TimeoutSeconds $endMessageTimeoutSeconds
        $stampOk = Test-Path -LiteralPath $endStampFile
        Write-Log "Finish: end message exit code $code, today's sent stamp present=$stampOk"

        if ($code -eq 0 -and $stampOk) { Invoke-CloseAndComplete }
        if (($code -eq $RC_END_HELD_UNKNOWN -or $code -eq $RC_END_HELD_TODAY) -and -not $resent) { continue }   # 보류 → 사용자 확인으로

        if ($code -eq $RC_END_BUSY) {
            $why = "다른 퇴근 메시지 처리가 진행 중이라 이번에는 보내지 않았습니다.`n1~2분 뒤 '연장 퇴근'을 다시 눌러 주세요."
        } elseif ($code -eq $RC_END_KILL_UNVERIFIED -or $code -eq $RC_CHILD_TIMEOUT_UNKNOWN) {
            $why = "발송 자동화가 완전히 멈췄는지 확인하지 못했습니다.`n하이웍스와 작업 관리자의 PowerShell 을 확인한 뒤 다시 시도해 주세요."
        } elseif ($code -eq 0) {
            $why = "퇴근 메시지 발송 기록이 없습니다 (평일·휴일 설정 등으로 건너뛰었을 수 있음)."
        } else {
            $why = "퇴근 메시지를 보내지 못했거나 전송 여부가 불확실합니다 (코드 $code).`n하이웍스에서 직접 확인해 주세요."
        }
        [void](Show-Choice -Title '퇴근 메시지 확인 필요' -Message ("{0}`n업무 앱은 닫지 않았습니다. 로그: C:\Scripts\logs\hiworks_end_message_task.log" -f $why) -Buttons @('확인') -TimeoutSeconds 900 -Activate)
        exit 2
    }
}

# ---------- 실행 ----------
Write-Log '=============================================='
Write-Log "Started. Flag=$(Test-Path -LiteralPath $flagFile) EndSent=$(Test-Path -LiteralPath $endStampFile)"

try {
    switch ($Action) {
        'Prompt' {
            if (!(Test-Workday)) { Write-Log '[SKIP] Not a workday'; exit 0 }
            if (!(Test-InWindow 18 50 19 0)) { Write-Log '[SKIP] Outside 18:50~19:00 prompt window (late or early run)'; exit 0 }
            if (Test-Path -LiteralPath $flagFile) { Write-Log '[SKIP] Overtime already on'; exit 0 }
            if (Test-Path -LiteralPath $endStampFile) { Write-Log '[SKIP] End message already sent today'; exit 0 }

            $choice = Show-Choice -Title '퇴근 확인' -Message "오늘 연장 근무하시나요?`n응답이 없으면 평소대로 19:00 퇴근 메시지 → 19:10 업무 앱 종료가 진행됩니다." -Buttons @('연장 근무', '정상 퇴근') -TimeoutSeconds $PromptTimeoutSeconds
            Write-Log "Prompt answer: $choice"
            if ($choice -eq '연장 근무') {
                Set-OvertimeFlag -Source 'prompt'
                [void](Show-Choice -Title '연장 모드' -Message "연장 모드를 켰습니다. 퇴근 메시지와 업무 앱 자동 종료를 보류합니다.`n끝나면 바탕화면의 '연장 퇴근'을 눌러 주세요." -Buttons @('확인') -TimeoutSeconds 20)
            }
            exit 0
        }
        'On' {
            if (Test-Path -LiteralPath $flagFile) {
                [void](Show-Choice -Title '연장 모드' -Message '이미 연장 모드입니다. 끝나면 바탕화면의 ''연장 퇴근''을 눌러 주세요.' -Buttons @('확인') -TimeoutSeconds 15 -Activate)
                exit 0
            }
            Set-OvertimeFlag -Source 'shortcut'
            $extra = ''
            if (Test-Path -LiteralPath $endStampFile) {
                $extra = "`n(퇴근 메시지는 이미 나갔습니다. 업무 앱 자동 종료만 막습니다.)"
            }
            [void](Show-Choice -Title '연장 모드' -Message ("연장 모드를 켰습니다. 퇴근 메시지와 업무 앱 자동 종료를 보류합니다.`n끝나면 바탕화면의 '연장 퇴근'을 눌러 주세요.{0}" -f $extra) -Buttons @('확인') -TimeoutSeconds 15 -Activate)
            exit 0
        }
        'Reminder' {
            if (!(Test-Path -LiteralPath $flagFile)) { Write-Log '[SKIP] Not in overtime mode'; exit 0 }
            if (!(Test-InWindow 19 35 20 30)) { Write-Log '[SKIP] Outside 19:35~20:30 reminder window (late or early run)'; exit 0 }
            $choice = Show-Choice -Title '연장 근무 중' -Message "연장 근무가 끝나셨나요?`n[퇴근 처리]를 누르면 퇴근 메시지를 보내고 업무 앱을 닫습니다.`n응답이 없으면 아무것도 하지 않습니다." -Buttons @('퇴근 처리', '계속') -TimeoutSeconds $ReminderTimeoutSeconds
            Write-Log "Reminder answer: $choice"
            if ($choice -eq '퇴근 처리') { Invoke-Finish }
            exit 0
        }
        'Finish' {
            $choice = Show-Choice -Title '연장 퇴근' -Message '퇴근 메시지를 보내고 업무 앱(하이웍스·LDPlayer·AnySupport 등)을 닫습니다. 진행할까요?' -Buttons @('진행', '취소') -TimeoutSeconds 60 -Activate
            Write-Log "Finish confirm: $choice"
            if ($choice -ne '진행') { exit 0 }
            Invoke-Finish
        }
    }
} catch {
    Write-Log "[ERROR] $($_.Exception.Message)"
    exit 1
}
