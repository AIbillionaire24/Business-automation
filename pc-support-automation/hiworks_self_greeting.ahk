#Requires AutoHotkey v2.0
#SingleInstance Force

SetTitleMatchMode 2
SendMode "Event"
CoordMode "Mouse", "Screen"
DetectHiddenWindows true

CHAT_TITLE := "동료C2"
CHAT_SEARCH_QUERY := "동료C2"
MAIN_TITLE := "하이웍스 메신저"
HIWORKS_EXE := "HiworksMessenger.exe"
HIWORKS_PATH := "C:\Program Files (x86)\Hiworks\Messenger\HiworksMessenger.exe"
MESSAGE := "안녕하세요~`n업무 시작합니다!^^"
LOG_FILE := "C:\Scripts\logs\hiworks_self_greeting.log"
DRY_RUN := false

; Hiworks layout offsets from the active chat window.
; Adjust only these if Hiworks changes its chat input/button layout.
INPUT_X_RATIO := 0.50
INPUT_Y_OFFSET_FROM_BOTTOM := 78
SEND_X_OFFSET_FROM_RIGHT := 46
SEND_Y_OFFSET_FROM_BOTTOM := 42

; Main messenger offsets used when the chat room is not already open.
MAIN_CHAT_TAB_X_OFFSET := 78
MAIN_CHAT_TAB_Y_OFFSET := 145
MAIN_SEARCH_X_RATIO := 0.50
MAIN_SEARCH_Y_OFFSET := 185
MAIN_FIRST_ROOM_X_RATIO := 0.17
MAIN_FIRST_ROOM_Y_OFFSET := 264

skipNext := false
for index, arg in A_Args {
    if skipNext {
        skipNext := false
        continue
    }

    if (arg = "--dry-run") {
        DRY_RUN := true
    } else if (arg = "--chat-title" && index < A_Args.Length) {
        CHAT_TITLE := A_Args[index + 1]
        skipNext := true
    } else if (arg = "--search" && index < A_Args.Length) {
        CHAT_SEARCH_QUERY := A_Args[index + 1]
        skipNext := true
    } else if (arg = "--message" && index < A_Args.Length) {
        MESSAGE := StrReplace(A_Args[index + 1], "\n", "`n")
        skipNext := true
    } else if (arg = "--message-file" && index < A_Args.Length) {
        MESSAGE := RTrim(FileRead(A_Args[index + 1], "UTF-8"), "`r`n")
        skipNext := true
    }
}

EnsureLogDir() {
    global LOG_FILE
    dir := RegExReplace(LOG_FILE, "\\[^\\]+$")
    if !DirExist(dir)
        DirCreate dir
}

WriteLog(message) {
    global LOG_FILE
    EnsureLogDir()
    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    FileAppend "[" timestamp "] " message "`n", LOG_FILE, "UTF-8"
}

Fail(stage, detail := "") {
    text := "하이웍스 자동 인사 실패 - " stage
    if (detail != "")
        text .= "`n" detail
    WriteLog "[ERROR] " StrReplace(text, "`n", " | ")
    ExitApp 1
}

FindHiworksChatWindow() {
    global CHAT_TITLE, HIWORKS_EXE

    for hwnd in WinGetList(CHAT_TITLE) {
        try {
            processName := WinGetProcessName("ahk_id " hwnd)
            title := WinGetTitle("ahk_id " hwnd)
            if (processName = HIWORKS_EXE && InStr(title, CHAT_TITLE))
                return hwnd
        }
    }

    hwnd := WinExist(CHAT_TITLE)
    return hwnd ? hwnd : 0
}

FindHiworksMainWindow() {
    global MAIN_TITLE, HIWORKS_EXE

    for hwnd in WinGetList("ahk_exe " HIWORKS_EXE) {
        try {
            title := WinGetTitle("ahk_id " hwnd)
            WinGetPos &winX, &winY, &winW, &winH, "ahk_id " hwnd
            if (InStr(title, MAIN_TITLE) || (winW <= 500 && winH >= 500))
                return hwnd
        }
    }

    hwnd := WinExist("ahk_exe " HIWORKS_EXE)
    return hwnd ? hwnd : 0
}

EnsureHiworksMainWindow() {
    global HIWORKS_PATH

    mainId := FindHiworksMainWindow()
    if mainId
        return mainId

    WriteLog "Visible main window not found; trying to show Hiworks by launching executable"
    if !FileExist(HIWORKS_PATH)
        return 0

    try {
        Run '"' HIWORKS_PATH '"'
        Sleep 3000
    } catch as err {
        WriteLog "[ERROR] Failed to launch Hiworks executable: " err.Message
        return 0
    }

    return FindHiworksMainWindow()
}

PasteText(text) {
    oldClip := ClipboardAll()
    try {
        A_Clipboard := ""
        Sleep 100
        A_Clipboard := text
        if !ClipWait(2)
            throw Error("클립보드 복사 실패")
        Send "^a"
        Sleep 120
        Send "^v"
        Sleep 300
    } finally {
        Sleep 150
        A_Clipboard := oldClip
        Sleep 100
        oldClip := ""
    }
}

OpenChatFromMainWindow() {
    global CHAT_TITLE, CHAT_SEARCH_QUERY
    global MAIN_SEARCH_X_RATIO, MAIN_SEARCH_Y_OFFSET, MAIN_FIRST_ROOM_X_RATIO, MAIN_FIRST_ROOM_Y_OFFSET

    mainId := EnsureHiworksMainWindow()
    if !mainId
        Fail "메인창 찾기", "하이웍스 메신저 메인창을 찾지 못했습니다."

    try {
        WinShow "ahk_id " mainId
        Sleep 200
        WinRestore "ahk_id " mainId
        Sleep 200
        WinActivate "ahk_id " mainId
    } catch as err {
        Fail "메인창 활성화", err.Message
    }

    if !WinWaitActive("ahk_id " mainId, , 5)
        Fail "메인창 활성화 대기", "하이웍스 메인창을 찾았지만 활성화되지 않았습니다."

    Sleep 700

    try {
        WinGetPos &mainX, &mainY, &mainW, &mainH, "ahk_id " mainId
    } catch as err {
        Fail "메인창 위치 확인", err.Message
    }

    chatTabX := mainX + MAIN_CHAT_TAB_X_OFFSET
    chatTabY := mainY + MAIN_CHAT_TAB_Y_OFFSET
    searchX := mainX + Round(mainW * MAIN_SEARCH_X_RATIO)
    searchY := mainY + MAIN_SEARCH_Y_OFFSET
    resultX := mainX + Round(mainW * MAIN_FIRST_ROOM_X_RATIO)
    resultY := mainY + MAIN_FIRST_ROOM_Y_OFFSET

    WriteLog "Opening chat from main window"
    WriteLog "Main window: x=" mainX ", y=" mainY ", w=" mainW ", h=" mainH
    WriteLog "Click chat tab: x=" chatTabX ", y=" chatTabY
    WriteLog "Click search: x=" searchX ", y=" searchY
    WriteLog "Click first chat result icon: x=" resultX ", y=" resultY

    try {
        Send "{Esc}"
        Sleep 150
        Click chatTabX, chatTabY
        Sleep 700
        Click searchX, searchY
        Sleep 250
        PasteText CHAT_SEARCH_QUERY
        Sleep 1200
        Click resultX, resultY
        Sleep 2500
    } catch as err {
        Fail "채팅방 검색/열기", err.Message
    }

    chatId := FindHiworksChatWindow()
    if chatId
        return chatId

    try {
        WinActivate "ahk_id " mainId
        Sleep 250
        Click resultX, resultY
        Sleep 1800
    } catch {
    }

    return FindHiworksChatWindow()
}

WriteLog "=============================================="
WriteLog "Hiworks self-chat greeting started"

winId := FindHiworksChatWindow()
if !winId {
    WriteLog "Chat window not found; trying to open it from main messenger"
    winId := OpenChatFromMainWindow()
}

if !winId
    Fail "채팅방 열기", '"' CHAT_TITLE '" 채팅방을 자동으로 열지 못했습니다.'

try {
    WinShow "ahk_id " winId
    Sleep 200
    WinRestore "ahk_id " winId
    Sleep 200
    WinActivate "ahk_id " winId
} catch as err {
    Fail "창 활성화", err.Message
}

if !WinWaitActive("ahk_id " winId, , 5)
    Fail "창 활성화 대기", "채팅창을 찾았지만 활성화되지 않았습니다."

Sleep 700

try {
    WinGetPos &winX, &winY, &winW, &winH, "ahk_id " winId
} catch as err {
    Fail "창 위치 확인", err.Message
}

if (winW < 300 || winH < 300)
    Fail "창 크기 확인", "창 크기가 비정상입니다. width=" winW ", height=" winH

inputX := winX + Round(winW * INPUT_X_RATIO)
inputY := winY + winH - INPUT_Y_OFFSET_FROM_BOTTOM
sendX := winX + winW - SEND_X_OFFSET_FROM_RIGHT
sendY := winY + winH - SEND_Y_OFFSET_FROM_BOTTOM

if (inputY < winY || inputY > winY + winH || sendY < winY || sendY > winY + winH)
    Fail "좌표 계산", "입력창/전송 버튼 좌표가 창 범위를 벗어났습니다."

WriteLog "Window: x=" winX ", y=" winY ", w=" winW ", h=" winH
WriteLog "Click input: x=" inputX ", y=" inputY
WriteLog "Click send: x=" sendX ", y=" sendY

if DRY_RUN {
    WriteLog "[OK] Dry run completed without sending"
    ExitApp 0
}

oldClip := ClipboardAll()

try {
    Click inputX, inputY
    Sleep 250
    PasteText MESSAGE
    Sleep 500

    Click sendX, sendY
    Sleep 500

    WriteLog "[OK] Greeting sent"
} catch as err {
    Fail "메시지 전송", err.Message
} finally {
    Sleep 200
    A_Clipboard := oldClip
    Sleep 100
    oldClip := ""
}

ExitApp 0


