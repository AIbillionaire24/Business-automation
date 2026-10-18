# PC 원격지원 업무 자동화 — PowerShell + AutoHotkey v2

> 재택 PC 원격지원 업무에서 매일 반복되는 일을 작업 스케줄러 + PowerShell + AutoHotkey v2 로 자동화한 실무 스크립트.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2.0-green)
![Windows](https://img.shields.io/badge/Windows-Task_Scheduler-orange)

> ⚠️ 공개용 사본입니다. 사람 이름·계정·고객사명·내부 주소는 플레이스홀더(`동료A`, `USERNAME`, `lms.example.com` 등)로 바꿨습니다. 그대로 실행하면 환경에 맞지 않으니 값을 바꿔서 쓰세요.

---

## 흐름

| 시점 | 스크립트 | 하는 일 |
|------|----------|---------|
| 시작 시 | `launch_apps.ps1` | 메신저·원격지원 도구·에뮬레이터·업무 사이트·AHK 실행 (중복 실행 방지, 필수 단계 실패 시 exit 1) |
| 근무 중 | `remote_support.ahk` | 메신저에서 `/re` → 인증번호 입력 → 안내문 + 이미지 자동 삽입 |
| 종료 시 | `close_apps.ps1` | 업무 앱 종료 — 시간 가드가 있어 근무 중 실수 실행으로는 안 닫힘 |

## 파일

**AutoHotkey**
- `remote_support.ahk` (v6.2) — `/re` 원격지원 안내, 예비 단축키 `Ctrl+Alt+R/N`, 발동 로그

**검증·운영 보조**
- `lint-ps51.ps1` — PowerShell 5.1 에서 깨지는 문법(BOM 누락, 7.x 전용 연산자 등) 사전 검사
- `register-backup-task.ps1`, `register_monthly_backup.bat` — 월간 백업 작업 등록

## 설계에서 신경 쓴 것

- **엉뚱한 창에는 동작하지 않게**: `/re`는 지정한 메신저 창이 활성일 때만 동작. 업무 앱은 이미 실행 중이면 다시 띄우지 않음.
- **늦게 실행된 작업 방어**: PC가 꺼져 있다가 켜지며 밀린 작업이 돌 때 엉뚱한 시각에 앱이 닫히지 않도록 시각 창(time window) 검사.
- **PowerShell 5.1 인코딩**: `.ps1` 은 UTF-8 with BOM 필수(없으면 CP949로 읽혀 한글 깨짐), `.bat` 은 CP949.

## 개발 방식

ChatGPT·Codex·Claude 로 작성하고, 다른 AI 로 교차 QA → 실사용 → 수정 반복. 각 스크립트 헤더에 QA 반영 이력을 남겼습니다.
