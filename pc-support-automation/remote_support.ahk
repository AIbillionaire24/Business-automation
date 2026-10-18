#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2
SendMode "Event"

; ============================================
; 원격지원 안내 메시지 자동 입력 v6.2
;
; 용도: 하이웍스 메신저(또는 휴대폰과 연결)에서 /re 입력
;       -> 인증번호 수동 입력 -> 안내문 + 이미지 자동 삽입
;
; v6.2 (2026-08-27): /re 는 되는데 /no 만 안 걸리는 건 조사 중.
;   먼저 확인한 것 - :*OB0:/no:: 구문 자체는 정상이다.
;   (격리 스크립트에서 /re 와 /no 를 같은 조건으로 보냈더니 둘 다 발동했다)
;   그래서 구문이 아니라 실사용 입력 단계가 문제인데, 지금 코드로는 그걸 못 좁힌다.
;   - 핫스트링 본문의 try 에 catch 가 없었다. AHK v2 에서 catch 없는 try 는
;     에러를 전부 조용히 삼킨다 -> 실패해도 화면에 아무것도 안 뜨니 원인 불명이었다.
;     catch 를 붙여 사유를 띄우고 로그에 남긴다.
;   - 발동 시각과 그때의 창 제목을 C:\scripts\logs\remote_support.log 에 기록한다.
;     다음 실패 때 이 로그 한 줄로 갈린다:
;       · /no 쳤는데 로그가 없다   = 핫스트링이 아예 안 걸린 것(입력 단계)
;       · 로그는 있는데 안 들어갔다 = 함수 쪽
;   - 핫스트링에 ? 옵션 추가(:*OB0: -> :*?OB0:). 기본 규칙상 바로 앞 글자가
;     글자·숫자면 핫스트링이 안 걸리는데, 한글 쓰다가 이어서 /no 를 치면
;     여기 걸릴 수 있다. ? 가 그 제한을 없앤다. 부작용은 단어 중간에서도
;     걸리는 것뿐이라 메신저에선 무해하다.
;   ※ 안 될 때는 예비 단축키 Ctrl+Alt+N (또는 트레이 메뉴)을 쓰면 된다.
;
; 브라우저 청소/보안프로그램 점검 기능은 v6.0에서 제거했습니다.
; 그 용도는 아래 도구함을 쓰세요.
;   C:\Users\USERNAME\Desktop\pc원격지원스크립트\Run-Toolkit.bat
; ============================================

; 설정
REMOTE_URL := "https://988.co.kr"
REMOTE_IMAGE_PATH := "C:\Users\USERNAME\OneDrive\바탕 화면\인수인계_업무자동화진행중\remotepicture.png"
HIWORKS_TITLE := "하이웍스"
NEWLINE_KEY := "+{Enter}"
SEND_DELAY := 150
PASTE_DELAY := 500
FOCUS_WAIT := 300

; ── 원격지원 접수 마감 ──────────────────────────────────────
; 1건에 30~40분이 걸리므로 이 시각 이후 접수는 19:00 안에 못 끝낸다.
; 시각을 바꾸려면 여기만 고치면 된다.
CUTOFF_HOUR := 18
CUTOFF_MIN  := 0
CUTOFF_NOTIFIED := false
CutoffGui := ""

; /no 로 삽입할 안내문. 이 배열만 고치면 문구가 바뀐다.
NOSUPPORT_LINES := [
    "안녕하세요 원격지원팀입니다.",
    "",
    "선생님^^ 원격 요청 주셔서 감사합니다.",
    "",
    "각 부서 요청을 순서대로 지원해 드리고 있어",
    "금일 중에는 힘들 것 같습니다.",
    "",
    "오후 1시 이후 하이웍스 메신저로 연락 부탁드리겠습니다.",
    "",
    "지원 시간은 평일 오후 1시~7시입니다.",
    "",
    "감사합니다."
]


; ── 진단 로그 ────────────────────────────────────────────────
; /no 가 안 걸리는 원인을 좁히려고 넣었다. 발동 자체가 안 되면 여기에 아무것도 안 남는다.
; 그게 곧 '핫스트링이 안 걸렸다'는 증거가 된다(함수 실패와 구분되는 지점).
LOG_PATH := "C:\scripts\logs\remote_support.log"

HsLog(msg) {
    global LOG_PATH
    try {
        win := ""
        try win := WinGetTitle("A")
        FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") " | " msg " | 창: " win "`n", LOG_PATH, "UTF-8"
    }
}

; 유틸리티 함수들
IMETest() {
    try {
        return SendMessage(0x0283, 0x0005, 0,, "A")
    } catch {
        return 0
    }
}

SwitchToEnglish() {
    try {
        if (IMETest()) {
            Send "{vk15sc138}"
            Sleep 300
        }
    }
}

IsHiworks() {
    global HIWORKS_TITLE
    return WinActive(HIWORKS_TITLE) || WinActive("ahk_exe hiworks.exe") || WinActive("ahk_exe HiworksMessenger.exe")
}

IsPhoneLink() {
    try {
        title := WinGetTitle("A")
        return WinActive("ahk_exe PhoneExperienceHost.exe") || WinActive("ahk_exe YourPhone.exe") || WinActive("ahk_exe YourPhoneAppProxy.exe") || InStr(title, "휴대폰과 연결") || InStr(title, "Phone Link")
    } catch {
        return false
    }
}

IsMessageCommandTarget() {
    return IsHiworks() || IsPhoneLink()
}

; 대상 창이 실제로 활성 상태인지 보장한다.
; (인증번호 InputBox / 이미지 선택 MsgBox 를 거치는 동안
;  사용자가 다른 창을 클릭하면 엉뚱한 곳에 붙여넣기가 들어가므로 필수)
EnsureTarget(hwnd) {
    if !hwnd
        return false
    if WinActive("ahk_id " hwnd)
        return true
    try {
        WinActivate "ahk_id " hwnd
        return WinWaitActive("ahk_id " hwnd,, 3) ? true : false
    } catch {
        return false
    }
}

CheckFileExists(filePath) {
    try {
        return FileExist(filePath) != ""
    } catch {
        return false
    }
}

LoadImageForHiworks(imagePath, hwnd) {
    try {
        ; PowerShell 홑따옴표 문자열 안에서는 ' 만 이스케이프 대상이다.
        escapedPath := StrReplace(imagePath, "'", "''")
        psScript := "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; `$img = [System.Drawing.Image]::FromFile('" escapedPath "'); [System.Windows.Forms.Clipboard]::SetImage(`$img); `$img.Dispose()"
        RunWait 'powershell.exe -WindowStyle Hidden -NoProfile -Command "' psScript '"',, "Hide"
        Sleep 400

        if !EnsureTarget(hwnd)
            throw Error("이미지 로드 후 메신저 창 복귀 실패")
        Sleep 300
        return true
    } catch as err {
        MsgBox "이미지 로드 실패: " err.Message, "오류", "IconX"
        return false
    }
}

HasClipboardImage() {
    try {
        return DllCall("IsClipboardFormatAvailable", "uint", 2) || DllCall("IsClipboardFormatAvailable", "uint", 8) || DllCall("IsClipboardFormatAvailable", "uint", 17)
    } catch {
        return false
    }
}

BuildNoSupportMessage() {
    global NOSUPPORT_LINES
    out := ""
    for i, line in NOSUPPORT_LINES {
        out .= (i = 1 ? "" : "`n") . line
    }
    return out
}

SendNoSupportMessage() {
    hwnd := WinGetID("A")
    if !hwnd {
        MsgBox "대상 창을 찾을 수 없습니다.", "오류", "IconX"
        return
    }
    try {
        if IsHiworks()
            SendTextForHiworks(BuildNoSupportMessage(), hwnd)
        else
            SendTextViaClipboard(BuildNoSupportMessage(), hwnd)
        HsLog("접수불가 안내 입력 완료")
        TrayTip "접수 불가 안내 입력 완료", "내용 확인 후 전송하세요.", 1
    } catch as err {
        HsLog("접수불가 안내 실패: " err.Message)
        MsgBox "안내문 입력 중 오류: " err.Message, "오류", "IconX"
    }
}

SendTextForHiworks(text, hwnd) {
    global PASTE_DELAY, FOCUS_WAIT

    if !EnsureTarget(hwnd)
        throw Error("메신저 창이 활성 상태가 아닙니다")

    Sleep FOCUS_WAIT
    SwitchToEnglish()
    Sleep 200

    oldClip := ClipboardAll()

    try {
        A_Clipboard := ""
        Sleep 50
        A_Clipboard := text

        if !ClipWait(1.5)
            throw Error("클립보드 복사 실패")

        Sleep 150
        Send "^v"
        Sleep PASTE_DELAY

    } finally {
        Sleep 250
        A_Clipboard := oldClip
        Sleep 150
        oldClip := ""
    }
}

SendTextViaClipboard(text, hwnd) {
    global PASTE_DELAY

    if !EnsureTarget(hwnd)
        throw Error("대상 창이 활성 상태가 아닙니다")

    oldClip := ClipboardAll()

    try {
        A_Clipboard := ""
        Sleep 30
        A_Clipboard := text
        if !ClipWait(1)
            throw Error("클립보드 복사 실패")
        Sleep 100
        Send "^v"
        Sleep PASTE_DELAY
    } finally {
        Sleep 200
        A_Clipboard := oldClip
        Sleep 100
        oldClip := ""
    }
}

CleanCode(code) => RegExReplace(Trim(code), "[^\d]")

PromptCode(defaultCode := "") {
    ib := InputBox("애니서포트 인증번호를 입력하세요:`n(숫자만 입력, 공백/하이픈 자동 제거)", "원격 인증번호", "w300 h150", defaultCode)
    if (ib.Result != "OK")
        return ""

    cleaned := CleanCode(ib.Value)
    if (cleaned = "") {
        MsgBox "유효한 인증번호를 입력해주세요.", "오류", "Iconx"
        return ""
    }
    return cleaned
}

BuildHeader() {
    global REMOTE_URL
    return "안녕하세요 선생님^^ 원격지원팀입니다.`n`n사이트 이용 관련 원격 요청주셔서 안내드립니다.`n`n아래 사이트로 접속하신 후 인증번호를 입력해 주세요.`n" REMOTE_URL
}

BuildFooter(code) {
    return "`n`n[인증번호 : " code "]`n`n점검 가능하실때 보내드린 이미지 참고하셔서 원격 접속 부탁드립니다~`n감사합니다!"
}

SendRemoteMessage() {
    global NEWLINE_KEY, PASTE_DELAY, SEND_DELAY, REMOTE_IMAGE_PATH

    targetWin := WinGetID("A")
    if !targetWin {
        MsgBox "대상 창을 찾을 수 없습니다.", "오류", "IconX"
        return
    }
    currentIsHiworks := IsHiworks()

    code := PromptCode()
    if (code = "")
        return

    fileExists := CheckFileExists(REMOTE_IMAGE_PATH)
    clipHasImage := HasClipboardImage()
    imageSource := "none"

    if (fileExists && clipHasImage) {
        result := MsgBox("🖼️ 파일과 📋 클립보드 모두 이미지가 있습니다.`n`n예: 파일 사용`n아니오: 클립보드 사용`n취소: 이미지 없이", "이미지 선택", "YesNoCancel Iconi")
        imageSource := (result = "Yes") ? "file" : (result = "No") ? "clipboard" : "none"
    } else if (fileExists) {
        result := MsgBox("🖼️ 저장된 이미지 파일을 자동으로 첨부합니다.`n`n계속하시겠습니까?", "자동 이미지 첨부", "YesNo Iconi")
        imageSource := (result = "Yes") ? "file" : "none"
    } else if (clipHasImage) {
        result := MsgBox("📋 클립보드의 이미지를 사용하시겠습니까?", "클립보드 이미지", "YesNo Iconi")
        imageSource := (result = "Yes") ? "clipboard" : "none"
    } else {
        result := MsgBox("⚠️ 이미지가 없습니다. 텍스트만 전송하시겠습니까?", "이미지 없음", "YesNo Icon!")
        if (result = "No")
            return
    }

    ; 대화상자를 거치는 동안 포커스가 옮겨갔을 수 있으므로 여기서 한 번 확정한다.
    if !EnsureTarget(targetWin) {
        MsgBox "메신저 창으로 돌아가지 못했습니다.`n입력된 내용이 없는지 확인 후 다시 시도해주세요.", "전송 취소", "IconX"
        return
    }

    oldClip := ClipboardAll()

    try {
        if currentIsHiworks {
            SendTextForHiworks(BuildHeader(), targetWin)
        } else {
            SendTextViaClipboard(BuildHeader(), targetWin)
        }

        Sleep 150
        Send NEWLINE_KEY
        Sleep SEND_DELAY
        Send NEWLINE_KEY
        Sleep SEND_DELAY

        if (imageSource = "file") {
            if LoadImageForHiworks(REMOTE_IMAGE_PATH, targetWin) {
                Sleep 400
                Send "^v"
                Sleep PASTE_DELAY * 2
                Send NEWLINE_KEY
                Sleep SEND_DELAY
                Send NEWLINE_KEY
                Sleep SEND_DELAY
                TrayTip "파일 이미지 첨부 완료!", "원격지원", 1
            } else {
                MsgBox "파일 로드 실패! 텍스트만 전송됩니다.", "경고", "Icon!"
            }
        } else if (imageSource = "clipboard") {
            if !EnsureTarget(targetWin)
                throw Error("메신저 창이 활성 상태가 아닙니다")
            A_Clipboard := oldClip
            Sleep 300
            Send "^v"
            Sleep PASTE_DELAY * 2
            Send NEWLINE_KEY
            Sleep SEND_DELAY
            Send NEWLINE_KEY
            Sleep SEND_DELAY
        }

        if currentIsHiworks {
            SendTextForHiworks(BuildFooter(code), targetWin)
        } else {
            SendTextViaClipboard(BuildFooter(code), targetWin)
        }

        TrayTip "원격지원 메시지 입력 완료!", "원격지원", 1

    } catch as err {
        MsgBox "메시지 입력 중 오류: " err.Message, "오류", "IconX"
    } finally {
        Sleep 300
        A_Clipboard := oldClip
        Sleep 150
        oldClip := ""
    }
}

; ============================================
; 핫스트링 (하이웍스 / 휴대폰과 연결 에서만)
; ============================================

#HotIf IsMessageCommandTarget()

; catch 없는 try 는 에러를 전부 조용히 삼킨다 - v6.1 까지 실패해도 아무 표시가
; 없었던 이유가 이것이다. 반드시 catch 를 붙여 사유를 남길 것.
:*?OB0:/re::{
    HsLog("/re 발동")
    try {
        Send "{Backspace 3}"  ; /re 삭제
        Sleep 100
        SendRemoteMessage()
    } catch as err {
        HsLog("/re 실패: " err.Message)
        MsgBox "/re 처리 중 오류: " err.Message, "오류", "IconX"
    }
}

:*?OB0:/no::{
    HsLog("/no 발동")
    try {
        Send "{Backspace 3}"  ; /no 삭제
        Sleep 100
        SendNoSupportMessage()
    } catch as err {
        HsLog("/no 실패: " err.Message)
        MsgBox "/no 처리 중 오류: " err.Message, "오류", "IconX"
    }
}

; 한글 입력 상태에서는 /re 핫스트링이 IME 조합에 막혀 안 걸릴 수 있다.
; 그때 쓰는 예비 단축키. (IME 문제는 핫스트링에만 생기므로
;  핫키를 같은 창 조건 안에 둬도 예비 역할은 그대로다)
^!r::{
    HsLog("Ctrl+Alt+R 발동")
    SendRemoteMessage()
}

^!n::{
    HsLog("Ctrl+Alt+N 발동")
    SendNoSupportMessage()
}

#HotIf

; 트레이 메뉴
A_TrayMenu.Delete()
A_TrayMenu.Add("🖼️ 원격지원 안내", (*) => IsMessageCommandTarget() ? SendRemoteMessage() : MsgBox("하이웍스 또는 휴대폰과 연결 창이 활성화되지 않았습니다!", "안전 가드", "Icon!"))
A_TrayMenu.Add("🔔 마감 배너 다시 띄우기", (*) => ShowCutoffBanner())
A_TrayMenu.Add("🚫 접수 불가 안내", (*) => IsMessageCommandTarget() ? SendNoSupportMessage() : MsgBox("하이웍스 또는 휴대폰과 연결 창이 활성화되지 않았습니다!", "안전 가드", "Icon!"))
A_TrayMenu.Add()
; A_TrayMenu.Delete() 로 기본 메뉴를 지우면 AHK 기본 'Reload Script' 도 같이 사라진다.
; 그래서 스크립트를 고쳐도 다시 읽을 방법이 트레이에 없었다. 되살려 둔다.
; Reload() 는 같은 권한으로 다시 뜨므로 관리자로 실행 중이어도 그대로 유지된다.
A_TrayMenu.Add("🔄 스크립트 다시 읽기", (*) => Reload())
A_TrayMenu.Add("종료", (*) => ExitApp())

; ── 접수 마감 알림 ──────────────────────────────────────────
; 이 스크립트는 launch_apps.ps1 이 띄우고 close_apps.ps1 이 내리므로
; 근무일에만 살아 있다. 주말/공휴일 검사는 그쪽에서 이미 한다.
; 바탕화면 우측 하단에 계속 떠 있는 배너.
; 트레이 알림은 몇 초 뒤 사라져서 놓칠 수 있으므로 눈에 남는 표시를 같이 띄운다.
; 클릭하면 닫히고, 19:10 close_apps.ps1 이 AHK 를 내릴 때 같이 사라진다.
ShowCutoffBanner() {
    global CutoffGui, CUTOFF_HOUR, CUTOFF_MIN
    if IsSet(CutoffGui) && IsObject(CutoffGui)
        return
    w := 340
    h := 74
    CutoffGui := Gui("+AlwaysOnTop -Caption +ToolWindow +Owner", "접수마감")
    CutoffGui.BackColor := "C0392B"
    CutoffGui.MarginX := 0
    CutoffGui.MarginY := 0
    CutoffGui.SetFont("s12 cWhite Bold", "맑은 고딕")
    opt1 := "x16 y12 w" . (w - 32) . " BackgroundTrans"
    txt1 := Format("{:02}:{:02} 이후 원격 접수 불가", CUTOFF_HOUR, CUTOFF_MIN)
    t1 := CutoffGui.Add("Text", opt1, txt1)
    CutoffGui.SetFont("s9 cWhite Norm")
    opt2 := "x16 y38 w" . (w - 32) . " BackgroundTrans"
    txt2 := "1건 30~40분 · 19:00 종료  |  /no 로 안내  (클릭하면 닫힘)"
    t2 := CutoffGui.Add("Text", opt2, txt2)
    t1.OnEvent("Click", (*) => HideCutoffBanner())
    t2.OnEvent("Click", (*) => HideCutoffBanner())
    x := A_ScreenWidth - w - 24
    y := A_ScreenHeight - h - 70
    CutoffGui.Show("x" x " y" y " w" w " h" h " NoActivate")
}

HideCutoffBanner() {
    global CutoffGui
    if IsSet(CutoffGui) && IsObject(CutoffGui) {
        try CutoffGui.Destroy()
        CutoffGui := ""
    }
}

CheckCutoff() {
    global CUTOFF_HOUR, CUTOFF_MIN, CUTOFF_NOTIFIED
    nowMin := Integer(A_Hour) * 60 + Integer(A_Min)
    cutMin := CUTOFF_HOUR * 60 + CUTOFF_MIN
    if (nowMin >= cutMin) {
        if !CUTOFF_NOTIFIED {
            CUTOFF_NOTIFIED := true
            msg := "1건 30~40분이라 19:00 안에 못 끝냅니다.`n새 요청은 /no 로 안내하세요."
            ttl := "원격지원 접수 마감 " . Format("{:02}:{:02}", CUTOFF_HOUR, CUTOFF_MIN)
            TrayTip msg, ttl, 1
            ShowCutoffBanner()
        }
    } else {
        CUTOFF_NOTIFIED := false
        HideCutoffBanner()
    }
}
SetTimer CheckCutoff, 60000
CheckCutoff()

TrayTip "원격지원 v6.1 실행!", "/re 원격안내  ·  /no 접수불가안내`n예비: Ctrl+Alt+R / Ctrl+Alt+N", 1
