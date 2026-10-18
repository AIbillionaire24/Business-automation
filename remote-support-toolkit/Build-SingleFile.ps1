<#
========================================================================
 Build-SingleFile.ps1  
 편집용 마스터(.ps1) → 배포용 단일 .bat 한 개로 굽는다.

 왜 필요한가
   애니서포트 파일전송을 2번(.bat + .ps1) 하던 것을 1번으로 줄인다.
   결과물은 더블클릭으로 바로 실행되고, UAC 승격도 자기가 한다.

 원리 (batch / PowerShell 폴리글롯)
   1행 '<# :' 은 cmd 에겐 '# 로부터 입력 리디렉션 + 레이블'(=아무 일도 안 함),
   PowerShell 에겐 블록주석 시작이다. 그래서 같은 파일을 둘 다 읽을 수 있다.
   cmd 는 헤더 몇 줄만 읽고 'exit /b' 로 빠지므로 아래쪽 PowerShell 코드의
   % 나 특수문자를 cmd 가 건드릴 일이 없다.

 절대 지켜야 할 것 (안 지키면 조용히 깨진다)
   · BOM 없는 UTF-8   : BOM 이 있으면 cmd 가 1행을 못 읽는다
   · CRLF 줄바꿈       : LF 만 있으면 cmd 가 줄 중간부터 실행한다(실측 확인)
   · 헤더는 ASCII 전용 : 본문은 UTF-8 인데 cmd 는 cp949 로 출력하므로 한글은 깨진다
   이래서 결과 .bat 을 손으로 편집하면 안 된다. 항상 마스터 .ps1 을 고치고 다시 빌드할 것.

 사용법
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-SingleFile.ps1
   (-Source 로 특정 버전 지정 가능. 생략하면 폴더에서 가장 최근 수정된 버전)
========================================================================
#>
param(
    [string]$Source,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $OutFile) { $OutFile = Join-Path $root '원격지원.bat' }

# ── 소스 선택: Run-Toolkit.bat 과 같은 규칙(수정시각 최신) ──────────────
if (-not $Source) {
    $Source = Get-ChildItem (Join-Path $root 'Remote-Support-Toolkit*.ps1') -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Source -or -not (Test-Path $Source)) { throw "마스터 .ps1 을 못 찾음: $root" }

# ── cmd 가 읽을 헤더. ASCII 전용. ────────────────────────────────────
#  · RST_SELF : 자기 경로. 본문의 메뉴0 자기삭제가 이 값을 쓴다.
#  · 관리자 판별을 batch 가 아니라 PowerShell 에 맡긴다.
#    'net session' 은 Server 서비스가 꺼져 있으면 관리자여도 실패해서 승격 창이
#    계속 다시 뜬다. 본문 첫 줄이 쓰는 것과 같은 API 로 판별하는 편이 일관된다.
#    ★ 2026-09-08 수정: IsInRole 에 문자열 'Administrator' 를 넘기고 있었다. 문자열
#      오버로드는 그룹 이름을 글자 그대로 찾는데 실제 그룹명은 'Administrators'(복수)라
#      승격한 뒤에도 계속 False → 자기를 또 RunAs 로 띄우고, 이미 관리자라 UAC 창도
#      안 뜨니 즉시 반복 = 무한 루프였다. 실측 근거: IsInRole('Users')=True 인데
#      IsInRole('User')=False → 이름을 글자 그대로 찾는다는 뜻. 본문은 enum 을 써서
#      멀쩡했고 헤더만 틀렸다 → 여기도 [WindowsBuiltInRole]::Administrator 로 통일.
#  · 재진입 가드: 승격할 때 '-elevated' 인자를 붙여 보낸다. 판별이 또 어긋나도 두 번째
#    실행에서 메시지를 띄우고 멈춘다. 선생님 PC 에서 창이 무한히 열리는 것보다 낫다.
#    ※ 가드는 반드시 '인자'로 넘길 것 - UAC 승격은 부모 환경변수를 물려주지 않는다.
#  · 'exit /b' 를 powershell 과 같은 줄에 둔다. 다음 줄을 읽으려고 cmd 가 파일을
#    다시 열면, 자기삭제로 파일이 사라진 뒤라 "배치 파일을 찾을 수 없습니다"가 뜬다.
$header = @(
    '<# :',
    '@echo off',
    'setlocal',
    'set "RST_SELF=%~f0"',
    'set "RST_ARG=%~1"',
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Invoke-Expression ([IO.File]::ReadAllText($env:RST_SELF,[Text.Encoding]::UTF8)); exit}; if($env:RST_ARG -eq ''-elevated''){Write-Host ''Could not obtain administrator rights.'' -ForegroundColor Red; Write-Host ''Right-click the file and choose Run as administrator.'' -ForegroundColor Yellow; Read-Host ''Press Enter to close''; exit}; try{Start-Process -FilePath $env:RST_SELF -ArgumentList ''-elevated'' -Verb RunAs}catch{Write-Host ''Elevation cancelled.'' -ForegroundColor Yellow; Read-Host ''Press Enter to close''}" & exit /b',
    ': #>'
)

# ── 본문: BOM 제거 + 줄바꿈 CRLF 통일 ─────────────────────────────────
$body = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8)
$body = $body.TrimStart([char]0xFEFF)

# ── 배포본에서는 주석을 전부 걷어낸다 (2026-09-08 신설) ──────────────
#  이 파일은 선생님 PC 로 올라간다. 주석에는 다른 선생님 실명·계정 ID·사내 판단 기준이
#  들어 있다(실측: 실명 6명 + 계정 ID 1건 + '손 떼는 기준' 원문). 화면에 안 뜬다고
#  안전한 게 아니다 - 메모장으로 열면 그대로 읽힌다. 자기삭제 전에 열어볼 수도 있다.
#  편집용 마스터(.ps1)는 손대지 않는다. 주석은 거기 남아야 다음에 왜 그랬는지 안다.
#  ※ 토크나이저가 짚어준 '주석 토큰'만 지운다. 문자열 안의 # 이나 here-string 내용은
#    주석이 아니므로 안 건드린다(정규식으로 지우면 그걸 못 가른다).
#  ※ 줄바꿈은 남긴다. 배포본 줄번호가 마스터와 같은 간격으로 어긋나야 오류를 대조할 수 있다.
$ctok = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$ctok, [ref]$null)
$cmts = @($ctok | Where-Object { $_.Kind -eq 'Comment' })
$sb   = New-Object System.Text.StringBuilder($body)
foreach ($c in ($cmts | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    [void]$sb.Remove($c.Extent.StartOffset, $c.Extent.EndOffset - $c.Extent.StartOffset)
}
$body = $sb.ToString()
$stripped = $cmts.Count

$body = ($body -replace "`r`n", "`n") -replace "`n", "`r`n"

$out = ($header -join "`r`n") + "`r`n" + $body
[IO.File]::WriteAllText($OutFile, $out, (New-Object Text.UTF8Encoding($false)))

# ── 검증: 위 4가지 조건을 실제로 확인한다 ────────────────────────────
$fail = @()
$bytes = [IO.File]::ReadAllBytes($OutFile)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $fail += 'BOM 이 붙었다' }

$text = [IO.File]::ReadAllText($OutFile, [Text.Encoding]::UTF8)
$lone = 0
for ($i = 0; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq "`n" -and ($i -eq 0 -or $text[$i-1] -ne "`r")) { $lone++ }
}
if ($lone) { $fail += "CRLF 아닌 줄바꿈 $lone 개" }

foreach ($h in $header) { if ($h -match '[^\x20-\x7E]') { $fail += "헤더에 ASCII 아닌 문자: $h" } }

# 승격 판별이 enum 인지 못 박는다. 문자열 'Administrator' 를 넘기면 실제 그룹명이
#  'Administrators'(복수)라 승격 뒤에도 False → 자기를 무한히 다시 띄운다(2026-09-08 실측).
#  조용히 깨지고 빌드 검증만으로는 안 드러나던 자리라 여기서 막는다.
$hdr = $header -join "`n"
if ($hdr -match "IsInRole\('")                          { $fail += "승격 판별에 문자열을 넘긴다 = 무한 루프. enum 을 쓸 것" }
if ($hdr -notmatch 'WindowsBuiltInRole\]::Administrator'){ $fail += "승격 판별 enum 이 없다" }
if ($hdr -notmatch '\-elevated')                        { $fail += "재진입 가드(-elevated)가 없다" }

# 헤더가 '<# ... #>' 안에 들어가므로 결과 .bat 전체가 PowerShell 로도 파싱돼야 정상이다
# 주석이 실제로 다 빠졌는지 확인한다. 헤더의 '<# : ... : #>' 는 폴리글롯 구조라 예외.
$ct2 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$ct2, [ref]$null)
$hdrLen = (($header -join "`r`n") + "`r`n").Length
$leftCmt = @($ct2 | Where-Object { $_.Kind -eq 'Comment' -and $_.Extent.StartOffset -ge $hdrLen }).Count
if ($leftCmt) { $fail += "배포본에 주석 $leftCmt 개가 남았다(실명·사내 문구 유출 경로)" }

$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
if ($errs) { $fail += ("PowerShell 파싱 오류 {0}건 (첫 줄 {1})" -f $errs.Count, $errs[0].Extent.StartLineNumber) }

# ── 배포 금지 단어 검사 (2026-09-17 신설) ─────────────────────────────
#  위의 '주석 제거'는 주석만 걷는다. Write-Host 문자열에 박아넣은 선생님 실명은 안 걷힌다.
#  실측: v3.6.6 빌드 결과 .bat 에서 다른 선생님 실명 4곳이 화면 출력 문구로 남아 있었다
#  (9/11·9/16 사례를 근거로 적으면서 이름을 그대로 썼다).
#  → deploy-blocklist.txt 의 단어가 배포본에 하나라도 남으면 빌드를 실패시킨다.
#  목록 파일 자체는 마스터 폴더에만 두고 배포하지 않는다.
$blockFile = Join-Path $root 'deploy-blocklist.txt'
$blockHits = @()
if (Test-Path $blockFile) {
    $words = @(Get-Content $blockFile -Encoding UTF8 |
               Where-Object { $_.Trim() -and $_.TrimStart() -notmatch '^#' } |
               ForEach-Object { $_.Trim() })
    foreach ($w in $words) {
        $n = ([regex]::Matches($text, [regex]::Escape($w))).Count
        if ($n) { $blockHits += ("{0} ({1}건)" -f $w, $n) }
    }
    if ($blockHits) {
        $fail += ("배포 금지 단어가 남았다: {0}" -f ($blockHits -join ' / '))
        $fail += "  → 주석이 아니라 Write-Host 등 '코드 문자열' 안에 있다. 마스터에서 문구를 고칠 것"
    }
} else {
    Write-Host "  [주의] deploy-blocklist.txt 가 없어 실명 검사를 건너뜁니다." -ForegroundColor DarkYellow
}

# 마스터의 메뉴 제목(=버전) 확인. 제목이 파일명과 어긋나면 현장에서 오판한다.
$ver = if ($text -match '원격지원 툴킷 (v[\d.]+ \([\d-]+\))') { $matches[1] } else { '(제목에서 버전 못 읽음)' }

Write-Host ""
Write-Host "  소스   : $(Split-Path $Source -Leaf)"      -ForegroundColor Gray
Write-Host "  버전   : $ver"                             -ForegroundColor Gray
Write-Host "  주석   : $stripped 개 제거(실명·사내 문구 배포 차단)" -ForegroundColor Gray
if (Test-Path $blockFile) {
    Write-Host ("  금지어 : {0}" -f $(if ($blockHits) { "★{0}건 발견" -f $blockHits.Count } else { "0건 (deploy-blocklist.txt 기준 통과)" })) `
        -ForegroundColor $(if ($blockHits) { 'Red' } else { 'Gray' })
}
Write-Host "  결과   : $OutFile"                         -ForegroundColor Gray
Write-Host ("  크기   : {0:N0} KB" -f ($bytes.Length/1KB)) -ForegroundColor Gray
if ($fail) {
    Write-Host "`n  [실패] 배포하지 말 것:" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`n  [검증 통과] BOM 없음 / CRLF / 헤더 ASCII / PowerShell 파싱 정상" -ForegroundColor Green
Write-Host "  → 이 파일 하나만 애니서포트로 전송하면 됩니다.`n" -ForegroundColor Cyan
