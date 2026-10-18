<#
========================================================================
 Check-Program.ps1   v1.0 - 2026-08-27
 "이거 지워도 되나?" 를 판별하는 조회 전용 스크립트. 삭제는 하지 않는다.

 왜 만들었나 (2026-08-26 교사L 교사 건 실측)
   · 'v_service uninstall' → 실체는 레지스트리 키 v_grid_setup (그리드딜리버리).
     표시명만 보면 VCam 구성요소로 오판한다. 키 이름을 같이 봐야 갈린다.
   · 'FSSADK Client for ROYALROADER' → 이름만 보면 정체 불명인데
     Publisher 가 Fasoo.com (파수 DRM) 이었다. 게시자 한 줄이 판정을 끝낸다.
   · 언인스톨러 파일이 이미 없는 고아 항목은 프로그램추가/제거에서 절대 안 지워진다.
     먼저 알아야 레지스트리 정리로 넘어간다.

 사용법 (관리자 PowerShell)
   .\Check-Program.ps1                 전체 목록 + 판정
   .\Check-Program.ps1 -Name fasoo     이름·게시자에 fasoo 가 들어간 것만
   .\Check-Program.ps1 -Suspect        판정이 필요한 것만 (고아·게시자없음)
   .\Check-Program.ps1 -Detail vcam    한 항목 깊이 파기(서명·폴더·서비스·자동시작)

 판정 열 읽는 법
   [고아]    언인스톨러 exe 가 없다 → UI 제거 불가. 레지스트리 키 직접 삭제 대상
   [무게시자] Publisher 비어 있음 → 이름만으로 판단 금지. -Detail 로 서명 확인
   [MSI]     MsiExec 제거 → 조용한 제거 가능 (/X{GUID} /qn)
   [사용자]  HKCU 등록 → 이 계정에만 설치됨
========================================================================
#>
param(
    [string]$Name,
    [string]$Detail,
    [switch]$Suspect
)

$ErrorActionPreference = 'SilentlyContinue'

# ── 등록 정보 수집 ───────────────────────────────────────────────────
function Get-ProgList {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $paths | Where-Object {
        $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName
    } | ForEach-Object {
        $key  = Split-Path $_.PSPath -Leaf
        $hive = if ($_.PSPath -match 'HKEY_CURRENT_USER') { 'HKCU' } else { 'HKLM' }
        $us   = $_.UninstallString

        # 언인스톨러 실체 확인. MSI 는 GUID 라 파일이 없어도 정상이다.
        $isMsi = $us -match 'MsiExec'
        $exe   = $null
        $orphan = $false
        if ($us -and -not $isMsi) {
            if ($us -match '"([^"]+\.exe)"') { $exe = $matches[1] }
            elseif ($us -match '^([^\s]+\.exe)') { $exe = $matches[1] }
            if ($exe) { $orphan = -not (Test-Path -LiteralPath $exe) }
        }

        $flag = @()
        if ($orphan)            { $flag += '고아' }
        if (-not $_.Publisher)  { $flag += '무게시자' }
        if ($isMsi)             { $flag += 'MSI' }
        if ($hive -eq 'HKCU')   { $flag += '사용자' }

        # 표시명과 레지스트리 키 이름이 다르면 실체 판단에 쓴다
        $keyHint = ''
        if ($key -notmatch '^\{' -and $_.DisplayName -notlike "*$key*") { $keyHint = $key }

        [pscustomobject]@{
            이름     = $_.DisplayName
            게시자   = $_.Publisher
            버전     = $_.DisplayVersion
            설치일   = $_.InstallDate
            키이름   = $keyHint
            판정     = ($flag -join '·')
            설치경로 = $_.InstallLocation
            제거     = $us
            PSPath   = $_.PSPath
        }
    }
}

# ── 상세: 게시자가 없거나 이름만으로 못 정할 때 ─────────────────────
function Show-Detail([string]$q) {
    $t = Get-ProgList | Where-Object { $_.이름 -match $q -or $_.키이름 -match $q }
    if (-not $t) { Write-Host "`n일치 항목 없음: $q`n" -ForegroundColor DarkYellow; return }

    foreach ($p in $t) {
        Write-Host "`n===============================" -ForegroundColor Cyan
        Write-Host (" {0}" -f $p.이름) -ForegroundColor Cyan
        Write-Host "===============================" -ForegroundColor Cyan
        Write-Host ("  게시자   : {0}" -f $(if ($p.게시자) { $p.게시자 } else { '(없음)' }))
        Write-Host ("  버전     : {0}   설치일: {1}" -f $p.버전, $p.설치일)
        Write-Host ("  레지스트리: {0}" -f ($p.PSPath -replace '^.*Registry::',''))
        Write-Host ("  제거명령 : {0}" -f $p.제거)

        # (1) 설치 폴더 + 실행파일 디지털 서명 = 진짜 만든 회사
        $dir = $p.설치경로
        if (-not $dir -and $p.제거 -match '"?([A-Z]:\\[^"]+)\\[^\\"]+\.exe') { $dir = $matches[1] }
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            Write-Host ("`n  [폴더] {0}" -f $dir) -ForegroundColor Yellow
            Get-ChildItem -LiteralPath $dir -Filter *.exe -Recurse -Depth 1 |
                Select-Object -First 5 | ForEach-Object {
                    $sig = Get-AuthenticodeSignature $_.FullName
                    $who = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1' } else { '(서명없음)' }
                    Write-Host ("     {0,-32} 서명: {1}" -f $_.Name, $who)
                }
        } else {
            Write-Host "`n  [폴더] 없음 또는 미등록 - 잔재일 수 있음" -ForegroundColor DarkGray
        }

        # (2) 지금 돌고 있나
        $k = ($p.이름 -split '[\s\.]')[0]
        $proc = Get-Process | Where-Object { $_.Name -like "*$k*" -or $_.Company -like "*$k*" }
        if ($proc) {
            Write-Host "`n  [실행중]" -ForegroundColor Red
            $proc | Select-Object -First 5 | ForEach-Object {
                Write-Host ("     {0} (PID {1})  {2}" -f $_.Name, $_.Id, $_.Path)
            }
        } else { Write-Host "`n  [실행중] 없음" -ForegroundColor DarkGray }

        # (3) 서비스 / 자동시작 = 제거해도 되살아나는 경로
        $svc = Get-Service | Where-Object { $_.Name -like "*$k*" -or $_.DisplayName -like "*$k*" }
        if ($svc) {
            Write-Host "`n  [서비스]" -ForegroundColor Yellow
            $svc | ForEach-Object { Write-Host ("     {0} ({1}) - {2}" -f $_.Name, $_.DisplayName, $_.Status) }
        }
        $run = Get-CimInstance Win32_StartupCommand | Where-Object { $_.Command -like "*$k*" }
        if ($run) {
            Write-Host "`n  [자동시작]" -ForegroundColor Yellow
            $run | ForEach-Object { Write-Host ("     {0} - {1}" -f $_.Name, $_.Command) }
        }
        Write-Host ""
    }
}

# ── 실행 ────────────────────────────────────────────────────────────
if ($Detail) { Show-Detail $Detail; return }

$list = Get-ProgList | Sort-Object 이름
if ($Name)    { $list = $list | Where-Object { $_.이름 -match $Name -or $_.게시자 -match $Name -or $_.키이름 -match $Name } }
if ($Suspect) { $list = $list | Where-Object { $_.판정 -match '고아|무게시자' } }

if (-not $list) { Write-Host "`n해당 없음`n" -ForegroundColor DarkYellow; return }

Write-Host "`n=== 설치 프로그램 판정 (조회 전용 - 삭제 안 함) ===`n" -ForegroundColor Cyan
$list | Format-Table 이름, 게시자, 버전, 키이름, 판정 -AutoSize

$orphan = @($list | Where-Object { $_.판정 -match '고아' })
$nopub  = @($list | Where-Object { $_.판정 -match '무게시자' })
Write-Host ("총 {0}개  |  고아 {1}개  |  게시자없음 {2}개" -f $list.Count, $orphan.Count, $nopub.Count) -ForegroundColor Yellow

if ($orphan) {
    Write-Host "`n[고아] 언인스톨러가 없어 UI 로는 못 지운다. 레지스트리 키를 직접 삭제할 것:" -ForegroundColor Red
    $orphan | ForEach-Object {
        Write-Host ("  {0}" -f $_.이름) -ForegroundColor Red
        Write-Host ("    Remove-Item '{0}' -Recurse -Force" -f ($_.PSPath -replace '^.*Registry::','Registry::')) -ForegroundColor DarkGray
    }
}
if ($nopub) {
    Write-Host "`n[무게시자] 이름만으로 판단하지 말 것. 아래로 서명·폴더·서비스 확인:" -ForegroundColor Yellow
    $nopub | Select-Object -First 8 | ForEach-Object {
        Write-Host ("  .\Check-Program.ps1 -Detail '{0}'" -f ($_.이름 -split '\s')[0]) -ForegroundColor DarkGray
    }
}
Write-Host ""
