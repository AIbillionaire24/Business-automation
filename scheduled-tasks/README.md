# 예약 작업 자동화

> ⚠️ 공개용 사본 — 서비스 도메인·이름은 플레이스홀더(`lms.example.com`, `LMS`)로 바꿨습니다. 자격증명은 저장소에 없습니다.

| 파일 | 하는 일 |
|---|---|
| `open_lms_prefill.ps1` | 평일 업무 시작 시 업무 포털을 열고 로그인 ID/비밀번호 자동 입력. CDP(Chrome DevTools Protocol) 우선, 실패 시 UI Automation. **허용 도메인(https) 탭에만 입력**, 확인 못 하면 중단 |
| `update_lms_password.ps1` | 6개월 주기 비밀번호 변경 시 자격증명 재저장. DPAPI(`Export-Clixml`)로 암호화, 입력은 `Read-Host -AsSecureString` (비밀번호를 명령줄 인자로 받지 않도록 설계) |
| `launch_ldplayer_hiworks.ps1` | 에뮬레이터 + 모바일 메신저 실행 |
| `tampermonkey/` | 게시판 새 원격요청 알림(소리), 로컬 설치 스크립트 |
