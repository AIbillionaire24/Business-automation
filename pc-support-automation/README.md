# PC 원격지원 업무 자동화 — PowerShell + AutoHotkey v2

> PC 원격지원 업무에서 반복되는 작업을 **PowerShell 스케줄러 + AutoHotkey v2**로 자동화한 실무 사례.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2.0-green)
![Windows](https://img.shields.io/badge/Windows-Task_Scheduler-orange)

---

## 문제 상황

PC 원격지원 업무에서 매일 반복되는 작업:

| 작업 | 자동화 전 | 자동화 후 |
|------|----------|----------|
| 출근 시 업무용 앱 7개 수동 실행 | 매일 3~5분 | **0분** (자동 실행) |
| 퇴근 시 앱 수동 종료 | 매일 2~3분 | **0분** (자동 종료) |
| 원격지원 안내 메시지 작성 | 건당 2~3분 | **건당 10초** (`/remo` 입력) |
| 브라우저 캐시 삭제 (원격 시) | 건당 1~2분 | **건당 5초** (단축키) |

**월간 절감 시간 추정: 약 8~10시간**

---

## 파일 구조

```
pc-support-automation/
├── README.md
├── launch_apps.ps1       ← 출근 시 자동 실행 (작업 스케줄러 연동)
├── close_apps.ps1        ← 퇴근 시 자동 종료 (작업 스케줄러 연동)
└── remote_support.ahk    ← 원격지원 업무 자동화 (AHK v2)
```

> ⚠️ 모든 파일에서 회사명, 제품명, 사용자명, URL 등 개인/기업 식별 정보는 플레이스홀더(`YOUR_*`, `example.com`)로 대체되어 있습니다. 실제 사용 시 환경에 맞게 수정하세요.

---

## 1. launch_apps.ps1 — 출근 자동화

**Windows 작업 스케줄러에 등록하여 출근 시간에 자동 실행.**

실행 앱 목록:
1. 사내 메신저
2. 모바일 에뮬레이터 (모바일 앱 테스트용)
3. 원격지원 도구
4. 휴대폰 연결 앱 (Phone Link)
5. 업무용 웹사이트 (Chrome)
6. AutoHotkey 원격지원 자동화 스크립트
7. 알림용 앱 (업무 시작 알림)

**특징:**
- 프로세스 중복 실행 방지 (`Get-Process` 체크 후 조건부 실행)
- 실행 파일 존재 여부 사전 검증 (`Test-Path`)
- 전체 실행 로그 기록 (타임스탬프 포함)
- AutoHotkey v2/v1 자동 감지 및 호환 실행

---

## 2. close_apps.ps1 — 퇴근 자동화

**퇴근 시간에 업무용 앱을 순차 종료.**

**특징:**
- Chrome은 의도적으로 종료하지 않음 (세션 유지 → 다음 날 자동 로그인)
- AutoHotkey 프로세스 와일드카드 종료 (`AutoHotkey*`)
- 전체 종료 로그 기록

---

## 3. remote_support.ahk — 원격지원 자동화 (핵심)

**사내 메신저와 원격지원 도구에서 원격지원 안내 메시지를 자동 생성·전송.**

### 핫스트링 (사내 메신저)
| 명령어 | 동작 |
|--------|------|
| `/start` | 업무 시작 인사 자동 입력 |
| `/end` | 업무 종료 인사 자동 입력 |
| `/remo` | 원격지원 안내 메시지 + 인증번호 + 이미지 자동 전송 |

### 단축키 (원격지원 도구 창 활성 시)
| 단축키 | 동작 |
|--------|------|
| `Ctrl+R` | 원격지원 메시지 전송 |
| `Ctrl+Alt+Q` | 브라우저 선택 후 캐시 삭제 |
| `Ctrl+Alt+C` | Chrome 캐시 삭제 |
| `Ctrl+Alt+E` | Edge 캐시 삭제 |

### 주요 기능
- **인증번호 입력 다이얼로그**: 숫자만 추출 (공백·하이픈 자동 제거)
- **이미지 자동 첨부**: 파일/클립보드 이미지 자동 감지, 선택 가능
- **IME 한/영 감지**: 영문 모드로 자동 전환 (URL 입력 오류 방지)
- **클립보드 안전 처리**: 기존 클립보드 백업 → 작업 → 복원
- **안전 가드**: 원격지원 도구 창이 활성화된 상태에서만 단축키 작동

---

## 작업 스케줄러 설정 방법

### 출근 자동 실행
```
프로그램: powershell.exe
인수: -ExecutionPolicy Bypass -File "C:\Scripts\launch_apps.ps1"
트리거: 매일 출근 5분 전
```

### 퇴근 자동 종료
```
프로그램: powershell.exe
인수: -ExecutionPolicy Bypass -File "C:\Scripts\close_apps.ps1"
트리거: 매일 퇴근 5분 후
```

---

## 개발 방식

> ChatGPT + Claude를 활용하여 스크립트 작성. 실무 테스트 후 반복 개선.

| AI 도구 | 활용 |
|---------|------|
| ChatGPT | PowerShell 스크립트 초안, AHK v2 문법 변환 |
| Claude | 엣지케이스 발견, 클립보드 안전 처리 로직, IME 처리 |

---

## 기술 스택

- **PowerShell 5.1+**: 프로세스 관리, 로깅, 작업 스케줄러 연동
- **AutoHotkey v2.0**: 핫스트링, 단축키, 클립보드 조작, IME 제어, DLL 호출
- **Windows 작업 스케줄러**: 시간 기반 자동 실행/종료
