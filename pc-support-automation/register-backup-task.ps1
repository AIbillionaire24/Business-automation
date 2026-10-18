<#
====================================================================
 원격 처리 현황 월간 백업 — 작업 스케줄러 등록
 (관리자 PowerShell에서 실행)

   .\register-backup-task.ps1           ← 미리보기
   .\register-backup-task.ps1 -Apply    ← 등록
   .\register-backup-task.ps1 -Remove   ← 삭제
====================================================================
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Remove,
    [string]$BackupScript = 'D:\원격처리현황\월간백업.ps1',
    [string]$TaskName     = '원격처리현황 월간백업'
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '관리자 권한으로 실행해야 합니다.' -ForegroundColor Red; exit 1
}

$exists = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)

if ($Remove) {
    if (-not $exists) { Write-Host '등록된 작업이 없습니다.' -ForegroundColor DarkGray; exit 0 }
    Write-Host ("[삭제] {0}" -f $TaskName) -ForegroundColor Green
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    exit 0
}

if (-not (Test-Path $BackupScript)) {
    Write-Host ("[실패] 백업 스크립트 없음: {0}" -f $BackupScript) -ForegroundColor Red; exit 1
}
if ($exists) { Write-Host ("이미 등록됨: {0}" -f $TaskName) -ForegroundColor DarkGray; exit 0 }

Write-Host ("[등록] {0}" -f $TaskName) -ForegroundColor Green
Write-Host  "       매월 1일 13:10" -ForegroundColor DarkGray
Write-Host ("       -> {0}" -f $BackupScript) -ForegroundColor DarkGray

if (-not $Apply) { Write-Host "`n미리보기였습니다. 등록: -Apply" -ForegroundColor Yellow; exit 0 }

# New-ScheduledTaskTrigger 에는 '매월 N일' 트리거가 없어 schtasks 로 등록한다
$tr  = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $BackupScript
$out = schtasks /create /tn $TaskName /f /tr $tr /sc monthly /d 1 /st 13:10 /rl HIGHEST 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ("[실패] {0}" -f ($out -join ' ')) -ForegroundColor Red; exit 1
}
Write-Host '완료.' -ForegroundColor Green
