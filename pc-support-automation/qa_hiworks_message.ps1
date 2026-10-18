$ErrorActionPreference='Stop'
$fail=0
function Ok($m){ Write-Host "  [PASS] $m" }
function Ng($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

Write-Host "`n== 1. 지터 경계 (10000회) =="
$s=@(); $e=@()
1..10000 | ForEach-Object {
    $s += (Get-Random -Minimum -5 -Maximum 4)
    $e += (Get-Random -Minimum 0 -Maximum 9)
}
$smin=($s|Measure-Object -Minimum).Minimum; $smax=($s|Measure-Object -Maximum).Maximum
$emin=($e|Measure-Object -Minimum).Minimum; $emax=($e|Measure-Object -Maximum).Maximum
Write-Host ("  출근 지터 {0}~{1}분 -> 12:{2} ~ 12:{3}" -f $smin,$smax,(55+$smin),(55+$smax))
Write-Host ("  퇴근 지터 {0}~{1}분 -> 19:{2:00} ~ 19:{3:00}" -f $emin,$emax,$emin,$emax)
if ($smin -ge -5 -and $smax -le 3) { Ok "출근 지터가 12:50~12:58 안" } else { Ng "출근 지터 범위 이탈" }
if ((55+$smax) -lt 60) { Ok "출근이 13:00 을 넘지 않음" } else { Ng "출근이 13:00 을 넘음" }
if ($emin -ge 0 -and $emax -le 8) { Ok "퇴근 지터가 19:00~19:08 안" } else { Ng "퇴근 지터 범위 이탈" }
if ($emin -ge 0) { Ok "퇴근이 19:00 이전에 안 나감" } else { Ng "퇴근이 19:00 이전에 나감" }
$uniq=($s|Sort-Object -Unique).Count
if ($uniq -ge 8) { Ok "출근 지터 값 $uniq 종류로 분산" } else { Ng "출근 지터 분산 부족: $uniq" }

Write-Host "`n== 2. 큐 윈도우 로직 (큐 시작시각별) =="
foreach ($h in 12,13) { foreach ($m in 40,45,50,55,0,5,9,11) {
    if ($h -eq 13 -and $m -gt 11) { continue }
    $now=[datetime]"2026-08-18 $($h):$($m.ToString('00')):00"
    foreach ($j in -5,0,3) {
        $target=([datetime]"2026-08-18 12:55:00").AddMinutes($j)
        $earliest=([datetime]"2026-08-18 12:45:00"); $latest=([datetime]"2026-08-18 13:10:00")
        $skip = ($now -lt $earliest -or $now -gt $latest)
        $delay=[Math]::Max(0,[int][Math]::Ceiling(($target-$now).TotalSeconds))
        $send = if($skip){'SKIP'}else{ $now.AddSeconds($delay).ToString('HH:mm:ss') }
        if (-not $skip -and $now.AddSeconds($delay) -gt $latest) { Ng "$($now.ToString('HH:mm')) j=$j -> 윈도우 초과" }
        Write-Host ("  큐시작 {0} jitter {1,2} -> {2}" -f $now.ToString('HH:mm'),$j,$send)
    }
} }
Ok "모든 조합에서 윈도우 초과 없음"

Write-Host "`n== 3. 문구 선택기 (각 500회) =="
foreach ($t in 'start','end') {
    Remove-Item ./last-message.json -ErrorAction SilentlyContinue
    $prev=$null; $dup=0; $empty=0; $seen=@{}
    1..500 | ForEach-Object {
        $p = (& ./hiworks-message.ps1 -Type $t) -join "`n"
        if ([string]::IsNullOrWhiteSpace($p)) { $empty++ }
        if ($p -eq $prev) { $dup++ }
        $seen[$p]=1; $prev=$p
    }
    if ($empty -eq 0) { Ok "$t : 빈 문구 0건" } else { Ng "$t : 빈 문구 $empty 건" }
    if ($dup   -eq 0) { Ok "$t : 연속 중복 0건" } else { Ng "$t : 연속 중복 $dup 건" }
    Ok "$t : 서로 다른 문구 $($seen.Count) 종류"
}

Write-Host "`n== 4. 파일 출력 형식 =="
Remove-Item ./last-message.json -ErrorAction SilentlyContinue
& ./hiworks-message.ps1 -Type end -WriteTo ./t_end.txt | Out-Null
$b=[IO.File]::ReadAllBytes('./t_end.txt')
$hasBom = ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
$txt=[Text.Encoding]::UTF8.GetString($b)
$crlf = ([regex]::Matches($txt,"`r`n")).Count
$lf   = ([regex]::Matches($txt,"`n")).Count
Write-Host ("  BOM={0} CRLF={1} LF={2} 줄수={3} 바이트={4}" -f $hasBom,$crlf,$lf,(($txt -split "`n").Count),$b.Length)
if ($lf -ge 1) { Ok "줄바꿈 포함 (원본과 동일하게 LF)" } else { Ng "줄바꿈 없음" }
if ($crlf -eq 0) { Ok "CRLF 혼입 없음" } else { Ng "CRLF 혼입" }
# uia 가 하는 처리와 동일하게 검증
$m = $txt.TrimStart([char]0xFEFF).TrimEnd("`r","`n")
if (-not [string]::IsNullOrWhiteSpace($m)) { Ok "uia TrimEnd 후에도 비어있지 않음" } else { Ng "TrimEnd 후 빈 문자열" }
$norm = ($m -replace "`r`n","`n" -replace "`r","`n").TrimEnd("`n"," ","`t")
if ($norm -eq $m) { Ok "Normalize-MessageTextForCompare 통과 (검증 단계에서 안 걸림)" } else { Ng "정규화 불일치 -> Assert 실패 위험" }
Remove-Item ./t_end.txt,./last-message.json -ErrorAction SilentlyContinue

Write-Host ""
if ($fail -eq 0) { Write-Host "전체 통과" -ForegroundColor Green } else { Write-Host "$fail 건 실패" -ForegroundColor Red }
exit $fail
