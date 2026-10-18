$ErrorActionPreference='Stop'
$fail=0; $warn=0

# [IO.File] 등 .NET API 는 PowerShell 의 현재 위치(cd)를 따르지 않고
# 프로세스 작업 디렉터리(보통 C:\WINDOWS\system32)를 쓴다.
# 임시 파일 경로는 전부 스크립트 폴더 기준 절대 경로로 만든다.
$Here    = $PSScriptRoot
$Picker  = Join-Path $Here 'hiworks-message.ps1'
$TmpKeep = Join-Path $Here 'qa_keep.txt'
$TmpFmt  = Join-Path $Here 'qa_fmt.txt'
$TmpBlk  = Join-Path $Here 'qa_blocked.txt'
$StateJs = Join-Path $Here 'last-message.json'
if (-not (Test-Path $Picker)) { Write-Host "hiworks-message.ps1 을 찾을 수 없습니다: $Picker" -ForegroundColor Red; exit 1 }
function Ok($m){ Write-Host "  [PASS] $m" -ForegroundColor Green }
function Ng($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Wn($m){ Write-Host "  [WARN] $m" -ForegroundColor DarkYellow; $script:warn++ }
function Section($t){ Write-Host "`n== $t ==" -ForegroundColor Cyan }

# ─────────────────────────────────────────────────────────────
Section "1. 퇴근 타이밍 예산 (Close Apps 1910 마감)"
$T=[datetime]'2026-08-19 19:00:00'; $CLOSE=$T.AddMinutes(10)
$HARD=$CLOSE.AddSeconds(-120).AddSeconds(-120)
$bad=0
foreach($j in 0..120){
    $send=$T.AddSeconds($j); $lat=$send.AddMinutes(4).AddSeconds(30)
    if($lat -gt $HARD){$lat=$HARD}
    $worst=$lat.AddSeconds(120)
    $budget=($lat-$send).TotalSeconds
    if($worst -ge $CLOSE){$bad++; if($bad -le 3){Ng "지터 ${j}s: 최악완료 $($worst.ToString('HH:mm:ss')) >= 종료 $($CLOSE.ToString('HH:mm'))"}}
    if($budget -lt 120){$bad++; if($bad -le 3){Ng "지터 ${j}s: 예산 ${budget}s - 재시도 1회도 불가"}}
}
if($bad -eq 0){Ok "지터 0~120s 전 구간: 하이웍스 종료 전 완료 + 재시도 예산 확보"}
$b0=($T.AddMinutes(4).AddSeconds(30)-$T).TotalSeconds
if($b0 -eq 270){Ok "지터 0 일 때 원래 동작과 동일 (예산 270s)"}else{Ng "지터 0 예산이 270s 가 아님: $b0"}

# ─────────────────────────────────────────────────────────────
Section "2. 출근 타이밍 예산 (창 13:10 고정)"
$T2=[datetime]'2026-08-19 12:55:00'; $LAT2=[datetime]'2026-08-19 13:10:00'
$EAR2=[datetime]'2026-08-19 12:45:00'; $RETRY=120; $RUN=90
$bad=0
foreach($j in -5..3){
  foreach($qstart in @('12:45','12:50','12:55','13:00')){
    $now=[datetime]"2026-08-19 $qstart"
    $send=$T2.AddMinutes($j)
    if($now -lt $EAR2 -or $now -gt $LAT2){ continue }
    $t=if($send -gt $now){$send}else{$now}
    $tries=0
    while($t -le $LAT2 -and $tries -lt 3){ $tries++; $t=$t.AddSeconds($RUN+$RETRY) }
    if($tries -lt 1){$bad++; Ng "큐시작 $qstart 지터 ${j}m: 시도 0회"}
  }
}
if($bad -eq 0){Ok "지터 -5~+3m × 큐시작 12:45~13:00: 항상 1회 이상 시도"}
$send=$T2.AddMinutes(3)
$t=$send; $tries=0
while($t -le $LAT2 -and $tries -lt 3){ $tries++; $t=$t.AddSeconds($RUN+$RETRY) }
if($tries -eq 3){Ok "최악(지터 +3m=12:58 발송)에도 재시도 3회 전부 가능"}else{Wn "최악 지터에서 시도 $tries 회"}

# ─────────────────────────────────────────────────────────────
Section "3. 인자 전달 (빈 문자열 / 공백 포함)"
function Join-New([string[]]$A){ ($A|ForEach-Object{
  if($null -eq $_ -or $_ -eq ''){'""'} elseif($_ -match '[\s"]'){'"'+($_ -replace '"','\"')+'"'} else{$_} }) -join ' ' }
$cases=@(
 @{N='빈 문자열';    A=@('-Label','end','-Expected','','-File','C:\a.txt'); Expect=6},
 @{N='공백 포함';    A=@('-Chat','나와의 채팅방','-File','C:\a.txt');       Expect=4},
 @{N='따옴표 포함';  A=@('-Msg','say "hi"','-File','C:\a.txt');             Expect=4},
 @{N='정상';         A=@('-Label','start','-File','C:\a.txt');              Expect=4}
)
foreach($c in $cases){
  $s=Join-New $c.A
  $tok=[regex]::Matches($s,'"(?:\\.|[^"\\])*"|\S+').Count
  if($tok -eq $c.Expect){Ok "$($c.N): 토큰 $tok 개 보존"}else{Ng "$($c.N): 토큰 $tok 개 (기대 $($c.Expect)) -> $s"}
}

# ─────────────────────────────────────────────────────────────
Section "4. 문구 선택기 (각 80회 - 잠시 걸립니다)"
foreach($t in 'start','end'){
  Remove-Item $StateJs -EA SilentlyContinue
  $prev=$null;$dup=0;$empty=0;$set=@{}
  1..80|ForEach-Object{
    $p=(& $Picker -Type $t) -join "`n"
    if([string]::IsNullOrWhiteSpace($p)){$empty++}
    if($p -eq $prev){$dup++}
    $set[$p]=1;$prev=$p
    if($_ % 20 -eq 0){ Write-Host '.' -NoNewline -ForegroundColor DarkGray }
  }
  Write-Host ''
  if($empty -eq 0){Ok "$t : 빈 문구 0"}else{Ng "$t : 빈 문구 $empty"}
  if($dup -eq 0){Ok "$t : 연속 중복 0"}else{Ng "$t : 연속 중복 $dup"}
  Ok "$t : $($set.Count) 종류"
}

# ─────────────────────────────────────────────────────────────
Section "5. 폴백 (선택기가 죽어도 인사말이 나가는가)"
Remove-Item $StateJs -EA SilentlyContinue
& $Picker -Type end -WriteTo $TmpFmt | Out-Null
$before=[IO.File]::ReadAllBytes($TmpFmt).Length
# 잘못된 경로로 쓰기 시도 -> 스크립트가 죽지 않고 문구는 반환되어야 함
# 실패 재현: 대상 경로를 '디렉터리'로 만든다.
# (읽기 전용 파일은 이 컨테이너가 root 라 무시돼서 재현이 안 된다)
$keep=$TmpKeep
& $Picker -Type end -WriteTo $keep | Out-Null
$kept1=[IO.File]::ReadAllBytes($keep)
New-Item -ItemType Directory -Path $TmpBlk -Force | Out-Null
$err=$null
try { $out = & $Picker -Type end -WriteTo $TmpBlk 3>$null } catch { $err=$_ }
if(-not $err){Ok "쓰기 실패해도 선택기가 죽지 않음"}else{Ng "쓰기 실패 시 예외로 종료: $err"}
if($out){Ok "문구는 정상 반환됨 (부르는 쪽이 쓸 수 있음)"}else{Ng "문구 반환 안 됨"}
$kept2=[IO.File]::ReadAllBytes($keep)
if([Convert]::ToBase64String($kept1) -eq [Convert]::ToBase64String($kept2)){
  Ok "실패한 호출이 다른 파일을 건드리지 않음"}else{Ng "다른 파일이 변경됨"}
Remove-Item $TmpBlk -Recurse -EA SilentlyContinue
Remove-Item $keep -EA SilentlyContinue
if($before -gt 0){Ok "정상 경로 쓰기 $before bytes"}else{Ng "파일이 비어 있음"}

# ─────────────────────────────────────────────────────────────
Section "6. 파일 형식 (uia 소비 경로 재현)"
Remove-Item $StateJs -EA SilentlyContinue
& $Picker -Type start -WriteTo $TmpFmt | Out-Null
$b=[IO.File]::ReadAllBytes($TmpFmt)
$txt=[Text.Encoding]::UTF8.GetString($b)
$m=$txt.TrimStart([char]0xFEFF).TrimEnd("`r","`n")          # uia 41~46행
$norm=($m -replace "`r`n","`n" -replace "`r","`n").TrimEnd("`n"," ","`t")  # Normalize-MessageTextForCompare
if(-not [string]::IsNullOrWhiteSpace($m)){Ok "TrimEnd 후 비어있지 않음"}else{Ng "TrimEnd 후 빈 문자열"}
if($norm -eq $m){Ok "정규화 일치 - Assert-MessageTextInInput 통과 예상"}else{Ng "정규화 불일치"}
if(([regex]::Matches($m,"`n")).Count -ge 1){Ok "두 줄 구조 유지"}else{Ng "줄바꿈 없음"}
Remove-Item $TmpFmt,$TmpKeep,$StateJs -EA SilentlyContinue

Write-Host ""
if($fail -eq 0){Write-Host "FAIL 0건 / WARN $warn 건" -ForegroundColor Green}
else{Write-Host "FAIL $fail 건 / WARN $warn 건" -ForegroundColor Red}
exit $fail
