# Shock Engine — 아키텍처 상세

## 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│                    SHOCK ENGINE v39                       │
│                   (n8n Workflow)                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────── 수집 레이어 ────────────┐                │
│  │ Benzinga  CNBC  MarketWatch  NYT    │                │
│  │ Yahoo  Bloomberg  SeekingAlpha      │                │
│  │ FinancialJuice (매크로 전용)         │                │
│  │         ↓ 10분 주기 RSS 수집         │                │
│  └─────────────────────────────────────┘                │
│                      ↓                                   │
│  ┌──────────── 필터 레이어 ────────────┐                │
│  │ Parse RSS v14 (XML→구조화)          │                │
│  │         ↓                            │                │
│  │ Keyword Filter v23                   │                │
│  │  ├─ 경로1: 지정학 충격              │                │
│  │  ├─ 경로2: 매크로 이벤트            │                │
│  │  └─ 경로3: 기업 이벤트              │                │
│  │         ↓                            │                │
│  │ Duplicate Check (Google Sheets)      │                │
│  └─────────────────────────────────────┘                │
│                      ↓                                   │
│  ┌──────────── 분석 레이어 ────────────┐                │
│  │ GPT-4o-mini Shock Detection          │                │
│  │  → shock_score, confidence,          │                │
│  │    direction, event_type,            │                │
│  │    ticker, thesis (한국어)           │                │
│  │         ↓                            │                │
│  │ Parse GPT + Route Decision v9        │                │
│  │  → 한글 가드, Direction 정규화       │                │
│  │  → 티커 정규화, 점수 파싱 강화       │                │
│  └─────────────────────────────────────┘                │
│                      ↓                                   │
│  ┌──────────── 라우팅 레이어 ──────────┐                │
│  │ score ≥ 4 ──→ Premium 채널           │                │
│  │ score 3 + 주요 이벤트 ──→ Free 채널  │                │
│  │ 기타 ──→ Discard                     │                │
│  └─────────────────────────────────────┘                │
│                      ↓                                   │
│  ┌──────────── 배포 레이어 ────────────┐                │
│  │ Yahoo Finance → 진입가 추출          │                │
│  │ Format Telegram Message              │                │
│  │ Send → Premium / Free 채널           │                │
│  │ Save to Google Sheets DB             │                │
│  └─────────────────────────────────────┘                │
│                      ↓                                   │
│  ┌──────────── 추적 레이어 ────────────┐                │
│  │ 10min Tracker Trigger                │                │
│  │ 60분 경과 기사 필터                  │                │
│  │ Yahoo Finance → 종료가 추출          │                │
│  │ change_pct 계산                      │                │
│  │ DB 업데이트                          │                │
│  └─────────────────────────────────────┘                │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## 노드 목록 (49개)

### 수집 (10개)
| 노드 | 유형 | 역할 |
|------|------|------|
| 10min Schedule Trigger | Schedule | 10분 주기 실행 |
| https - Benzinga | HTTP | Benzinga RSS |
| https - CNBC Tech | HTTP | CNBC 기술 뉴스 RSS |
| https - MarketWatch Top | HTTP | MarketWatch 탑뉴스 RSS |
| https - MarketWatch Realtime | HTTP | MarketWatch 실시간 RSS |
| https - NYT Business | HTTP | NYT 비즈니스 RSS |
| https - Yahoo Finance | HTTP | Yahoo Finance RSS |
| https - Bloomberg Markets | HTTP | Bloomberg 시장 RSS |
| https - SeekingAlpha | HTTP | SeekingAlpha RSS |
| RSS Feed - FinancialJuice | HTTP | FinancialJuice 매크로 |

### 처리 (8개)
| 노드 | 유형 | 역할 |
|------|------|------|
| Merge | Merge | 9개 소스 병합 |
| FinancialJuice Normalize | Code | FJ 데이터 정규화 |
| Parse RSS | Code (v14) | XML → 구조화 데이터 |
| Keyword Filter | Code (v23) | 3경로 키워드 필터 |
| Has Results? | If | 빈 결과 체크 |
| Split Per Article | SplitInBatches | 기사별 루프 |
| Duplicate Check (DB) | Google Sheets | URL 중복 조회 |
| Duplicate Check Logic | Code | 정규화 비교 |

### 분석 (4개)
| 노드 | 유형 | 역할 |
|------|------|------|
| New Article? | If | 중복 여부 분기 |
| GPT Shock Detection | OpenAI | 충격도 분석 |
| Parse GPT + Route Decision | Code (v9) | 응답 파싱 + 라우팅 |
| Passes Route Filter? | If | discard 분기 |

### 라우팅·배포 (12개)
| 노드 | 유형 | 역할 |
|------|------|------|
| Valid Ticker? | If | UNKNOWN/MULTI 분기 |
| Yahoo Finance - Entry Price | HTTP | 진입가 조회 |
| Extract Entry Price | Code | 가격 추출 |
| Skip Yahoo (No Valid Ticker) | Code | MULTI용 스킵 |
| Route = premium | If | Premium/Free 분기 |
| Format Telegram (Premium) | Code | Premium 메시지 포맷 |
| Format Telegram (Free) | Code | Free 메시지 포맷 |
| Telegram Premium | Telegram | Premium 채널 발송 |
| Telegram Free | Telegram | Free 채널 발송 |
| Save to DB (Premium) | Google Sheets | Premium 기록 |
| Save to DB (Free) | Google Sheets | Free 기록 |

### 가격 추적 (9개)
| 노드 | 유형 | 역할 |
|------|------|------|
| 10min Tracker Trigger | Schedule | 추적 트리거 |
| Fetch Rows Without Exit Price | Google Sheets | 미추적 행 조회 |
| Filter Rows Ready for Exit | Code | 60분+ 경과 필터 |
| Has Rows to Track? | If | 빈 결과 체크 |
| Split Per Row | SplitInBatches | 행별 루프 |
| Yahoo Finance - Exit Price | HTTP | 종료가 조회 |
| Extract Exit Price + Change% | Code | 종료가 + 수익률 |
| Got Exit Price? | If | 가격 유효 체크 |
| Update DB - Exit Price | Google Sheets | DB 업데이트 |

### 기타 (6개)
| 노드 | 유형 | 역할 |
|------|------|------|
| No Results - Stop | NoOp | 정지 |
| Already Exists - Skip | NoOp | 중복 스킵 |
| SKIP (Discarded) | NoOp | 점수 미달 스킵 |
| No Exit Price - Skip | NoOp | 가격 없음 스킵 |
| No Rows - Stop | NoOp | 추적 대상 없음 |
| Calculate Performance Summary | Code | 성과 집계 |
