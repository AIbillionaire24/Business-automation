# Business Automation

> AI 도구(ChatGPT, Codex, Claude, Gemini, Perplexity)를 활용한 실무 업무 자동화 포트폴리오

**범솔** — IT 운영 자동화 엔지니어 (경력 7년+)

---

## 프로젝트

### 🔴 [Shock Engine](./shock-engine/) — AI 기반 실시간 금융 뉴스 자동 분류 시스템

> n8n + GPT-4o-mini + Yahoo Finance API | 49개 노드 | v39 | **운영 중**

- 8개 RSS + FinancialJuice에서 10분 주기로 금융 뉴스 자동 수집
- GPT-4o-mini로 충격도(1-5점) 자동 분석, 한국어 요약 생성
- Premium/Free 티어 자동 라우팅 → 텔레그램 채널 자동 배포
- Yahoo Finance API로 진입가 추출 → 60분 후 종료가 추적 → 수익률 자동 계산
- **기술**: n8n, OpenAI API, Yahoo Finance API, Google Sheets, Telegram Bot API, JavaScript

📂 [상세 문서 →](./shock-engine/README.md)

---

### 🟢 [PC 원격지원 업무 자동화](./pc-support-automation/) — PowerShell + AutoHotkey v2

> 교육 서비스 기업 PC 원격지원 실무 (재택) | **운영 중**

- 작업 스케줄러로 업무 앱 자동 실행 / 종료 (중복 실행 방지, 시간 가드로 근무 중 오작동 차단)
- AutoHotkey v2 `/re` → 인증번호 입력 → 원격지원 안내문 + 이미지 자동 삽입 (지정한 메신저 창이 활성일 때만 동작)
- **기술**: PowerShell 5.1, AutoHotkey v2, Windows Task Scheduler

📂 [상세 문서 →](./pc-support-automation/README.md)

---

### 🔵 [원격지원 진단 툴킷](./remote-support-toolkit/) — 단일 파일 PowerShell 툴킷

> 원격 세션에서 교사 PC로 보내 실행하는 1차 진단·정리 도구 | v3.6.20 | 약 5,200행 | **운영 중**

- 증상별 시나리오 6종(카메라/마이크, 로그인, CRM, 강의 재생, 느림, 화상수업 품질) + 개별 도구 18종
- 보안 프로그램 탐지 → 보존 목록 우선 평가 → UI로 안 지워지는 것만 CMD 제거
- 이름 기반 탐지가 못 잡는 경우를 위해 **프로세스별 TCP 연결 수**로 느림 원인 추적
- 실제 케이스가 들어올 때마다 버전을 올리고, 변경 근거(실측)를 스크립트 헤더에 기록
- 빌드 스크립트가 단일 `.bat` 배포본을 만들고, **금지어 목록(실명·계정ID)이 남아 있으면 빌드 실패**

📂 [상세 문서 →](./remote-support-toolkit/README.md)

---

### 🟡 [예약 작업 자동화](./scheduled-tasks/) — 작업 스케줄러 + CDP + Tampermonkey

- 업무 포털 로그인 자동 입력 — 자격증명은 DPAPI(`Export-Clixml`)로 저장, 허용 도메인 탭에만 입력
- Tampermonkey: 게시판 새 원격요청 알림(소리)

📂 [폴더 →](./scheduled-tasks/)

---

## 사용 AI 도구 및 역할

| AI 도구 | 활용 내역 |
|---------|----------|
| **ChatGPT** | 아키텍처 설계, 코드 생성, 프롬프트 엔지니어링, 문서 자동화 |
| **OpenAI Codex** | 코드 노드 최적화, 버그 수정, 오탐 방지 로직 강화 |
| **Claude** | 구조 검토, 엣지케이스 발견, 긴 문서 분석, 전략 수립 |
| **Gemini** | 정보 검색, 다중 자료 비교 |
| **Perplexity** | 시장 조사, 경쟁자 분석 |

## 개발 철학

```
"코드를 직접 짜는 것"이 아니라
"AI 도구를 지휘해서 실제 돌아가는 시스템을 만들고 운영하는 것"
```

모든 프로젝트의 코드는 AI 도구를 활용하여 작성되었습니다.
제가 담당하는 영역은 **문제 정의, 아키텍처 설계, AI 프롬프트 설계, 품질 판단, 반복 개선, 실제 운영**입니다.

---

## 기술 스택

**자동화**: n8n, PowerShell, AutoHotkey v2, 작업 스케줄러

**클라우드/인프라**: VMware vSphere, Microsoft 365, Azure AD, AWS, Active Directory

**스크립팅**: JavaScript (n8n Code 노드), PowerShell, Bash

**AI/API**: OpenAI GPT-4o-mini, Telegram Bot API, Yahoo Finance API, Google Sheets API

**모니터링**: Grafana, Distill Web Monitor

---

## 연락처

- 📧 bumsol2@gmail.com
- 💼 [GitHub](https://github.com/AIbillionaire24)
