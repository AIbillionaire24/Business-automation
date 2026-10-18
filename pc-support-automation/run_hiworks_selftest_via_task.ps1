param(
    [switch]$DryRun,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$logDir = "C:\Scripts\logs"
$markerPath = "C:\Scripts\hiworks_marker_request.json"
$senderPath = "C:\Scripts\send_hiworks_self_greeting.ps1"
$taskName = "Launch Apps 1250"

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

if (!(Test-Path -LiteralPath $senderPath)) {
    throw "Sender script not found: $senderPath"
}

if (Test-Path -LiteralPath $markerPath) {
    throw "Marker request already exists. Wait for the previous marker run or inspect: $markerPath"
}

$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$label = "selftest_task_$runId"
$resultPath = Join-Path $logDir "hiworks_marker_result_$runId.json"

$arguments = @(
    "-MessageLabel",
    $label,
    "-TargetChatTitle",
    "나와의 채팅방",
    "-TargetSearchQuery",
    "유아 하이웍스CS",
    "-TargetSearchResult",
    "유아 하이웍스CS",
    "-SendMessage",
    "자동화 테스트입니다."
)

if ($DryRun) {
    $arguments += "-DryRun"
}

$request = [PSCustomObject]@{
    RunId = $runId
    Type = "HiworksSelfTest"
    CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Script = $senderPath
    Arguments = $arguments
    ResultPath = $resultPath
}

$request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8
Write-Output "Marker request written: $markerPath"
Write-Output "Result path: $resultPath"

Start-ScheduledTask -TaskName $taskName
Write-Output "Scheduled task started: $taskName"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $resultPath) {
        $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Output "Marker result:"
        $result | Format-List | Out-String | Write-Output

        $messageLog = Join-Path $logDir ("hiworks_{0}_message_uia.log" -f $label)
        if (Test-Path -LiteralPath $messageLog) {
            Write-Output "Recent message log:"
            Get-Content -LiteralPath $messageLog -Tail 80 | Write-Output
        }

        $screenshots = Get-ChildItem -LiteralPath $logDir -Filter ("hiworks_{0}_*.png" -f $label) -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime
        if ($screenshots) {
            Write-Output "Screenshots:"
            $screenshots | Select-Object FullName, LastWriteTime | Format-Table -AutoSize | Out-String | Write-Output
        }

        exit ([int]$result.ExitCode)
    }

    Start-Sleep -Seconds 2
}

throw "Timed out waiting for marker result: $resultPath"
