@echo off
chcp 949 >nul
title 강의채널 점검 (조회 전용)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::GetEncoding(949)); $b=($c -split '(?m)^:PSBEGIN\r?$',2)[1]; Invoke-Expression $b"
echo.
pause
exit /b
:PSBEGIN
# LectureChannel-Diag.ps1 - 강의채널 재생 불가 점검 (조회 전용, 아무것도 변경하지 않음)
# 2026-10-02 / 근거: 원격지원가이드 Q052~Q058, 9/15 교사D 건(Agent 중복 실행·포트 응답 끊김)
$ErrorActionPreference = 'SilentlyContinue'
function H($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }

H "1. StarPlayer / Kollus / lms 설치 버전"
$keys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $keys | Where-Object { $_.DisplayName -match 'StarPlayer|Kollus|lms' } |
    Select-Object DisplayName, DisplayVersion, InstallDate | Format-Table -AutoSize
Write-Host "  기준: StarPlayerAgent 1.3.19.8 이상 (가이드 Q052)" -ForegroundColor DarkGray
$ag = 'C:\Program Files (x86)\Axissoft\StarPlayerAgent'
if (Test-Path $ag) { Write-Host "  Agent 폴더 존재: $ag (uninstall.exe: $(Test-Path "$ag\uninstall.exe"))" }
else { Write-Host "  Agent 폴더 없음: $ag" -ForegroundColor Red }

H "2. StarPlayer 프로세스 (Agent 중복 실행 여부)"
$pr = Get-Process | Where-Object { $_.Name -match 'StarPlayer' }
if ($pr) { $pr | Select-Object Name, Id, SessionId, StartTime | Format-Table -AutoSize
    $n = @($pr | Where-Object Name -match 'Agent').Count
    if ($n -gt 1) { Write-Host "  ※ Agent 프로세스 $n 개 - 9/15 교사D 건과 같은 중복 패턴" -ForegroundColor Yellow } }
else { Write-Host "  실행 중인 StarPlayer 프로세스 없음" -ForegroundColor Red }

H "3. StarPlayer 서비스"
Get-Service | Where-Object { $_.Name -match 'StarPlayer' -or $_.DisplayName -match 'StarPlayer' } |
    Select-Object Name, Status, StartType | Format-Table -AutoSize

H "4. 로컬 포트 3450~3454 리슨"
$ls = Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -ge 3450 -and $_.LocalPort -le 3454 }
if ($ls) { $ls | ForEach-Object { "  {0}:{1}  PID {2} ({3})" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, (Get-Process -Id $_.OwningProcess).Name } }
else { Write-Host "  리슨 포트 없음 - Agent 미구동" -ForegroundColor Red }

H "5. 로컬 응답 (http / https)"
[Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls11,Tls'
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
foreach ($p in 3450..3454) { foreach ($s in 'http','https') {
    try { $r = Invoke-WebRequest "${s}://127.0.0.1:$p/" -UseBasicParsing -TimeoutSec 3; "  $s $p -> HTTP $($r.StatusCode)" }
    catch { $c = $_.Exception.Response.StatusCode.value__; if ($c) { "  $s $p -> HTTP $c (응답은 옴)" } else { "  $s $p -> $($_.Exception.Message)" } } } }
Write-Host "  ※ 정상 기준값 미검증 - 정상 PC 결과와 대조할 것" -ForegroundColor DarkGray

H "6. 캡처/녹화/원격 프로세스 (가이드 Q057 '불법적인 시도')"
Get-Process | Where-Object { $_.Name -match 'Bandi|obs|XSplit|ALCapture|Capture|Camtasia|Snagit|GameBar|PowerDirector|wemeeo' } |
    Select-Object Name, Id | Format-Table -AutoSize

H "7. 기본 브라우저 / Chrome 버전"
(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice').ProgId
$ch = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
if (Test-Path $ch) { "  Chrome " + (Get-Item $ch).VersionInfo.ProductVersion } else { "  Chrome 기본 경로 없음" }
Write-Host ""
