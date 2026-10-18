<#
========================================================================
 카메라 진단 (조회 전용) v1.0.1 - 2026-09-28
 v1.0.1: 업데이트 실패(ID 20) 줄에 제목 대신 오류코드 정수가 찍히던 것 수정 → 제목 + 0x 오류코드
 용도 : "업데이트 후 노트북 카메라 안 됨" 을 1회 실행으로 층위별로 가른다.
        기기·OS빌드 / 최근 업데이트 / 카메라 장치·드라이버 / 개인정보 설정 /
        카메라 점유 앱 / Frame Server / 브라우저 카메라 권한 / 제조사 차단SW / 장치 이벤트
 원칙 : 아무것도 바꾸지 않는다. 조치 명령은 화면에만 출력한다.
 실행 : 파일 우클릭 → [PowerShell에서 실행]  (관리자 아니어도 됨)
        또는  powershell -NoProfile -ExecutionPolicy Bypass -File .\Camera-Diag.ps1
 주의 : 다른 관리자 계정으로 승격해 실행해도, 개인정보 설정·브라우저 권한은
        '지금 로그온한 선생님 계정'(explorer.exe 소유자) 기준으로 읽는다.
 근거 : 2026-09-08 교사 PC 실측 - 웹캠이 서드파티 드라이버로 Image(WIA) 클래스에 잡혀
        카메라 앱·브라우저가 0xA00F4244. 같은 날 카메라 토글 OFF 건.
        KB5124010(9월 선택적 업데이트, 빌드 .9550)에 '내장 카메라가 카메라 앱 및
        다른 앱에서 작동 중지되는 문제' 수정 포함.
========================================================================
#>

$ErrorActionPreference = 'SilentlyContinue'
$script:Verdict = New-Object System.Collections.Generic.List[object]
function Add-Verdict([string]$level, [string]$msg) { $script:Verdict.Add([PSCustomObject]@{ L = $level; M = $msg }) }
function H([string]$t) { Write-Host "`n$t" -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "======================================" -ForegroundColor Blue
Write-Host "  카메라 진단 (조회 전용) v1.0.1" -ForegroundColor Blue
Write-Host "======================================" -ForegroundColor Blue

# ── [0] 기기 / OS 빌드 ────────────────────────────────────────────────
H "[0] 기기 / OS 빌드"
$cs    = Get-CimInstance Win32_ComputerSystem
$csp   = Get-CimInstance Win32_ComputerSystemProduct
$os    = Get-CimInstance Win32_OperatingSystem
$cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr   = [int]$cv.UBR
$maker = [string]$cs.Manufacturer
$model = [string]$cs.Model
# 레노버는 Model 이 '20XXS0AB00' 같은 코드라 Version 에 실제 모델명이 있다
if ($maker -match 'LENOVO' -and $csp.Version) { $model = '{0} ({1})' -f $csp.Version, $cs.Model }
Write-Host ("  제조사/모델 : {0} / {1}" -f $maker, $model)
Write-Host ("  Windows     : {0} {1}  빌드 {2}.{3}" -f $os.Caption, $cv.DisplayVersion, $build, $ubr)
$needKB = $false
if ($build -in 26100, 26200) {
    if ($ubr -ge 9550) {
        Write-Host "  → 9월 카메라 수정(KB5124010, .9550) 포함 빌드" -ForegroundColor Green
    } else {
        $needKB = $true
        Write-Host "  → .9550 미만 = 9월 카메라 수정(KB5124010) 미포함 빌드" -ForegroundColor DarkYellow
    }
}

# ── [1] 최근 21일 업데이트 설치 기록 ─────────────────────────────────
H "[1] 최근 21일 Windows 업데이트 설치 기록 (드라이버 포함)"
$since21 = (Get-Date).AddDays(-21)
$wu = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
                                         Id = 19, 20; StartTime = $since21 } -ErrorAction SilentlyContinue)
if ($wu) {
    foreach ($e in ($wu | Select-Object -First 15)) {
        # ID 19(성공)은 Properties[0]=제목. ID 20(실패)은 [0]=오류코드, [1]=제목 이다.
        # (v1.0 은 실패 건에 오류코드 정수 '-2145116149' 만 찍었다 - 2026-09-28 교사 PC 실측)
        if ($e.Id -eq 20) {
            $title = '{0}  (오류 0x{1:X8})' -f [string]$e.Properties[1].Value, [int]$e.Properties[0].Value
        } else {
            $title = [string]$e.Properties[0].Value
        }
        if ($title.Length -gt 95) { $title = $title.Substring(0, 95) + '…' }
        $isCam = $title -match '(?i)- (Camera|Image) -|camera|카메라'
        $res   = if ($e.Id -eq 19) { '성공' } else { '실패' }
        $col   = if ($e.Id -eq 20) { 'Red' } elseif ($isCam) { 'Cyan' } else { 'Gray' }
        $tag   = if ($isCam) { '  ← 카메라 드라이버' } else { '' }
        Write-Host ("  {0}  {1}  {2}{3}" -f $e.TimeCreated.ToString('MM-dd HH:mm'), $res, $title, $tag) -ForegroundColor $col
        if ($isCam -and $e.Id -eq 19) {
            Add-Verdict 'INFO' ("Windows Update 가 카메라 드라이버를 설치함({0}) → 장치관리자 [드라이버 롤백] 후보" -f $e.TimeCreated.ToString('MM-dd'))
        }
    }
} else {
    Write-Host "  이벤트 기록 없음 → 설치된 업데이트(HotFix) 최근 5건으로 대체" -ForegroundColor DarkGray
    Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host ("  {0}  {1}  {2}" -f $_.InstalledOn.ToString('MM-dd'), $_.HotFixID, $_.Description) -ForegroundColor Gray }
}

# ── [2] 카메라 장치 · 드라이버 ────────────────────────────────────────
H "[2] 카메라 관련 장치 (연결됨 = 지금 OS 에 잡힘 / 미연결 = 과거 기록)"
$camRx  = '(?i)camera|webcam|카메라|웹캠|AVStream|Imaging Signal|iVSC|Visual Sensing|Control Logic|\bIPU\b|MIPI|VCam|XSplit|Virtual Cam'
$mipiRx = '(?i)AVStream|Imaging Signal|iVSC|Visual Sensing|Control Logic|\bIPU\b|MIPI'
$virtRx = '(?i)VCam|XSplit|Virtual Cam|OBS'
$probMap = @{
    1 = '구성 오류'; 3 = '드라이버 손상'; 10 = '장치 시작 실패'; 12 = '리소스 충돌'; 14 = '재부팅 필요'
    18 = '드라이버 재설치 필요'; 19 = '레지스트리 구성 손상'; 21 = '제거 대기'; 22 = '사용 안 함'
    24 = '장치 없음/미설치'; 28 = '드라이버 미설치'; 31 = '드라이버 로드 실패'; 32 = '드라이버 서비스 비활성'
    37 = '드라이버 초기화 실패'; 39 = '드라이버 손상/누락'; 43 = '장치가 문제를 보고(중지)'
    45 = '현재 연결 안 됨'; 48 = '드라이버 차단됨'; 52 = '드라이버 서명 확인 실패'
}
# Image 클래스 전체를 넣으면 복합기 스캐너(WIA)까지 섞인다 → Image 는 이름이 카메라인 것만 ($camRx)
$devs = @(Get-PnpDevice | Where-Object {
            $_.Class -notin 'AudioEndpoint', 'MEDIA' -and
            ($_.Class -eq 'Camera' -or $_.FriendlyName -match $camRx) } |
          Sort-Object @{ e = { $_.Status -eq 'Unknown' } }, FriendlyName)
$presentCam = @(); $problemDev = @(); $isMipi = $false; $hasVirtual = $false
foreach ($d in $devs) {
    $prop = @{}
    Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_IsPresent' |
        ForEach-Object { $prop[$_.KeyName] = $_.Data }
    $code    = [int]$d.ConfigManagerErrorCode
    $present = if ($null -ne $prop['DEVPKEY_Device_IsPresent']) { [bool]$prop['DEVPKEY_Device_IsPresent'] } else { $d.Status -ne 'Unknown' }
    $name    = [string]$d.FriendlyName
    $inf     = [string]$prop['DEVPKEY_Device_DriverInfPath']
    $dDate   = $prop['DEVPKEY_Device_DriverDate']
    $virtual = $name -match $virtRx
    $mipi    = $name -match $mipiRx
    if ($virtual) { $hasVirtual = $true }
    if ($mipi -and $present) { $isMipi = $true }

    if (-not $present) {
        Write-Host ("  [미연결] {0}  ({1})" -f $name, $d.Class) -ForegroundColor DarkGray
        continue
    }
    # '실제 카메라' 집계: 가상카메라·IR(윈도우 헬로)·IPU 보조장치는 빼고 센다
    if (-not $virtual -and -not $mipi -and $name -notmatch '(?i)\bIR\b' -and
        ($d.Class -eq 'Camera' -or $name -match '(?i)camera|webcam|카메라|웹캠')) { $presentCam += $d }
    $col = if ($code -ne 0) { 'Red' } elseif ($virtual) { 'DarkYellow' } else { 'Gray' }
    Write-Host ("  [연결됨] {0}  ({1})" -f $name, $d.Class) -ForegroundColor $col
    $dateTxt = if ($dDate) { ([datetime]$dDate).ToString('yyyy-MM-dd') } else { '-' }
    Write-Host ("           드라이버: {0} / {1} / {2} / {3}" -f $prop['DEVPKEY_Device_DriverProvider'],
        $prop['DEVPKEY_Device_DriverVersion'], $dateTxt, $inf) -ForegroundColor DarkGray

    if ($code -ne 0) {
        $desc = if ($probMap.ContainsKey($code)) { $probMap[$code] } else { '기타' }
        Write-Host ("           ← 오류 코드 {0}: {1}" -f $code, $desc) -ForegroundColor Red
        $problemDev += $d
        if ($code -eq 22) {
            Add-Verdict 'ERR' ("{0}: 코드 22(사용 안 함) → 장치관리자 [디바이스 사용] 또는 설정 > Bluetooth 및 장치 > 카메라 에서 사용" -f $name)
        } elseif ($code -in 10, 43) {
            Add-Verdict 'ERR' ("{0}: 코드 {1}({2}) → 장치 제거(드라이버 삭제 체크 안 함) → 하드웨어 변경 검색 → 안 되면 완전 종료(shutdown /s /t 0) 후 부팅" -f $name, $code, $desc)
        } else {
            $m = "{0}: 코드 {1}({2}) → 드라이버 문제. 장치관리자 [드라이버 롤백] 가능하면 롤백, 아니면 제조사 드라이버 재설치" -f $name, $code, $desc
            if ($mipi) { $m += ' (MIPI 라 Windows 기본 드라이버로는 대체 안 됨)' }
            Add-Verdict 'ERR' $m
        }
    }
    # 2026-09-08 실측 패턴: 웹캠이 서드파티 inf 로 Image(WIA) 클래스에 잡히면 카메라 앱·브라우저가 못 쓴다
    if ($d.Class -eq 'Image' -and $name -match '(?i)camera|webcam|카메라|웹캠' -and $inf -match '^oem\d+\.inf$') {
        Write-Host "           ← 웹캠이 Image(WIA) 클래스로 잡힘 (9/8 실측 패턴)" -ForegroundColor Red
        Add-Verdict 'ERR' ("{0}: Image(WIA) 클래스 = 카메라 앱·브라우저가 못 씀(0xA00F4244) → pnputil /delete-driver {1} /uninstall /force 후 재부팅 → 표준 UVC 로 재설치됨" -f $name, $inf)
    }
    if ($dDate -and ([datetime]$dDate) -gt (Get-Date).AddDays(-30) -and -not $virtual) {
        Write-Host "           ← 최근 30일 내 드라이버 날짜 (업데이트로 교체됐을 수 있음)" -ForegroundColor Cyan
        Add-Verdict 'INFO' ("{0}: 드라이버 날짜 {1} → 업데이트로 바뀐 드라이버일 수 있음. 장치관리자 [드라이버 롤백] 후보" -f $name, $dateTxt)
    }
}
if (-not $devs) { Write-Host "  카메라 관련 장치 기록 자체가 없음" -ForegroundColor Red }
if ($isMipi) {
    Write-Host "  ※ Intel IPU(MIPI) 카메라 구성 - 제조사 드라이버 패키지로만 복구됨(기본 UVC 드라이버 없음)" -ForegroundColor DarkYellow
}
if ($hasVirtual) { Add-Verdict 'INFO' '가상카메라(XSplit/VCam/OBS 등) 있음 → 앱에서 장치 선택이 가상카메라로 가 있는지 확인. 소유 프로그램은 툴킷 장치 확인 메뉴(DirectShow)' }
if ($presentCam.Count -eq 0 -and $problemDev.Count -eq 0) {
    if ($isMipi) {
        Add-Verdict 'ERR' 'Intel IPU 구성요소는 잡히는데 카메라 장치가 없음 → 제조사 카메라(IPU) 드라이버 패키지 재설치. 업데이트로 IPU 드라이버 조합이 어긋났을 가능성(가정)'
    } else {
        Add-Verdict 'ERR' 'OS 에 실제 카메라가 안 잡힘 = 드라이버·설정 이전 단계 → 카메라 차단 키(F키 카메라 아이콘)·물리 스위치·제조사 보안모드(LG Fn+F4 등)·BIOS 카메라 사용 여부 확인'
    }
}

# ── [3] 개인정보 설정 (선생님 계정 기준) ─────────────────────────────
H "[3] 개인정보 > 카메라 설정"
$sid = $null; $who = $null
$ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
if ($ex) {
    $sid = (Invoke-CimMethod -InputObject $ex -MethodName GetOwnerSid).Sid
    $ow  = Invoke-CimMethod -InputObject $ex -MethodName GetOwner
    if ($ow.User) { $who = '{0}\{1}' -f $ow.Domain, $ow.User }
}
if (-not $sid) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $who = "$env:USERNAME (현재 실행 계정 - explorer 소유자 조회 실패)"
}
Write-Host ("  기준 계정: {0}" -f $who) -ForegroundColor DarkGray
$csRel    = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
$userRoot = "Registry::HKEY_USERS\$sid\$csRel"
function Show-Consent([string]$label, $val, [string]$note) {
    $txt = if ($val) { [string]$val } else { '(미설정 = 허용)' }
    $col = if ($val -eq 'Deny') { 'Red' } else { 'Gray' }
    Write-Host ("  {0,-26}: {1}{2}" -f $label, $txt, $note) -ForegroundColor $col
    if ($val -eq 'Deny') { Add-Verdict 'ERR' ("개인정보 설정 '{0}' = 꺼짐 → 설정 > 개인 정보 및 보안 > 카메라 에서 켜기 (실행: start ms-settings:privacy-webcam)" -f $label) }
}
Show-Consent '카메라 액세스(기기 전체)' (Get-ItemProperty "HKLM:\$csRel").Value ''
Show-Consent '앱의 카메라 액세스(계정)'  (Get-ItemProperty $userRoot).Value ''
Show-Consent '데스크톱 앱 카메라 액세스' (Get-ItemProperty "$userRoot\NonPackaged").Value '   ← 크롬·엣지·화상수업앱은 이 항목'
$pol   = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy').LetAppsAccessCamera
$allow = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Camera').AllowCamera
if ($null -ne $pol) {
    $col = if ($pol -eq 2) { 'Red' } else { 'Gray' }
    Write-Host ("  정책 LetAppsAccessCamera  : {0}  (0=사용자 선택 / 1=강제 허용 / 2=강제 차단)" -f $pol) -ForegroundColor $col
    if ($pol -eq 2) { Add-Verdict 'ERR' "정책으로 카메라 강제 차단(LetAppsAccessCamera=2). 개인 PC 라면 최적화툴·보안SW가 넣었을 가능성(가정) → 해제: Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name LetAppsAccessCamera (관리자)" }
}
if ($null -ne $allow) {
    $col = if ($allow -eq 0) { 'Red' } else { 'Gray' }
    Write-Host ("  정책 AllowCamera          : {0}  (0=카메라 사용 금지)" -f $allow) -ForegroundColor $col
    if ($allow -eq 0) { Add-Verdict 'ERR' "정책으로 카메라 사용 금지(AllowCamera=0) → 해제: Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Camera' -Name AllowCamera (관리자)" }
}

# ── [4] 카메라를 쓴 앱 (사용 시도 기록) ──────────────────────────────
H "[4] 카메라 사용 기록 (최근 6건 - '사용 중'이면 다른 앱이 점유)"
$uses = @()
$keys = @(Get-ChildItem $userRoot) + @(Get-ChildItem "$userRoot\NonPackaged")
foreach ($k in $keys) {
    if (-not $k -or $k.PSChildName -eq 'NonPackaged') { continue }
    $pp = Get-ItemProperty $k.PSPath
    $s = [long]$pp.LastUsedTimeStart; $e = [long]$pp.LastUsedTimeStop
    if ($s -le 0) { continue }
    $path  = $k.PSChildName -replace '#', '\'
    $short = if ($path -match '\\') { Split-Path $path -Leaf } else { $path -replace '_[a-z0-9]{13}$', '' }
    $running = $false
    if ($path -match '^[A-Za-z]:\\') { $running = [bool](Get-Process | Where-Object { $_.Path -eq $path } | Select-Object -First 1) }
    $uses += [PSCustomObject]@{ App = $short; Start = [DateTime]::FromFileTime($s); InUse = ($e -eq 0); Running = $running }
}
if ($uses) {
    foreach ($u in ($uses | Sort-Object Start -Descending | Select-Object -First 6)) {
        $st  = if ($u.InUse -and $u.Running) { '사용 중(실행 중)' } elseif ($u.InUse) { '종료 기록 없음' } else { '정상 종료' }
        $col = if ($u.InUse -and $u.Running) { 'Red' } else { 'Gray' }
        Write-Host ("  {0}  {1,-34} {2}" -f $u.Start.ToString('MM-dd HH:mm'), $u.App, $st) -ForegroundColor $col
        if ($u.InUse -and $u.Running) { Add-Verdict 'WARN' ("{0} 가 카메라를 점유 중 → 그 프로그램 종료 후 재시도" -f $u.App) }
    }
    Write-Host "  ※ '사용 시도' 기록이다. 성공 여부는 아니지만, 업데이트 설치 시각([1])과 대조하면 마지막 정상 시점을 짐작할 수 있다." -ForegroundColor DarkGray
} else { Write-Host "  기록 없음" -ForegroundColor DarkGray }

# ── [5] Windows Camera Frame Server ──────────────────────────────────
H "[5] Windows Camera Frame Server 서비스 (중지=평소 정상 / 사용 안 함=비정상)"
foreach ($sn in 'FrameServer', 'FrameServerMonitor') {
    $s = Get-Service -Name $sn
    if (-not $s) { continue }
    $bad = ([string]$s.StartType -eq 'Disabled')
    $col = if ($bad) { 'Red' } else { 'Gray' }
    Write-Host ("  {0,-20} 상태 {1,-8} 시작유형 {2}" -f $sn, $s.Status, $s.StartType) -ForegroundColor $col
    if ($bad) { Add-Verdict 'ERR' ("{0} 서비스가 '사용 안 함' (최적화툴 흔적 가능) → 복구: Set-Service {0} -StartupType Manual (관리자)" -f $sn) }
}

# ── [6] 브라우저 카메라 권한 (선생님 계정 프로필) ────────────────────
H "[6] 브라우저 카메라 권한 (차단된 것만 표시)"
$prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
$bRoots = @{ Chrome = "$prof\AppData\Local\Google\Chrome\User Data"; Edge = "$prof\AppData\Local\Microsoft\Edge\User Data" }
$bAny = $false
foreach ($b in $bRoots.Keys) {
    $root = $bRoots[$b]
    if (-not $prof -or -not (Test-Path $root)) { continue }
    foreach ($pd in (Get-ChildItem $root -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
        $pref = Join-Path $pd.FullName 'Preferences'
        if (-not (Test-Path $pref)) { continue }
        try { $j = Get-Content $pref -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Host ("  {0}/{1}: Preferences 읽기 실패" -f $b, $pd.Name) -ForegroundColor DarkYellow; continue }
        $def = $j.profile.default_content_setting_values.media_stream_camera
        if ($def -eq 2) {
            $bAny = $true
            Write-Host ("  {0}/{1}: 카메라 기본값 = 차단" -f $b, $pd.Name) -ForegroundColor Red
            Add-Verdict 'WARN' ("{0}/{1} 카메라 기본값 차단 → {2}://settings/content/camera 에서 허용" -f $b, $pd.Name, $b.ToLower())
        }
        $exs = $j.profile.content_settings.exceptions.media_stream_camera
        if ($exs) {
            foreach ($site in $exs.PSObject.Properties) {
                if ($site.Value.setting -eq 2) {
                    $bAny = $true
                    Write-Host ("  {0}/{1}: 차단 사이트 {2}" -f $b, $pd.Name, $site.Name) -ForegroundColor Red
                    if ($site.Name -match 'lms|vendor') {
                        Add-Verdict 'WARN' ("{0}/{1} 에서 {2} 카메라 차단 → 주소창 자물쇠 > 카메라 허용" -f $b, $pd.Name, $site.Name)
                    }
                }
            }
        }
    }
}
if (-not $bAny) { Write-Host "  차단 설정 없음" -ForegroundColor DarkGray }

# ── [7] 제조사 카메라 차단 SW ────────────────────────────────────────
H "[7] 제조사 보안/설정 앱 (카메라 차단 기능 보유)"
$oemRx  = '(?i)Samsung Settings|Samsung Security|LG Smart Assistant|LG Security Center|LG Control Center|Lenovo Vantage|Lenovo Commercial Vantage|myHP|HP Privacy|MyASUS|Dell Optimizer'
$oemApx = '(?i)SamsungSettings|SamsungSecurity|LenovoCompanion|LenovoVantage|LenovoSettings|myHP|HPPrivacy|ASUSPCAssistant|DellOptimizer|LGSmartAssistant|LGControlCenter'
$found = @()
foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
               "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*") {
    Get-ItemProperty $p | Where-Object { $_.DisplayName -match $oemRx } | ForEach-Object { $found += $_.DisplayName }
}
$apx = if ($isAdmin) { Get-AppxPackage -AllUsers } else { Get-AppxPackage }
$apx | Where-Object { $_.Name -match $oemApx } | ForEach-Object { $found += $_.Name }
$found = @($found | Sort-Object -Unique)
if ($found) { $found | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor Gray } }
else { Write-Host "  없음" -ForegroundColor DarkGray }
$hint = $null
# 원격지원가이드 '제조사 보안 소프트웨어' 절 기준 (HP 는 가이드에 없음 - 일반 안내)
switch -Regex ($maker.Trim()) {
    '^SAMSUNG'      { $hint = 'Samsung Settings > 사생활 보호 > 녹화/녹음 방지 [낮음] / Samsung Security > 녹화/녹음 방지 [꺼짐]'; break }
    '^LG'           { $hint = 'LG Smart Assistant 보안모드 해제(Fn+F4) / 22년4월 이전 모델은 LG Security Center > 웹캠 및 마이크 사용중지 off'; break }
    '^LENOVO'       { $hint = 'Lenovo Vantage > 하드웨어 설정 > 오디오/비디오 > 카메라 프라이버시 모드 끄기 + 화면 상단 물리 셔터'; break }
    '^HP|Hewlett'   { $hint = '키보드 카메라 차단 키(카메라 아이콘) / 물리 셔터 확인'; break }
}
if ($hint) {
    Write-Host ("  → {0}" -f $hint) -ForegroundColor Cyan
    Add-Verdict 'INFO' ("제조사({0}) 차단 기능 점검: {1}" -f $maker.Trim(), $hint)
}

# ── [8] 카메라 장치 이벤트 (시작 실패 / 드라이버 설치) ────────────────
H "[8] 카메라 장치 이벤트 (시작 실패 14일 / 드라이버 설치 30일)"
$ev411 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 411; StartTime = (Get-Date).AddDays(-14) })
$ev200 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-UserPnp'; Id = 20001; StartTime = (Get-Date).AddDays(-30) })
$evAny = $false
foreach ($d in ($devs | Where-Object { $_.FriendlyName -notmatch $virtRx })) {
    $id = [string]$d.InstanceId
    $f411 = @($ev411 | Where-Object { $_.Message -and $_.Message.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($f411) {
        $evAny = $true
        Write-Host ("  {0}: 시작 실패 {1}회 (마지막 {2})" -f $d.FriendlyName, $f411.Count, $f411[0].TimeCreated.ToString('MM-dd HH:mm')) -ForegroundColor Red
    }
    foreach ($x in @($ev200 | Where-Object { $_.Message -and $_.Message.IndexOf($id, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 3)) {
        $evAny = $true
        $infN = if ($x.Message -match '([^\s\\]+\.inf)') { $matches[1] } else { '?' }
        $stat = if ($x.Message -match '(0x[0-9A-Fa-f]+)') { $matches[1] } else { '?' }
        Write-Host ("  {0}: 드라이버 설치 {1}  {2}  상태 {3}" -f $d.FriendlyName, $x.TimeCreated.ToString('MM-dd HH:mm'), $infN, $stat) -ForegroundColor Cyan
    }
}
if (-not $evAny) { Write-Host "  해당 이벤트 없음" -ForegroundColor DarkGray }

# ── 판정 ────────────────────────────────────────────────────────────
Write-Host "`n===== 판정 · 권장 조치 =====" -ForegroundColor Cyan
$hard = @($script:Verdict | Where-Object { $_.L -in 'ERR', 'WARN' })
if ($needKB) {
    $lvl = if ($hard) { 'INFO' } else { 'WARN' }
    Add-Verdict $lvl ("빌드 {0}.{1} = KB5124010(.9550) 미포함. 이 업데이트에 '내장 카메라가 카메라 앱·다른 앱에서 작동 중지' 수정이 들어 있음 → 설정 > Windows 업데이트 > 고급 옵션 > 선택적 업데이트 (재부팅 시 원격 끊김 주의)" -f $build, $ubr)
}
$order = @{ ERR = 0; WARN = 1; INFO = 2 }
foreach ($v in ($script:Verdict | Sort-Object { $order[$_.L] })) {
    $col = switch ($v.L) { 'ERR' { 'Red' } 'WARN' { 'Yellow' } default { 'Cyan' } }
    Write-Host ("  [{0}] {1}" -f $v.L, $v.M) -ForegroundColor $col
}
if (-not $hard) {
    Write-Host "  → OS 쪽 차단 요인은 안 보임. 남는 후보: 물리 셔터/카메라 차단 키, 앱 쪽(화상수업앱 카메라 토글·장치 선택)" -ForegroundColor Green
}

# ── 카메라 앱 테스트 (선택) ──────────────────────────────────────────
Write-Host ""
if ((Read-Host "Windows 카메라 앱으로 바로 테스트할까요? (y/n)") -eq 'y') {
    Start-Process 'microsoft.windows.camera:'
    Write-Host "  0xA00F4244 = 카메라를 못 찾음 → [2] 장치/드라이버 층" -ForegroundColor DarkGray
    Write-Host "  0xA00F4243 = 다른 앱이 사용 중(참고) → [4]" -ForegroundColor DarkGray
    Write-Host "  화면이 검정/회색인데 오류 없음 → 물리 셔터·카메라 차단 키 1순위" -ForegroundColor DarkGray
}
Read-Host "`nEnter 를 누르면 닫힙니다" | Out-Null
