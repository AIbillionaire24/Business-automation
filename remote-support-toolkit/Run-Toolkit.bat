@echo off
setlocal
cd /d "%~dp0"

rem == 관리자 권한 확인. 아니면 UAC 띄워서 자기 자신을 관리자로 재실행 ==
rem    (스크립트가 관리자 아니면 첫 줄에서 그냥 종료되므로 여기서 승격해야 함)
rem    net session 은 Server 서비스가 꺼져 있으면 관리자여도 실패한다(승격 창이 계속 다시 뜸).
rem    fltmc 는 서비스와 무관하게 관리자일 때만 성공한다.
fltmc >nul 2>&1
if errorlevel 1 (
    echo 관리자 권한이 필요합니다. 승격 창을 띄웁니다...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem == 같은 폴더의 Remote-Support-Toolkit*.ps1 중 최신 선택 (수정시각 최신순 = /o-d) ==
rem    이름 역순 정렬이면 v2.6.2 보다 v2.6 이 먼저 와서 구버전이 잡힌다
set "PS1="
for /f "delims=" %%F in ('dir /b /a-d /o-d "Remote-Support-Toolkit*.ps1" 2^>nul') do (
    if not defined PS1 set "PS1=%%~fF"
)
if not defined PS1 (
    echo [오류] Remote-Support-Toolkit*.ps1 파일을 이 폴더에서 찾지 못했습니다.
    pause
    exit /b 1
)

echo 실행: %PS1%
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

rem == 스크립트가 시작하자마자 죽어도 오류를 볼 수 있게 창 유지 ==
echo.
pause
