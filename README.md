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

> 천재교과서 PC 원격지원 실무 | **운영 중**

- PowerShell + 작업 스케줄러로 출퇴근 시 업무용 앱 7개 자동 실행/종료
- AutoHotkey v2로 원격지원 안내 메시지 자동 생성 (`/remo` → 인증번호 입력 → 이미지 첨부 → 전송)
- 브라우저 캐시 삭제 자동화 (Chrome/Edge 대응)
- **월간 약 8~10시간 절감**
- **기술**: PowerShell, AutoHotkey v2, Windows Task Scheduler

📂 [상세 문서 →](./pc-support-automation/README.md)

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

**모니터링**: Grafana, Splunk, Distill Web Monitor

---

## 연락처

- 📧 beomsol1124@gmail.com
- 💼 [GitHub](https://github.com/lifeispain1124)
