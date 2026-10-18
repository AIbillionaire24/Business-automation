// ==UserScript==
// @name         ExtraNet 교사 원격지원요청 새 글 알림
// @namespace    http://tampermonkey.net/
// @version      1.3
// @description  교사 원격지원요청 게시판 새 글 감지 (평일 12:50-19:00, 공휴일 제외)
// @match        *://extra.lms.example.com/*
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    const CHECK_INTERVAL_SEC = 30;
    const STORAGE_KEY        = "boardalert_last_board_id";
    const LEGACY_STORAGE_KEY = "keepalive_last_board_id";
    const BASELINE_DATE_KEY  = "boardalert_last_baseline_date";
    const SOUND_URL          = "https://actions.google.com/sounds/v1/cartoon/clang_and_wobble.ogg";
    const SOUND_REPEAT       = 3;
    const SOUND_INTERVAL_MS  = 5000;
    const WORK_START_MIN     = 12 * 60 + 50;
    const WORK_END_MIN       = 19 * 60;

    const KOREA_PUBLIC_HOLIDAYS = new Set([
        "2026-01-01",
        "2026-02-16", "2026-02-17", "2026-02-18",
        "2026-03-01", "2026-03-02",
        "2026-05-05", "2026-05-24", "2026-05-25",
        "2026-06-03", "2026-06-06",
        "2026-07-17",
        "2026-08-15", "2026-08-17",
        "2026-09-24", "2026-09-25", "2026-09-26",
        "2026-10-03", "2026-10-05", "2026-10-09",
        "2026-12-25"
    ]);

    let lastTopId = localStorage.getItem(STORAGE_KEY) ||
                    localStorage.getItem(LEGACY_STORAGE_KEY) ||
                    null;
    let timerStarted = false;
    let lastGateLogKey = "";

    function toYmd(date) {
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, "0");
        const d = String(date.getDate()).padStart(2, "0");
        return `${y}-${m}-${d}`;
    }

    function isWorkTime(now = new Date()) {
        const day = now.getDay();
        if (day === 0 || day === 6) return false;
        if (KOREA_PUBLIC_HOLIDAYS.has(toYmd(now))) return false;

        const minutes = now.getHours() * 60 + now.getMinutes();
        return minutes >= WORK_START_MIN && minutes < WORK_END_MIN;
    }

    function shouldRun(scope) {
        if (isWorkTime()) return true;

        const now = new Date();
        const logKey = `${toYmd(now)} ${now.getHours()}`;
        if (lastGateLogKey !== logKey) {
            lastGateLogKey = logKey;
            console.log(`[${scope}] 업무시간 외라 중지:`, now.toLocaleString());
        }
        return false;
    }

    function getBoardId(link, baseUrl) {
        try {
            const href = link.getAttribute("href") || link.href;
            const url = new URL(href, baseUrl);
            return url.searchParams.get("BoardId") || url.href;
        } catch (e) {
            return link.href || link.innerText.trim();
        }
    }

    function playSound(count) {
        if (count <= 0) return;

        try {
            const audio = new Audio(SOUND_URL);
            audio.volume = 1.0;
            const playResult = audio.play();
            if (playResult && typeof playResult.catch === "function") {
                playResult.catch(e => console.warn("[BoardAlert] 알림음 재생 실패:", e.message));
            }
            console.log(`[BoardAlert] 알림음 재생 (${SOUND_REPEAT - count + 1}/${SOUND_REPEAT}회)`);
            setTimeout(() => playSound(count - 1), SOUND_INTERVAL_MS);
        } catch (e) {
            console.warn("[BoardAlert] 알림음 재생 실패:", e.message);
        }
    }

    function ensureNotificationPermission() {
        if (Notification.permission === "default") {
            Notification.requestPermission();
        }
    }

    function showNotification(title, body) {
        if (Notification.permission === "granted") {
            new Notification(title, { body, icon: "https://extra.lms.example.com/favicon.ico" });
        } else if (Notification.permission !== "denied") {
            Notification.requestPermission().then(p => {
                if (p === "granted") new Notification(title, { body });
            });
        }
    }

    function checkBoard() {
        if (!shouldRun("BoardAlert")) return;

        try {
            const iframe = document.getElementById("ContentFrame");
            if (!iframe) return;

            const iDoc = iframe.contentDocument;
            const iUrl = iframe.contentWindow.location.href;

            if (!iUrl.includes("MenuId=10002")) return;

            const rows = iDoc.querySelectorAll("table#dataTable tbody tr[data-top='0']");
            if (!rows.length) return;

            const firstRow = rows[0];
            const link = firstRow.querySelector("a[href*='BoardId=']");
            if (!link) return;

            const currentId = getBoardId(link, iUrl);
            const title = link.innerText.trim();
            const today = toYmd(new Date());
            const lastBaselineDate = localStorage.getItem(BASELINE_DATE_KEY);

            if (lastBaselineDate !== today) {
                lastTopId = currentId;
                localStorage.setItem(STORAGE_KEY, currentId);
                localStorage.setItem(BASELINE_DATE_KEY, today);
                ensureNotificationPermission();
                console.log("[BoardAlert] 업무 시작 기준 글 저장:", currentId, title);
                return;
            }

            if (lastTopId === null) {
                lastTopId = currentId;
                localStorage.setItem(STORAGE_KEY, currentId);
                console.log("[BoardAlert] 기준 글 저장:", currentId, title);
                return;
            }

            if (currentId !== lastTopId) {
                lastTopId = currentId;
                localStorage.setItem(STORAGE_KEY, currentId);

                console.log("[BoardAlert] 새 글 감지:", currentId, title);
                playSound(SOUND_REPEAT);
                showNotification("교사 원격지원요청 새 글", title);
            }
        } catch (e) {
            console.error("[BoardAlert] 오류:", e.message);
        }
    }

    function startTimer() {
        if (timerStarted) return;
        timerStarted = true;
        console.log("[BoardAlert] 타이머 시작 (30초마다 체크):", new Date().toLocaleTimeString());

        checkBoard();
        setInterval(checkBoard, CHECK_INTERVAL_SEC * 1000);

        document.addEventListener("visibilitychange", () => {
            if (document.visibilityState === "visible") checkBoard();
        });
    }

    if (document.getElementById("ContentFrame")) {
        setTimeout(startTimer, 1000);
    } else {
        const observer = new MutationObserver(() => {
            if (document.getElementById("ContentFrame")) {
                observer.disconnect();
                setTimeout(startTimer, 1000);
            }
        });
        observer.observe(document.body, { childList: true, subtree: true });
        console.log("[BoardAlert] ContentFrame 대기 중...");
    }

})();
