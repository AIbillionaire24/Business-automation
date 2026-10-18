@echo off
setlocal

rem === 관리자 권한 확인. 아니면 UAC 띄워 자기 자신을 관리자로 재실행 ===
net session >nul 2>&1
if errorlevel 1 (
    echo 관리자 권한이 필요합니다. 승격 창을 띄웁니다...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "BACKUP=D:\원격처리현황\월간백업.ps1"
set "TASK=원격처리현황 월간백업"

if not exist "%BACKUP%" (
    echo [오류] 백업 스크립트를 찾지 못했습니다: %BACKUP%
    pause
    exit /b 1
)

echo 작업 등록: %TASK%
echo   일정  : 매월 1일 13:10
echo   실행  : %BACKUP%
echo.

schtasks /create /tn "%TASK%" /f ^
  /tr "powershell -NoProfile -ExecutionPolicy Bypass -File \"%BACKUP%\"" ^
  /sc monthly /d 1 /st 13:10 /rl HIGHEST

if errorlevel 1 (
    echo.
    echo [실패] 작업 등록에 실패했습니다.
) else (
    echo.
    echo [완료] 등록되었습니다. 아래에서 확인하세요.
    echo.
    schtasks /query /tn "%TASK%" /fo LIST
)

echo.
pause
