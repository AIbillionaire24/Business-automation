<#
====================================================================
 하이웍스 출근/퇴근 메시지 선택기

   -Type start|end     어느 인사말인지
   -WriteTo <경로>     고른 문구를 그 파일에 쓴다 (UTF-8)
   -ToClipboard        클립보드에도 넣는다

 - 요일에 맞는 문구 풀에서 하나를 고른다
 - 직전에 쓴 문구는 다시 고르지 않는다 (last-message.json)
 - 실패해도 호출한 쪽을 막지 않는다 (기본 문구로 폴백)
====================================================================
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('start','end')][string]$Type,
    [string]$WriteTo = '',
    [switch]$ToClipboard
)

$statePath = Join-Path $PSScriptRoot 'last-message.json'
$dow = (Get-Date).DayOfWeek

$fallback = if ($Type -eq 'start') { "안녕하세요~`n업무 시작합니다!^^" }
            else                   { "업무 종료하겠습니다.`n감사합니다!^^" }

try {
    $pool = if ($Type -eq 'start') {
        $b = @(
            "안녕하세요~`n업무 시작합니다!^^"
            "안녕하세요~`n업무 시작하겠습니다^^"
            "안녕하세요!`n오늘 업무 시작합니다~"
            "안녕하세요~`n금일 업무 시작합니다.^^"
        )
        $b
    } else {
        $b = @(
            "업무 종료하겠습니다.`n감사합니다!^^"
            "오늘 업무 마무리하겠습니다.`n감사합니다~"
            "업무 종료합니다.`n수고 많으셨습니다!^^"
            "금일 업무 종료하겠습니다.`n감사합니다."
        )
        if ($dow -eq [DayOfWeek]::Friday) { $b += "한 주 수고 많으셨습니다.`n업무 종료하겠습니다!^^" }
        $b
    }

    # 직전 문구 제외 (연속 중복 방지)
    $last = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $last = (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).$Type } catch { }
    }
    $cand = @($pool | Where-Object { $_ -ne $last })
    if ($cand.Count -eq 0) { $cand = @($pool) }
    $pick = $cand | Get-Random

    $state = @{}
    if (Test-Path -LiteralPath $statePath) {
        try {
            $o = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    $state[$Type] = $pick
    try { ($state | ConvertTo-Json) | Set-Content -LiteralPath $statePath -Encoding UTF8 } catch { }
}
catch {
    $pick = $fallback
}

if (-not $pick) { $pick = $fallback }

if ($WriteTo) {
    # 쓰기에 실패하면 같은 경로에 다시 쓰지 않는다. 어차피 또 실패한다.
    # 기존 파일이 그대로 남으므로 부르는 쪽이 그 내용으로 발송하면 된다.
    # (인사말이 안 나가는 것보다 어제 문구가 나가는 편이 낫다)
    try {
        Set-Content -LiteralPath $WriteTo -Value $pick -Encoding UTF8 -NoNewline
    } catch {
        Write-Warning "메시지 파일 쓰기 실패, 기존 파일 유지: $($_.Exception.Message)"
    }
}
if ($ToClipboard) { try { Set-Clipboard -Value $pick } catch { } }
Write-Output $pick
