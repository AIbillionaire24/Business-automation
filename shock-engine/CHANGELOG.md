# Changelog

## [v39] - 2026-03-30
### Parse GPT + Route Decision v9
- Analyst 이벤트 조건부 Free 허용 (빅테크/반도체 화이트리스트 + score 3 + confidence ≥ 3)
- 추적성 필드 추가 (`routing_reason`, `allow_free_analyst`)

### Parse GPT + Route Decision v8
- thesis 접두어 후처리: GPT가 "한국어 한 문장:", "요약:" 등을 붙이는 문제 해결

### Parse GPT + Route Decision v7
- parseScore 소수 문자열 처리 강화 ("4.5" → 5, "0.8" → 1)

### Parse GPT + Route Decision v6
- normalizeEventType 부분 매칭 강화 (변형 변수 커버)
- shock_score/confidence 파싱 강화 ("4/5", "4점" 형태 처리)

## [v23] - Keyword Filter
- MACRO_ACTION_RE 동사 축소 (says/announces/expects 제거 → 정치 기사 오탐 방지)
- MACRO_CONTEXT_RE 신설: entity + 동사 + 경제 문맥 3중 게이트
- MACRO_ENTITIES_RE에서 white house / pentagon 제거

## [v22] - Keyword Filter
- Codex 보정 3개 반영
- minLen 조건 개선: (isMacroSource || hasMacroEntity) ? 10 : 40
- US Treasury 점 없는 형태 커버 (`u\.?s\.?`)
- MACRO_ACTION_RE 신설 (entity + 동사 조합 보조 경로)

## [v20-v21] - Keyword Filter
- FinancialJuice 매크로 소스 통합
- MACRO_KEYWORDS, MACRO_ENTITIES_RE 신설
- 매크로 소스 최소 길이 10자 (ECB HOLDS RATES 등 대응)

## [v14] - Parse RSS
- FinancialJuice 패스스루 로직 추가
- PASSTHROUGH_SOURCES Set 방식 (Codex + ChatGPT 권장)
- 패스스루 항목 normalizeLink() 적용

## [v1-v9] - 초기 구축
- 기본 RSS 수집 파이프라인
- GPT 충격도 분석 연동
- 텔레그램 Premium/Free 채널 분리
- Google Sheets 중복 체크
- Yahoo Finance 진입가/종료가 추적
