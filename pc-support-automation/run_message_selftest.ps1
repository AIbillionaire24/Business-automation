<#
====================================================================
 문구 변형 셀프테스트 — "나와의 채팅방" 으로 실제 발송해 확인한다

   .\run_message_selftest.ps1 -Type start
   .\run_message_selftest.ps1 -Type end
   .\run_message_selftest.ps1 -Type start -DryRun     ← 입력만 하고 전송 안 함

 기존 run_hiworks_selftest_via_task.ps1 과 다른 점:
   -SendMessage(고정문구) 가 아니라 -MessageFile 로 넘긴다.
   즉 hiworks-message.ps1 -> 파일 -> uia 경로를 그대로 탄다.

 채팅방 이름이 안 맞으면 -SearchQuery / -ChatTitle 로 바꿔서 실행.
====================================================================
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('start','end')][string]$Type,
    [switch]$DryRun,
    [string]$ChatTitle   = '나와의 채팅방',
    [string]$SearchQuery = '원격_담당자',
    # 계정 검사는 uia 가 계정명을 UIA 로 못 읽어 항상 WARN 후 통과한다.
    # 테스트에서는 명시적으로 비워 검사를 건너뛴다.
    [string]$ExpectedAccountName = '',
    [int]$TimeoutSeconds = 180,
    # 이 시간보다 오래된 마커는 처리 실패로 보고 자동으로 치운다
    [int]$StaleMarkerMinutes = 10
)

$ErrorActionPreference = 'Stop'
$logDir     = 'C:\Scripts\logs'
$markerPath = 'C:\Scripts\hiworks_marker_request.json'
$senderPath = 'C:\Scripts\send_hiworks_self_greeting.ps1'
$pickerPath = 'C:\Scripts\hiworks-message.ps1'
$taskName   = 'Launch Apps 1250'

if (!(Test-Path -LiteralPath $logDir))     { New-Item -ItemType Directory -Path $logDir | Out-Null }
if (!(Test-Path -LiteralPath $senderPath)) { throw "발송 스크립트 없음: $senderPath" }
if (!(Test-Path -LiteralPath $pickerPath)) { throw "문구 선택기 없음: $pickerPath" }
# ── 남아 있는 마커 처리 ──────────────────────────────────────────
# 마커가 남아 있으면 다음 'Launch Apps 1250' 실행이 그것을 처리하고
# "Normal launch flow skipped" 로 앱 실행과 출근 인사 큐를 통째로 건너뛴다.
# 그래서 방치하면 안 되고, 오래된 것은 자동으로 치운다.
if (Test-Path -LiteralPath $markerPath) {
    $age = (Get-Date) - (Get-Item -LiteralPath $markerPath).LastWriteTime
    if ($age.TotalMinutes -ge $StaleMarkerMinutes) {
        $trash = Join-Path $logDir ("stale_marker_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Move-Item -LiteralPath $markerPath -Destination $trash -Force
        Write-Host ("[정리] {0:n0}분 된 마커를 치웠습니다 -> {1}" -f $age.TotalMinutes, $trash) -ForegroundColor DarkYellow
        Write-Host "       (방치하면 다음 12:50 실행에서 앱 실행·출근 인사가 통째로 안 돕니다)" -ForegroundColor DarkYellow
    } else {
        throw ("마커 요청이 처리 중입니다 ({0:n0}분 전 생성). 끝날 때까지 기다리세요: {1}" -f $age.TotalMinutes, $markerPath)
    }
}

# 'Launch Apps 1250' 이 이미 돌고 있으면 Start-ScheduledTask 가 무시된다.
# 그 상태로 마커를 쓰면 처리되지 못한 채 남는다. 미리 막는다.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') {
    throw "'$taskName' 작업이 이미 실행 중입니다. 끝난 뒤 다시 시도하세요."
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$label = "msgtest_${Type}_$runId"
$msgFile = Join-Path $logDir "selftest_message_$runId.txt"

# ── 1) 실제 운영과 같은 방식으로 문구를 골라 파일에 쓴다 ──────────
& $pickerPath -Type $Type -WriteTo $msgFile | Out-Null
$bytes = [IO.File]::ReadAllBytes($msgFile)
$text  = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)

Write-Host "`n=== 고른 문구 ===" -ForegroundColor Cyan
$text -split "`n" | ForEach-Object { Write-Host "  $_" }
Write-Host ("  (BOM={0}  LF={1}  CRLF={2}  {3} bytes)" -f `
    ($bytes[0] -eq 0xEF), ([regex]::Matches($text,"`n")).Count, `
    ([regex]::Matches($text,"`r`n")).Count, $bytes.Length) -ForegroundColor DarkGray

# ── 2) 마커 요청 ────────────────────────────────────────────────
$resultPath = Join-Path $logDir "hiworks_marker_result_$runId.json"
$arguments = @(
    '-MessageLabel',       $label,
    '-TargetChatTitle',    $ChatTitle,
    '-TargetSearchQuery',  $SearchQuery,
    '-TargetSearchResult', $SearchQuery,
    '-MessageFile',        $msgFile
)
# 빈 문자열 인자는 넘기지 않는다.
# launch_apps.ps1 이 & powershell.exe @arguments 로 네이티브 호출하는데,
# 배열 안의 "" 는 전달 과정에서 사라져 뒤 인자가 한 칸씩 밀린다.
# (-ExpectedAccountName 이 -MessageFile 을 값으로 먹고, 경로가 위치 인자가 되어
#  파라미터 바인딩 실패 -> 스크립트가 로그 한 줄도 못 쓰고 exit 1)
# 스크립트 기본값이 이미 "" 이므로 생략하면 같은 효과다.
if ($ExpectedAccountName) { $arguments += @('-ExpectedAccountName', $ExpectedAccountName) }
if ($DryRun) { $arguments += '-DryRun' }

[PSCustomObject]@{
    RunId      = $runId
    Type       = "HiworksMessageSelfTest_$Type"
    CreatedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Script     = $senderPath
    Arguments  = $arguments
    ResultPath = $resultPath
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8

Write-Host "`n=== 실행 ===" -ForegroundColor Cyan
Write-Host "  채팅방 : $ChatTitle  (검색어: $SearchQuery)"
Write-Host "  모드   : $(if($DryRun){'DryRun - 입력만 하고 전송 안 함'}else{'실제 전송'})"
Start-ScheduledTask -TaskName $taskName
Write-Host "  작업 시작: $taskName" -ForegroundColor DarkGray

# ── 3) 결과 대기 ────────────────────────────────────────────────
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $resultPath) {
        $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $code = [int]$result.ExitCode

        Write-Host "`n=== 결과 ===" -ForegroundColor Cyan
        if ($code -eq 0) {
            Write-Host "  성공 (ExitCode 0)" -ForegroundColor Green
            if ($DryRun) {
                Write-Host "  DryRun 은 여기까지 확인합니다:" -ForegroundColor DarkGray
                Write-Host "    채팅방 검색 -> 열기 -> 입력창/전송버튼 확보" -ForegroundColor DarkGray
                Write-Host "  ※ 붙여넣기와 텍스트 대조(Assert-MessageTextInInput)는" -ForegroundColor Yellow
                Write-Host "     DryRun 경로에 없습니다. 문구가 입력창에 제대로 들어가는지까지" -ForegroundColor Yellow
                Write-Host "     보려면 -DryRun 없이 실행하세요 (나와의 채팅방이라 안전합니다)." -ForegroundColor Yellow
            } else {
                Write-Host "  붙여넣기 후 Assert-MessageTextInInput 를 통과했으므로," -ForegroundColor DarkGray
                Write-Host "  입력창에 들어간 텍스트가 위 문구와 일치함이 확인된 것입니다." -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  실패 (ExitCode $code)" -ForegroundColor Red
        }

        $uiaLog = Join-Path $logDir ("hiworks_{0}_message_uia.log" -f $label)
        if (Test-Path -LiteralPath $uiaLog) {
            Write-Host "`n--- uia 로그 (마지막 40줄) ---" -ForegroundColor DarkGray
            Get-Content -LiteralPath $uiaLog -Tail 40
        }
        $shots = Get-ChildItem -LiteralPath $logDir -Filter ("hiworks_{0}_*.png" -f $label) -ErrorAction SilentlyContinue
        if ($shots) {
            Write-Host "`n--- 스크린샷 ---" -ForegroundColor DarkGray
            $shots | Select-Object -ExpandProperty FullName
        }
        exit $code
    }
    Start-Sleep -Seconds 2
}

# 타임아웃 시 내가 쓴 마커가 처리되지 않고 남아 있으면 반드시 치운다.
if (Test-Path -LiteralPath $markerPath) {
    $trash = Join-Path $logDir ("stale_marker_{0}.json" -f $runId)
    Move-Item -LiteralPath $markerPath -Destination $trash -Force
    Write-Host "[정리] 처리되지 않은 마커를 치웠습니다 -> $trash" -ForegroundColor DarkYellow
}
throw "시간 초과. 결과 파일이 안 생겼습니다: $resultPath"
