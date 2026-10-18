<#
====================================================================
 Windows PowerShell 5.1 대상 정적 검사

 PowerShell 7 에서 통과해도 5.1 에서 깨지는 것들을 잡는다.
   .\lint-ps51.ps1 -Path C:\scripts
====================================================================
#>
param([string[]]$Path = @('C:\scripts'))

$issues = New-Object System.Collections.Generic.List[object]
function Add-Issue($file,$sev,$rule,$msg,$line=0) {
    $issues.Add([PSCustomObject]@{ File=$file; Sev=$sev; Rule=$rule; Line=$line; Msg=$msg })
}

# PS7 전용 구문 (5.1 에서 ParserError 또는 CommandNotFound)
$ps7only = @(
    @{ N='ternary';        P='[^=!<>]\?\s+[^\s].*\s:\s';        M='삼항 연산자 ? : 는 PS7 전용' }  # lint:ignore
    @{ N='null-coalesce';  P='\?\?';                             M='?? / ??= 는 PS7 전용' }  # lint:ignore
    @{ N='null-conditional';P='\$\w+\?\.';                       M='?. 는 PS7 전용' }  # lint:ignore
    @{ N='parallel';       P='ForEach-Object\s+-Parallel';       M='-Parallel 은 PS7 전용' }  # lint:ignore
    @{ N='enc-name';       P='-Encoding\s+(utf8NoBOM|utf8BOM|ansi)'; M='이 -Encoding 값은 PS7 전용' }  # lint:ignore
    @{ N='IsWindows';      P='\$IsWindows|\$IsLinux|\$IsMacOS';  M='$IsWindows 등은 PS7 전용' }  # lint:ignore
    @{ N='chain-op';       P='(\|\||&&)\s*$';                    M='|| && 파이프라인 체인은 PS7 전용' }  # lint:ignore
    @{ N='ConvertFrom-Json-AsHashtable'; P='-AsHashtable';        M='-AsHashtable 은 PS7(6+) 전용' }  # lint:ignore
)

$files = foreach ($p in $Path) {
    if (Test-Path $p -PathType Container) { Get-ChildItem $p -Filter *.ps1 -File -Recurse | Where-Object { $_.FullName -notmatch '\\_' } }
    elseif (Test-Path $p) { Get-Item $p }
}
$bats = foreach ($p in $Path) { if (Test-Path $p -PathType Container) { Get-ChildItem $p -Filter *.bat -File } }

foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii = $true; break } }

    # 1) BOM
    if ($nonAscii -and -not $hasBom) {
        Add-Issue $f.Name 'ERROR' 'BOM' 'ASCII 밖 문자가 있는데 UTF-8 BOM 이 없음. 5.1 이 CP949 로 읽어 깨짐'
    }
    # 2) UTF-8 로 디코드 되는지 (깨진 인코딩 혼입)
    try { [Text.Encoding]::GetEncoding('utf-8',[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback).GetString($bytes) | Out-Null }
    catch { Add-Issue $f.Name 'ERROR' 'ENCODING' 'UTF-8 로 디코드되지 않음 (인코딩 혼합 의심)' }

    # BOM 을 벗기고 파싱한다. U+FEFF 가 남으면 첫 줄 '<#' 이 깨져 전체가 오탐이 된다.
    $text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $lines = $text -split "`r?`n"

    # 3) PS7 전용 구문
    for ($i=0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*#') { continue }
        foreach ($r in $ps7only) {
            if ($l -match '#\s*lint:ignore') { continue }
            if ($l -match $r.P) { Add-Issue $f.Name 'ERROR' $r.N $r.M ($i+1) }
        }
    }

    # 4) 문법 (파서)
    $errs = $null; $toks = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
    if ($errs -and $errs.Count) {
        foreach ($e in $errs) { Add-Issue $f.Name 'ERROR' 'SYNTAX' $e.Message $e.Extent.StartLineNumber }
    }

    # 5) 정의 없는 자체 함수 호출
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
    $defined = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name }
    $called = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
    foreach ($c in ($called | Select-Object -Unique)) {
        if ($c -match '^[A-Z][a-z]+-[A-Z]' ) { continue }   # 표준 cmdlet 형태는 제외
        if ($defined -contains $c) { continue }
        if ($c -match '\.ps1$|\\|/|^\$') { continue }
        if (Get-Command $c -ErrorAction SilentlyContinue) { continue }
        if ($c -in @('Get-ScheduledTask','Set-ScheduledTask','Register-ScheduledTask','Unregister-ScheduledTask',
                     'Export-ScheduledTask','New-ScheduledTaskAction','New-ScheduledTaskTrigger',
                     'New-ScheduledTaskSettingsSet','Start-ScheduledTask','Set-Clipboard','schtasks','net')) { continue }
        Add-Issue $f.Name 'WARN' 'UNDEFINED' "정의를 못 찾은 호출: $c"
    }
}

foreach ($b in $bats) {
    $bytes = [IO.File]::ReadAllBytes($b.FullName)
    try {
        $cp949 = [Text.Encoding]::GetEncoding(949)
        $s = $cp949.GetString($bytes)
        if ($s -match '[\uFFFD]') { Add-Issue $b.Name 'ERROR' 'BAT-ENC' 'CP949 로 디코드 시 깨짐' }
    } catch { Add-Issue $b.Name 'WARN' 'BAT-ENC' 'CP949 확인 불가' }
    $crlf = ([regex]::Matches([Text.Encoding]::ASCII.GetString($bytes), "`r`n")).Count
    $lf   = ([regex]::Matches([Text.Encoding]::ASCII.GetString($bytes), "`n")).Count
    if ($lf -ne $crlf) { Add-Issue $b.Name 'ERROR' 'BAT-EOL' "LF 단독 줄바꿈 $($lf-$crlf)개 - .bat 은 CRLF 여야 함" }
}

Write-Host ("`n검사 파일: ps1 {0}개 / bat {1}개" -f @($files).Count, @($bats).Count) -ForegroundColor Cyan
$err = @($issues | Where-Object Sev -eq 'ERROR')
$wrn = @($issues | Where-Object Sev -eq 'WARN')
if ($issues.Count -eq 0) { Write-Host "이상 없음`n" -ForegroundColor Green; exit 0 }
foreach ($i in ($issues | Sort-Object Sev, File, Line)) {
    $c = if ($i.Sev -eq 'ERROR') { 'Red' } else { 'DarkYellow' }
    Write-Host ("  [{0,-5}] {1,-38} {2,-16} L{3,-4} {4}" -f $i.Sev,$i.File,$i.Rule,$i.Line,$i.Msg) -ForegroundColor $c
}
Write-Host ("ERROR {0}건 / WARN {1}건`n" -f $err.Count, $wrn.Count) -ForegroundColor $(if($err.Count){'Red'}else{'Yellow'})
exit $err.Count
