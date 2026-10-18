$ErrorActionPreference = "Continue"

$ldConsolePath = "C:\LDPlayer\LDPlayer9\ldconsole.exe"
$instanceIndex = 0
$packageName = "kr.co.hiworks.messenger"
$holidayFile = "C:\Scripts\hiworks_holidays.txt"
$logDir = Join-Path $env:LOCALAPPDATA "CodexAutomation"
$logFile = Join-Path $logDir "launch_ldplayer_hiworks.log"

if (!(Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

function Get-HolidayReason {
    param([datetime]$Date)

    if (!(Test-Path -LiteralPath $holidayFile)) {
        return $null
    }

    $dateText = $Date.ToString("yyyy-MM-dd")
    foreach ($line in Get-Content -LiteralPath $holidayFile -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match '^(?<date>\d{4}-\d{2}-\d{2})(?:\s+(?<reason>.*))?$') {
            if ($Matches.date -eq $dateText) {
                if ([string]::IsNullOrWhiteSpace($Matches.reason)) {
                    return "configured holiday"
                }
                return $Matches.reason
            }
        }
    }

    return $null
}

function Invoke-LdConsole {
    param([string[]]$Arguments)

    $output = & $ldConsolePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in @($output)) {
        if ($null -ne $line -and $line.ToString().Length -gt 0) {
            Write-Log "[ldconsole] $line"
        }
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Test-LdPlayerRunning {
    $status = Invoke-LdConsole -Arguments @("isrunning", "--index", "$instanceIndex")
    $statusText = ($status.Output -join "`n")
    return ($statusText -match "\brunning\b")
}

function Wait-LdPlayerRunning {
    param([int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-LdPlayerRunning) {
            Write-Log "[OK] LDPlayer instance $instanceIndex is running"
            return $true
        }

        Write-Log "Waiting for LDPlayer instance $instanceIndex to start..."
        Start-Sleep -Seconds 10
    }

    return $false
}

function Test-PackageInstalled {
    $ldPlayerDir = Split-Path -Parent $ldConsolePath
    $metadataFiles = @(
        (Join-Path $ldPlayerDir "appNames.text"),
        (Join-Path $ldPlayerDir "vms\leidian$instanceIndex\appsinfo.data")
    )

    foreach ($metadataFile in $metadataFiles) {
        if (!(Test-Path -LiteralPath $metadataFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $metadataFile -Raw -ErrorAction SilentlyContinue
        if ($content -match [regex]::Escape($packageName)) {
            Write-Log "[OK] Package is installed: $packageName"
            return $true
        }
    }

    return $false
}

function Test-ActivePackageUpdated {
    param([datetime]$Since)

    $ldPlayerDir = Split-Path -Parent $ldConsolePath
    $activeFile = Join-Path $ldPlayerDir "vms\leidian$instanceIndex\appsactive.data"
    if (!(Test-Path -LiteralPath $activeFile)) {
        Write-Log "[WARN] Active app metadata not found: $activeFile"
        return $false
    }

    $activeInfo = Get-Item -LiteralPath $activeFile
    $content = Get-Content -LiteralPath $activeFile -Raw -ErrorAction SilentlyContinue
    if ($content -match [regex]::Escape($packageName)) {
        if ($activeInfo.LastWriteTime -ge $Since.AddSeconds(-2)) {
            Write-Log "[OK] LDPlayer active app metadata updated for: $packageName"
        }
        else {
            Write-Log "[OK] LDPlayer active app metadata already shows: $packageName"
        }
        return $true
    }

    Write-Log "[WARN] Active app metadata does not show package yet"
    return $false
}

$now = Get-Date
$weekday = @("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
if ($weekday -notcontains $now.DayOfWeek.ToString()) {
    Write-Log "[SKIP] Today is not a weekday: $($now.DayOfWeek)"
    exit 0
}

$holidayReason = Get-HolidayReason -Date $now.Date
if ($holidayReason) {
    Write-Log "[SKIP] Today is configured holiday: $($now.ToString('yyyy-MM-dd')) $holidayReason"
    exit 0
}

Write-Log "=============================================="
Write-Log "LDPlayer Hiworks launch started"
Write-Log "=============================================="

if (!(Test-Path -LiteralPath $ldConsolePath)) {
    Write-Log "[ERROR] ldconsole.exe not found: $ldConsolePath"
    exit 1
}

if (!(Test-LdPlayerRunning)) {
    Write-Log "[WARN] LDPlayer is not running; launching instance $instanceIndex"
    Invoke-LdConsole -Arguments @("launch", "--index", "$instanceIndex") | Out-Null
    if (!(Wait-LdPlayerRunning -TimeoutSeconds 180)) {
        Write-Log "[ERROR] LDPlayer instance $instanceIndex did not report running after launch"
        exit 1
    }
}
else {
    Write-Log "[OK] LDPlayer instance $instanceIndex is running"
}

if (!(Test-PackageInstalled)) {
    Write-Log "[ERROR] Package is not listed as installed in LDPlayer: $packageName"
    exit 1
}

for ($attempt = 1; $attempt -le 12; $attempt++) {
    Write-Log "Trying to run Hiworks app inside LDPlayer. Attempt $attempt"
    $launchStarted = Get-Date
    $result = Invoke-LdConsole -Arguments @("runapp", "--index", "$instanceIndex", "--packagename", $packageName)
    if ($result.ExitCode -eq 0) {
        Start-Sleep -Seconds 5
        if (Test-ActivePackageUpdated -Since $launchStarted) {
            Write-Log "[OK] Hiworks app launch confirmed: $packageName"
            exit 0
        }

        Write-Log "[WARN] Hiworks app launch command was sent but not confirmed yet"
    }
    else {
        Write-Log "[WARN] Hiworks app launch command failed with exit code $($result.ExitCode)"
    }

    Start-Sleep -Seconds 10
}

Write-Log "[WARN] Falling back to launchex for package: $packageName"
$fallbackStarted = Get-Date
$fallback = Invoke-LdConsole -Arguments @("launchex", "--index", "$instanceIndex", "--packagename", $packageName)
if ($fallback.ExitCode -eq 0) {
    Start-Sleep -Seconds 5
    if (Test-ActivePackageUpdated -Since $fallbackStarted) {
        Write-Log "[OK] Hiworks app launch fallback confirmed"
        exit 0
    }
}

Write-Log "[ERROR] Failed to launch Hiworks app inside LDPlayer"
exit 1
