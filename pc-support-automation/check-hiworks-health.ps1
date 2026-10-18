<#
====================================================================
 하이웍스 자동화 상태 점검

   .\check-hiworks-health.ps1

 "조용히 틀리고 있는 것"을 찾아 보고한다.
 - 공휴일 목록이 올해를 덮고 있는지
 - 최근 발송 성공/실패
 - 지터·문구 변형이 실제로 동작 중인지
 - 계정명이 UIA 로 읽히기 시작했는지 (읽히면 검사를 되살릴 수 있다)
====================================================================
#>
$ErrorActionPreference = 'SilentlyContinue'
$logDir      = 'C:\Scripts\logs'
$holidayFile = 'C:\Scripts\hiworks_holidays.txt'
$warn = 0
function Ok($m)  { Write-Host "  [정상] $m" -ForegroundColor Green }
function Wn($m)  { Write-Host "  [확인] $m" -ForegroundColor Yellow; $script:warn++ }
function Ng($m)  { Write-Host "  [문제] $m" -ForegroundColor Red;    $script:warn++ }

Write-Host "`n=== 하이웍스 자동화 상태 ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ===" -ForegroundColor Cyan

# 1. 공휴일 목록
Write-Host "`n[1] 공휴일 목록"
if (!(Test-Path $holidayFile)) { Ng "목록 파일 없음: $holidayFile" }
else {
    $dates = Get-Content $holidayFile -Encoding UTF8 |
        ForEach-Object { if ($_ -match '^\s*(\d{4})-\d{2}-\d{2}') { [int]$Matches[1] } }
    $years = $dates | Sort-Object -Unique
    $thisYear = (Get-Date).Year
    Write-Host ("  등록 연도: {0}  (총 {1}일)" -f ($years -join ', '), $dates.Count)
    if ($years -contains $thisYear) {
        $left = ($dates | Where-Object { $_ -eq $thisYear }).Count
        Ok "올해($thisYear) 공휴일 $left 일 등록됨"
    } else {
        Ng "올해($thisYear) 공휴일이 하나도 없음 - 공휴일에 메시지가 나갑니다"
    }
    $next = $thisYear + 1
    if ($years -notcontains $next) { Wn "내년($next) 목록 없음 - 연말 전에 채워야 함" }

    # 확정 범위 표시 (# CONFIRMED_THROUGH yyyy-MM-dd)
    $raw = Get-Content $holidayFile -Encoding UTF8
    $ct = $raw | Where-Object { $_ -match 'CONFIRMED_THROUGH\s+(\d{4}-\d{2}-\d{2})' } | Select-Object -Last 1
    if ($ct -and $ct -match 'CONFIRMED_THROUGH\s+(\d{4}-\d{2}-\d{2})') {
        $through = [datetime]::Parse($Matches[1])
        if ((Get-Date) -gt $through) {
            Ng ("확정 범위를 지났습니다 (표시: {0}). 목록을 갱신하세요." -f $through.ToString('yyyy-MM-dd'))
        } else {
            $left = ($through - (Get-Date)).Days
            if ($left -le 60) { Wn ("확정 범위가 {0}일 남았습니다 ({1})" -f $left, $through.ToString('yyyy-MM-dd')) }
            else { Ok ("확정 범위 {0} 까지 ({1}일 남음)" -f $through.ToString('yyyy-MM-dd'), $left) }
        }
    } else {
        Wn "CONFIRMED_THROUGH 표시가 없습니다 - 목록이 어디까지 확정인지 알 수 없음"
    }

    # 연도별 대체공휴일 포함 여부 (본 공휴일만 있으면 대체가 빠진 것)
    foreach ($y in @($thisYear, $thisYear + 1)) {
        if ($years -notcontains $y) { continue }
        $sub = @($raw | Where-Object { $_ -match ("^{0}-" -f $y) -and $_ -match '대체' })
        if ($sub.Count -eq 0) {
            Wn ("{0}년에 대체공휴일이 하나도 없습니다 - 관보 확정 후 채워야 합니다" -f $y)
        }
    }
}

# 2. 최근 발송 결과
Write-Host "`n[2] 최근 발송 (최근 10회)"
foreach ($set in @(
    @{ N='출근'; F=Join-Path $logDir 'hiworks_self_greeting_queue.log' },
    @{ N='퇴근'; F=Join-Path $logDir 'hiworks_end_message_queue.log' })) {
    if (!(Test-Path $set.F)) { Wn "$($set.N) 큐 로그 없음"; continue }
    $lines = Get-Content $set.F -Encoding UTF8 -Tail 400
    $done = @($lines | Select-String 'finished with exit code: (\d+)' | Select-Object -Last 10)
    if ($done.Count -eq 0) { Wn "$($set.N) 발송 기록 없음"; continue }
    $fail = @($done | Where-Object { $_.Matches[0].Groups[1].Value -ne '0' }).Count
    if ($fail -eq 0) { Ok "$($set.N) 최근 $($done.Count)회 전부 성공" }
    else { Ng "$($set.N) 최근 $($done.Count)회 중 $fail 회 실패" }
    $last = $done[-1].Line
    if ($last -match '^\[([\d\- :]+)\]') { Write-Host "       마지막: $($Matches[1])" -ForegroundColor DarkGray }
}

# 3. 지터 / 문구 변형
Write-Host "`n[3] 지터 · 문구 변형"
$jit = @(Get-ChildItem $logDir -Filter '*queue.log' | ForEach-Object {
    Get-Content $_.FullName -Encoding UTF8 -Tail 200 | Select-String 'Jitter (-?\d+)m' })
if ($jit.Count -eq 0) { Wn "아직 적용 기록 없음 (다음 실행부터 반영됩니다)" }
else {
    $vals = $jit | ForEach-Object { [int]$_.Matches[0].Groups[1].Value }
    Ok ("지터 동작 중 - 최근 {0}회, 값 {1}" -f $vals.Count, (($vals | Select-Object -Last 6) -join ', '))
    if (($vals | Select-Object -Unique).Count -eq 1 -and $vals.Count -ge 4) {
        Wn "지터 값이 계속 같습니다 - Get-Random 이 안 도는지 확인"
    }
}
$msg = @(Get-ChildItem $logDir -Filter '*queue.log' | ForEach-Object {
    Get-Content $_.FullName -Encoding UTF8 -Tail 200 | Select-String 'message prepared: (.+)$' })
if ($msg.Count -eq 0) { Wn "문구 선택 기록 없음 (다음 실행부터 반영됩니다)" }
else {
    $texts = $msg | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    Ok ("문구 변형 동작 중 - 최근 {0}회, 서로 다른 문구 {1}종" -f $texts.Count, ($texts | Select-Object -Unique).Count)
    $texts | Select-Object -Last 3 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
}
$picker = @(Get-ChildItem $logDir -Filter '*queue.log' | ForEach-Object {
    Get-Content $_.FullName -Encoding UTF8 -Tail 200 | Select-String 'Message picker failed' })
if ($picker.Count -gt 0) { Wn "문구 선택기 실패 $($picker.Count)회 - 기본 문구로 폴백됐습니다" }

# 4. 마커 잔재
Write-Host "`n[4] 마커 잔재"
$markerPath = 'C:\Scripts\hiworks_marker_request.json'
if (Test-Path $markerPath) {
    $age = (Get-Date) - (Get-Item $markerPath).LastWriteTime
    Ng ("마커가 {0:n0}분째 남아 있습니다: {1}" -f $age.TotalMinutes, $markerPath)
    Write-Host "       다음 'Launch Apps 1250' 이 이걸 처리하고" -ForegroundColor Red
    Write-Host "       'Normal launch flow skipped' 로 앱 실행과 출근 인사 큐를" -ForegroundColor Red
    Write-Host "       통째로 건너뜁니다. 12:50 전에 지우세요." -ForegroundColor Red
} else {
    Ok "남아 있는 마커 없음"
}
# 최근 마커 처리에서 launch flow 가 스킵된 날이 있는지
$skipped = @(Get-Content (Join-Path $logDir 'hiworks_marker_task.log') -Encoding UTF8 -Tail 200 -EA SilentlyContinue |
    Select-String 'Normal launch flow skipped')
if ($skipped.Count -gt 0) {
    $last = $skipped[-1].Line
    if ($last -match '^\[([\d\- :]+)\]') {
        $when = [datetime]::Parse($Matches[1])
        if ($when.Date -eq (Get-Date).Date -and $when.Hour -eq 12 -and $when.Minute -ge 45) {
            Ng ("오늘 12:50 실행이 마커 때문에 스킵됐습니다: {0}" -f $when.ToString('HH:mm:ss'))
        } else {
            Write-Host ("       (참고) 마지막 launch flow 스킵: {0}" -f $when.ToString('MM-dd HH:mm')) -ForegroundColor DarkGray
        }
    }
}

# 5. 계정 검사
Write-Host "`n[5] 계정 검사"
$detected = @(Get-ChildItem $logDir -Filter '*uia*.log' | ForEach-Object {
    Get-Content $_.FullName -Encoding UTF8 | Select-String 'Detected Hiworks account: (.+)$' })
if ($detected.Count -eq 0) {
    Ok "계정명이 UIA 에 노출되지 않아 검사는 꺼진 상태 (현재 정상)"
} else {
    $names = $detected | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } | Select-Object -Unique
    Wn ("계정명이 읽히기 시작했습니다: {0}" -f ($names -join ', '))
    Write-Host "       send_hiworks_self_greeting.ps1 의 ExpectedAccountName 을" -ForegroundColor DarkGray
    Write-Host "       위 값으로 넣으면 계정 검사를 되살릴 수 있습니다." -ForegroundColor DarkGray
}

Write-Host ""
if ($warn -eq 0) { Write-Host "이상 없음" -ForegroundColor Green }
else { Write-Host "확인할 항목 $warn 건" -ForegroundColor Yellow }
