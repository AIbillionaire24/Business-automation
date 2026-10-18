# PC 원격지원 업무 자동화 — PowerShell + AutoHotkey v2

> 재택 PC 원격지원 업무(근무 13:00~19:00)에서 매일 반복되는 일을 작업 스케줄러 + PowerShell + AutoHotkey v2 로 자동화한 실무 스크립트.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2.0-green)
![Windows](https://img.shields.io/badge/Windows-Task_Scheduler-orange)

> ⚠️ 공개용 사본입니다. 사람 이름·계정·고객사명·내부 주소는 플레이스홀더(`동료A`, `USERNAME`, `lms.example.com` 등)로 바꿨습니다. 그대로 실행하면 환경에 맞지 않으니 값을 바꿔서 쓰세요.

---

## 하루 흐름

| 시각 | 스크립트 | 하는 일 |
|------|----------|---------|
| 12:50 | `launch_apps.ps1` | 메신저·원격지원 도구·에뮬레이터·업무 사이트·AHK 실행 (중복 실행 방지, 필수 단계 실패 시 exit 1) |
| 12:50~13:00 | `queue_hiworks_self_greeting_1255.ps1` | 출근 인사 발송 큐 — 지터 0~4분, 실패 시 13:00까지 60초 간격 재시도, 당일 중복 방지 |
| 근무 중 | `remote_support.ahk` | 메신저에서 `/re` → 인증번호 입력 → 안내문 + 이미지 자동 삽입 |
| 18:55 | `workday_overtime.ps1 -Action Prompt` | "오늘 연장 근무하시나요?" 알림 (포커스를 뺏지 않음) |
| 19:00 | `queue_hiworks_end_message_1900.ps1` | 퇴근 인사 발송 (연장 기록이 있으면 건너뜀) |
| 19:09~ | `close_apps.ps1` | 업무 앱 종료 — 시간 가드(평일 19:09~23:59)가 있어 근무 중 실수 실행으로는 안 닫힘 |
| 19:40 | `workday_overtime.ps1 -Action Reminder` | 연장 중이면 "끝나셨나요?" 알림 |

## 파일

**메신저 인사 발송 체인**
- `queue_*.ps1` → `send_hiworks_self_greeting.ps1` / `send_hiworks_end_message.ps1` → `send_hiworks_self_greeting_uia.ps1`
  - 실제 입력은 UI Automation 으로 창·검색창·채팅방을 찾아서 넣고, 좌표 클릭은 마지막 폴백
  - 대화방 이름이 부분 일치하는 다른 방(여러 명 방)은 거르고, 전송 여부를 확인 못 하면 `.hold` 로 보류 → 다음 수동 퇴근 때 사람에게 확인
- `hiworks-message.ps1` — 인사 문구 풀에서 직전 문구를 피해 선택
- `hiworks_holidays.txt` — 공휴일 목록 1개를 6개 스크립트가 공유. `check-hiworks-health.ps1` 이 연도별 대체공휴일 누락까지 점검

**연장 근무**
- `workday_overtime.ps1` — Prompt / On / Finish / Reminder 4가지 모드. 발송 기록(`.sent`)이 확인된 뒤에만 앱을 닫음

**검증·운영 보조**
- `qa-full.ps1`, `qa_hiworks_message.ps1`, `run_message_selftest.ps1`, `run_hiworks_*_via_task.ps1` — 실제 발송 없이 dry-run / 나와의 채팅으로 셀프 테스트
- `lint-ps51.ps1` — PowerShell 5.1 에서 깨지는 문법(BOM 누락, 7.x 전용 연산자 등) 사전 검사
- `register-backup-task.ps1`, `register_monthly_backup.bat` — 월간 백업 작업 등록

**AutoHotkey**
- `remote_support.ahk` (v6.2) — `/re` 원격지원 안내, 예비 단축키 `Ctrl+Alt+R/N`, 발동 로그
- `hiworks_self_greeting.ahk` — 초기 AHK 버전 출근 인사 (현재는 PowerShell UIA 체인으로 대체)

## 설계에서 신경 쓴 것

- **잘못 보내는 것보다 안 보내는 게 낫다**: 대상 창·대화방을 확인 못 하면 입력을 중단. 전송 여부 불명이면 재전송하지 않고 보류.
- **늦게 실행된 작업 방어**: PC가 꺼져 있다가 켜지며 밀린 작업이 돌 때 엉뚱한 시각에 메시지가 나가거나 앱이 닫히지 않도록 시각 창(time window) 검사.
- **PowerShell 5.1 인코딩**: `.ps1` 은 UTF-8 with BOM 필수(없으면 CP949로 읽혀 한글 깨짐), `.bat` 은 CP949.

## 개발 방식

ChatGPT·Codex·Claude 로 작성하고, 다른 AI 로 교차 QA → 실사용 → 수정 반복. 각 스크립트 헤더에 QA 반영 이력을 남겼습니다.
