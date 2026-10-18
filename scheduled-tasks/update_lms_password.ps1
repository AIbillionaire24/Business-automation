# update_lms_password.ps1
# LMS 익스트라넷 비밀번호를 바꿨을 때(6개월 주기) 12:50 자동입력용 자격증명을 다시 저장한다.
# 대상 작업: Open Lms Extra Prefill Weekdays -> open_lms_prefill.ps1
#
# 실행: 이 파일 우클릭 -> "PowerShell에서 실행" (관리자 권한 불필요)
# 주의: 저장 파일은 DPAPI 로 암호화된다. 예약 작업을 돌리는 같은 Windows 계정으로 실행해야
#       12:50 작업이 읽을 수 있다. 비밀번호는 입력 창으로만 받는다(명령줄 인자 X -> 4688 감사 로그에 안 남음).

$ErrorActionPreference = 'Stop'
$taskName = 'Open Lms Extra Prefill Weekdays'
$credPath = Join-Path $env:LOCALAPPDATA 'CodexAutomation\lms_login_credential.xml'
$task     = $null

function Pause-Exit([int]$code) {
    Read-Host "`nEnter 를 누르면 창이 닫힙니다" | Out-Null
    exit $code
}

# 1) 예약 작업 확인 - 작업이 -CredentialPath 를 따로 지정했다면 그 경로에 저장한다
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $taskArgs = ($task.Actions | ForEach-Object { $_.Arguments }) -join ' '
    if ($taskArgs -match '-CredentialPath\s+(?:"([^"]+)"|(\S+))') {
        $p = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $credPath = [Environment]::ExpandEnvironmentVariables($p)
    }
    $runAs = [string]$task.Principal.UserId
    Write-Host "예약 작업: $taskName (실행 계정: $runAs)"
    if ($runAs -and $runAs -notmatch [regex]::Escape($env:USERNAME)) {
        Write-Host "[주의] 현재 로그인 계정($env:USERNAME)과 작업 실행 계정이 달라 보입니다. 다르면 12:50 작업이 새 비밀번호를 못 읽습니다." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[주의] 예약 작업 '$taskName' 을 찾지 못했습니다. 기본 경로에 저장합니다." -ForegroundColor Yellow
}
Write-Host "저장 위치: $credPath"

# 2) 기존 아이디 확인 후 콘솔에서 새 비밀번호 입력
#    (Get-Credential 팝업은 터미널 창 뒤에 숨어 안 보이는 경우가 있어 콘솔 입력으로 바꿈)
$oldUser = $null
if (Test-Path -LiteralPath $credPath) {
    try {
        $oldUser = (Import-Clixml -LiteralPath $credPath).UserName
        Write-Host ("기존 저장일: {0:yyyy-MM-dd HH:mm}" -f (Get-Item -LiteralPath $credPath).LastWriteTime)
    } catch {
        Write-Host "[주의] 기존 파일을 읽지 못했습니다(다른 계정/PC에서 만든 파일일 수 있음). 아이디도 새로 입력하세요." -ForegroundColor Yellow
    }
}

function Test-SameSecure([Security.SecureString]$a, [Security.SecureString]$b) {
    $p1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)
    $p2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)
    try {
        return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p2))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p2)
    }
}

Write-Host ""
if ($oldUser) {
    $inId = Read-Host "아이디 (그냥 Enter = $oldUser 그대로 사용)"
    $userId = if ([string]::IsNullOrWhiteSpace($inId)) { $oldUser } else { $inId.Trim() }
} else {
    $userId = "$(Read-Host '아이디')".Trim()
}
if ([string]::IsNullOrWhiteSpace($userId)) {
    Write-Host "아이디가 비어 있어 저장하지 않았습니다." -ForegroundColor Red
    Pause-Exit 1
}

$pw = $null
for ($i = 1; $i -le 3; $i++) {
    $pw1 = Read-Host "새 비밀번호 (입력하면 * 로 표시됨)" -AsSecureString
    if ($pw1.Length -eq 0) { Write-Host "비밀번호가 비어 있습니다. 다시 입력하세요." -ForegroundColor Yellow; continue }
    $pw2 = Read-Host "새 비밀번호 한 번 더" -AsSecureString
    if (Test-SameSecure $pw1 $pw2) { $pw = $pw1; break }
    Write-Host "두 번 입력한 비밀번호가 다릅니다. 다시 입력하세요. ($i/3)" -ForegroundColor Yellow
}
if (-not $pw) {
    Write-Host "3회 실패 - 아무것도 바뀌지 않았습니다." -ForegroundColor Red
    Pause-Exit 1
}
$cred = New-Object System.Management.Automation.PSCredential($userId, $pw)

# 3) 저장 후 바로 다시 읽어서 복호화되는지 확인
try {
    $dir = Split-Path -Parent $credPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cred | Export-Clixml -LiteralPath $credPath -Force
    $check = Import-Clixml -LiteralPath $credPath
    if ($check.UserName -ne $cred.UserName -or $check.Password.Length -ne $cred.Password.Length) {
        throw '저장 직후 다시 읽은 값이 입력값과 다릅니다.'
    }
} catch {
    Write-Host "[실패] 저장 오류: $($_.Exception.Message)" -ForegroundColor Red
    Pause-Exit 1
}
Write-Host ("[완료] 저장됨 - 아이디 {0} / 비밀번호 {1}자리" -f $check.UserName, $check.Password.Length) -ForegroundColor Green

# 4) 선택: 지금 바로 익스트라넷을 열어 새 비밀번호로 채워지는지 확인
$ans = Read-Host "`n지금 익스트라넷을 열어 자동입력을 테스트할까요? (Y/N)"
if ($ans -match '^[Yy]') {
    if ($task) {
        Start-ScheduledTask -TaskName $taskName
        Write-Host "작업을 실행했습니다. 크롬에 아이디/비밀번호가 채워지면 로그인까지 눌러 확인하세요."
        Write-Host "(최근 5분 안에 이미 열었으면 중복 방지로 건너뜁니다. 오늘이 휴무일 목록에 있으면 SKIP 됩니다.)"
    } else {
        Write-Host "예약 작업이 없어 테스트를 건너뜁니다."
    }
}
Pause-Exit 0
