#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2
SendMode "Event"

; ============================================================
; 설정 — 실제 환경에 맞게 변경하세요
; ============================================================
REMOTE_URL := "https://your-remote-support.example.com"          ; ← 원격지원 접속 URL
REMOTE_IMAGE_PATH := "C:\Scripts\remote_guide_image.png"         ; ← 원격 접속 안내 이미지 경로
REMOTE_TOOL_TITLE := "RemoteTool"                                ; ← 원격지원 도구 창 제목
REMOTE_TOOL_EXE := "RemoteTool.exe"                              ; ← 원격지원 도구 프로세스명
MESSENGER_TITLE := "Messenger"                                   ; ← 사내 메신저 창 제목
NEWLINE_KEY := "+{Enter}"
SEND_DELAY := 150
PASTE_DELAY := 500
FOCUS_WAIT := 300
TAB_TO_TIMERANGE := 1
USE_CLIPBOARD_PASTE := true

; ============================================================
; 유틸리티 함수
; ============================================================
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

IsRemoteTool() {
    global REMOTE_TOOL_TITLE, REMOTE_TOOL_EXE
    return WinActive(REMOTE_TOOL_TITLE) || WinActive("ahk_exe " REMOTE_TOOL_EXE)
}

IsMessenger() {
    global MESSENGER_TITLE
    return WinActive(MESSENGER_TITLE)
}

WaitForWindowFocus(timeout := 2000) {
    startTime := A_TickCount
    while (A_TickCount - startTime < timeout) {
        if WinActive("A")
            return true
        Sleep 50
    }
    return false
}

CheckFileExists(filePath) {
    try {
        return FileExist(filePath) != ""
    } catch {
        return false
    }
}

SafeClipboardOperation(url) {
    global PASTE_DELAY
    oldClip := ClipboardAll()
    success := false
    
    try {
        A_Clipboard := ""
        Sleep 50
        A_Clipboard := url
        if !ClipWait(1.5)
            throw Error("클립보드 복사 실패")
        
        Sleep 150
        Send "^a"
        Sleep 100
        Send "^v"
        Sleep PASTE_DELAY
        success := true
    } finally {
        Sleep 250
        A_Clipboard := oldClip
        Sleep 150
        oldClip := ""
    }
    return success
}

LoadImageForMessenger(imagePath) {
    try {
        escapedPath := StrReplace(imagePath, "\", "\\")
        psScript := "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; `$img = [System.Drawing.Image]::FromFile('" escapedPath "'); [System.Windows.Forms.Clipboard]::SetImage(`$img); `$img.Dispose()"
        activeWin := WinGetID("A")
        RunWait 'powershell.exe -WindowStyle Hidden -NoProfile -Command "' psScript '"',, "Hide"
        Sleep 400
        
        if activeWin {
            try {
                WinActivate "ahk_id " activeWin
                WinWaitActive "ahk_id " activeWin,, 2
            }
            Sleep 300
        }
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

SendTextForMessenger(text) {
    global PASTE_DELAY, FOCUS_WAIT
    
    if !WaitForWindowFocus()
        throw Error("창 포커스 대기 시간 초과")
    
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

SendTextViaClipboard(text) {
    global PASTE_DELAY
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

; ============================================================
; 브라우저 캐시 삭제 함수
; ============================================================
CleanChromeURL() {
    global USE_CLIPBOARD_PASTE, TAB_TO_TIMERANGE
    TrayTip "Chrome 설정 페이지로 이동...", "원격 캐시 청소", 1
    Sleep 500
    
    try {
        Send "^l"
        Sleep 400
        SwitchToEnglish()
        
        if USE_CLIPBOARD_PASTE {
            if !SafeClipboardOperation("chrome://settings/clearBrowserData")
                throw Error("클립보드 작업 실패")
        } else {
            Send "^a"
            Sleep 50
            SendText "chrome://settings/clearBrowserData"
            Sleep 200
        }
        
        Send "{Enter}"
        Sleep 1500
        
        Loop TAB_TO_TIMERANGE {
            Send "{Tab}"
            Sleep 200
        }
        
        Send "!{Down}"
        Sleep 300
        Send "{End}"
        Sleep 300
        Send "{Enter}"
        Sleep 500
        Send "{Enter}"
        Sleep 1500
        
        TrayTip "Chrome 기록 삭제 완료!", "원격 캐시 청소", 1
        return true
    } catch as err {
        MsgBox "Chrome 청소 중 오류: " err.Message, "오류", "IconX"
        return false
    }
}

CleanEdgeURL() {
    global USE_CLIPBOARD_PASTE, TAB_TO_TIMERANGE
    TrayTip "Edge 설정 페이지로 이동...", "원격 캐시 청소", 1
    Sleep 500
    
    try {
        Send "^l"
        Sleep 400
        SwitchToEnglish()
        
        if USE_CLIPBOARD_PASTE {
            if !SafeClipboardOperation("edge://settings/clearBrowserData")
                throw Error("클립보드 작업 실패")
        } else {
            Send "^a"
            Sleep 50
            SendText "edge://settings/clearBrowserData"
            Sleep 200
        }
        
        Send "{Enter}"
        Sleep 1500
        
        Loop TAB_TO_TIMERANGE {
            Send "{Tab}"
            Sleep 200
        }
        
        Send "!{Down}"
        Sleep 300
        Send "{End}"
        Sleep 300
        Send "{Enter}"
        Sleep 500
        Send "{Enter}"
        Sleep 1500
        
        TrayTip "Edge 기록 삭제 완료!", "원격 캐시 청소", 1
        return true
    } catch as err {
        MsgBox "Edge 청소 중 오류: " err.Message, "오류", "IconX"
        return false
    }
}

CleanBrowserSimple() {
    global TAB_TO_TIMERANGE
    TrayTip "브라우저 기록 삭제 시작...", "원격 캐시 청소", 1
    Sleep 500
    
    try {
        Send "^+{Del}"
        Sleep 1000
        
        Loop TAB_TO_TIMERANGE {
            Send "{Tab}"
            Sleep 200
        }
        
        Send "!{Down}"
        Sleep 300
        Send "{End}"
        Sleep 300
        Send "{Enter}"
        Sleep 500
        Send "{Enter}"
        Sleep 1000
        
        TrayTip "브라우저 기록 삭제 완료!", "원격 캐시 청소", 1
        return true
    } catch as err {
        MsgBox "브라우저 청소 중 오류: " err.Message, "오류", "IconX"
        return false
    }
}

QuickSelectBrowser() {
    result := MsgBox("어떤 브라우저로 청소하시겠습니까?`n`n예: Chrome 방식 (추천)`n아니오: Edge 방식`n취소: 범용 방식", "브라우저 선택", "YesNoCancel Iconi")
    
    switch result {
        case "Yes": return CleanChromeURL()
        case "No": return CleanEdgeURL()
        case "Cancel": return CleanBrowserSimple()
    }
    return false
}

; ============================================================
; 원격지원 메시지 생성·전송
; ============================================================
CleanCode(code) => RegExReplace(Trim(code), "[^\d]")

PromptCode(defaultCode := "") {
    ib := InputBox("원격지원 인증번호를 입력하세요:`n(숫자만 입력, 공백/하이픈 자동 제거)", "원격 인증번호", "w300 h150", defaultCode)
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
    return "안녕하세요~선생님^^`n`n사이트 이용 관련 원격 요청주셔서 안내드립니다.`n`n아래 사이트로 접속하신 후 인증번호를 입력해 주세요.`n" REMOTE_URL
}

BuildFooter(code) {
    return "`n`n[인증번호 : " code "]`n`n점검 가능하실때 보내드린 이미지 참고하셔서 원격 접속 부탁드립니다~`n감사합니다!"
}

SendRemoteMessage() {
    global NEWLINE_KEY, PASTE_DELAY, SEND_DELAY, REMOTE_IMAGE_PATH
    
    currentIsMessenger := IsMessenger()
    
    if !WaitForWindowFocus() {
        MsgBox "창이 활성화되지 않았습니다!", "오류", "IconX"
        return
    }
    
    Sleep 200
    Send "^a"
    Sleep 100
    Send "{Delete}"
    Sleep 150
    
    code := PromptCode()
    if (code = "")
        return
    
    fileExists := CheckFileExists(REMOTE_IMAGE_PATH)
    clipHasImage := HasClipboardImage()
    imageSource := "none"
    
    if (fileExists && clipHasImage) {
        result := MsgBox("파일과 클립보드 모두 이미지가 있습니다.`n`n예: 파일 사용`n아니오: 클립보드 사용`n취소: 이미지 없이", "이미지 선택", "YesNoCancel Iconi")
        imageSource := (result = "Yes") ? "file" : (result = "No") ? "clipboard" : "none"
    } else if (fileExists) {
        result := MsgBox("저장된 이미지 파일을 자동으로 첨부합니다.`n`n계속하시겠습니까?", "자동 이미지 첨부", "YesNo Iconi")
        imageSource := (result = "Yes") ? "file" : "none"
    } else if (clipHasImage) {
        result := MsgBox("클립보드의 이미지를 사용하시겠습니까?", "클립보드 이미지", "YesNo Iconi")
        imageSource := (result = "Yes") ? "clipboard" : "none"
    } else {
        result := MsgBox("이미지가 없습니다. 텍스트만 전송하시겠습니까?", "이미지 없음", "YesNo Icon!")
        if (result = "No")
            return
    }
    
    oldClip := ClipboardAll()
    
    try {
        if currentIsMessenger {
            SendTextForMessenger(BuildHeader())
        } else {
            SendTextViaClipboard(BuildHeader())
        }
        
        Sleep 150
        Send NEWLINE_KEY
        Sleep SEND_DELAY
        Send NEWLINE_KEY
        Sleep SEND_DELAY
        
        if (imageSource = "file") {
            if LoadImageForMessenger(REMOTE_IMAGE_PATH) {
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
            A_Clipboard := oldClip
            Sleep 300
            Send "^v"
            Sleep PASTE_DELAY * 2
            Send NEWLINE_KEY
            Sleep SEND_DELAY
            Send NEWLINE_KEY
            Sleep SEND_DELAY
        }
        
        if currentIsMessenger {
            SendTextForMessenger(BuildFooter(code))
        } else {
            SendTextViaClipboard(BuildFooter(code))
        }
        
        TrayTip "원격지원 메시지 전송 완료!", "원격지원", 1
        
    } catch as err {
        MsgBox "메시지 전송 중 오류: " err.Message, "오류", "IconX"
    } finally {
        Sleep 300
        A_Clipboard := oldClip
        Sleep 150
        oldClip := ""
    }
}

; ============================================================
; 핫스트링 (사내 메신저에서 /명령어 사용)
; ============================================================

:*OB0:/start::{
    try {
        Send "{Backspace 6}"
        Sleep 100
        if IsMessenger() {
            SendTextForMessenger("안녕하세요~`n업무 시작합니다!^^")
        } else {
            SendTextViaClipboard("안녕하세요~`n업무 시작합니다!^^")
        }
    }
}

:*OB0:/end::{
    try {
        Send "{Backspace 4}"
        Sleep 100
        if IsMessenger() {
            SendTextForMessenger("업무 종료하겠습니다.`n감사합니다!^^")
        } else {
            SendTextViaClipboard("업무 종료하겠습니다.`n감사합니다!^^")
        }
    }
}

:*OB0:/remo::{
    try {
        Send "{Backspace 5}"
        Sleep 100
        SendRemoteMessage()
    }
}

; ============================================================
; 단축키 (원격지원 도구 창에서만 작동)
; ============================================================
#HotIf IsRemoteTool()

^r::{
    SendRemoteMessage()
}

^!q::{
    QuickSelectBrowser()
}

^!c::{
    if MsgBox("Chrome 설정 페이지로 이동하여 기록을 삭제합니다.`n`n계속하시겠습니까?", "Chrome 청소", "YesNo Iconi") = "Yes"
        CleanChromeURL()
}

^!e::{
    if MsgBox("Edge 설정 페이지로 이동하여 기록을 삭제합니다.`n`n계속하시겠습니까?", "Edge 청소", "YesNo Iconi") = "Yes"
        CleanEdgeURL()
}

^!+c::{
    if MsgBox("Ctrl+Shift+Del 방식으로 기록을 삭제합니다.`n`n계속하시겠습니까?", "범용 청소", "YesNo Icon!") = "Yes"
        CleanBrowserSimple()
}

#HotIf

^!r::{
    SendRemoteMessage()
}

; ============================================================
; 트레이 메뉴
; ============================================================
A_TrayMenu.Delete()
A_TrayMenu.Add("원격지원 안내", (*) => SendRemoteMessage())
A_TrayMenu.Add()
A_TrayMenu.Add("빠른 브라우저 선택", (*) => IsRemoteTool() ? QuickSelectBrowser() : MsgBox("원격지원 도구 창이 활성화되지 않았습니다!", "안전 가드", "Icon!"))
A_TrayMenu.Add("Chrome 청소", (*) => IsRemoteTool() ? CleanChromeURL() : MsgBox("원격지원 도구 창이 활성화되지 않았습니다!", "안전 가드", "Icon!"))
A_TrayMenu.Add("Edge 청소", (*) => IsRemoteTool() ? CleanEdgeURL() : MsgBox("원격지원 도구 창이 활성화되지 않았습니다!", "안전 가드", "Icon!"))
A_TrayMenu.Add()
A_TrayMenu.Add("종료", (*) => ExitApp())

TrayTip "원격지원 v5.0 실행!", "준비 완료! /remo 또는 Ctrl+R", 1
