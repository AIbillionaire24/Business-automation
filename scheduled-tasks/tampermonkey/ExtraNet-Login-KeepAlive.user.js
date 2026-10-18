// ==UserScript==
// @name         ExtraNet Login KeepAlive
// @namespace    http://tampermonkey.net/
// @version      2.1
// @description  ExtraNet 로그인 세션 자동 연장 (평일 12:50-19:00, 공휴일 제외)
// @match        *://extra.lms.example.com/*
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    const CHECK_INTERVAL_SEC = 30;
    const TRIGGER_MIN        = 10;
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

    function parseExpireTime(text) {
        if (!text) return null;
        const m = text.match(/(\d+)\s*분\s*(\d+)\s*초/);
        if (m) return parseInt(m[1], 10) + parseInt(m[2], 10) / 60;
        const m2 = text.match(/(\d+)\s*분/);
        if (m2) return parseInt(m2[1], 10);
        return null;
    }

    function checkAndExtend() {
        if (!shouldRun("KeepAlive")) return;

        try {
            const iframe = document.getElementById("ContentFrame");
            if (!iframe) return;

            const iDoc = iframe.contentDocument;
            const timeSpan = iDoc.getElementById("expireTime");
            const btn      = iDoc.getElementById("extLogin");

            if (!timeSpan || !btn) return;

            const remaining = parseExpireTime(timeSpan.innerText.trim());
            if (remaining === null) return;

            console.log(`[KeepAlive] 남은 시간: ${timeSpan.innerText.trim()} (${remaining.toFixed(1)}분)`);

            if (remaining <= TRIGGER_MIN) {
                btn.click();
                console.log(`[KeepAlive] 로그인 연장 클릭 (${remaining.toFixed(1)}분 남음):`,
                            new Date().toLocaleTimeString());
            }
        } catch (e) {
            console.error("[KeepAlive] 오류:", e.message);
        }
    }

    function startTimer() {
        if (timerStarted) return;
        timerStarted = true;
        console.log("[KeepAlive] 타이머 시작 (30초마다 체크):", new Date().toLocaleTimeString());

        checkAndExtend();
        setInterval(checkAndExtend, CHECK_INTERVAL_SEC * 1000);
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
        console.log("[KeepAlive] ContentFrame 대기 중...");
    }

})();
