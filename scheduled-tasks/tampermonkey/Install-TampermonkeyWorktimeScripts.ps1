$OpenOnly = $false
$AutoStopSeconds = 900

foreach ($Arg in $args) {
    if ($Arg -eq "-OpenOnly") {
        $OpenOnly = $true
    }
    elseif ($Arg -like "-AutoStopSeconds=*") {
        $AutoStopSeconds = [int]($Arg -replace "^-AutoStopSeconds=", "")
    }
}

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), 0)
$Listener.Start()
$Port = $Listener.LocalEndpoint.Port
$Listener.Stop()

$ChromeCandidates = @(
    (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
    "chrome.exe"
)

$Chrome = $ChromeCandidates | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $Chrome) {
    throw "chrome command not found. Open the printed .user.js URLs manually in Chrome."
}

$Python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $Python) {
    throw "python command not found. Install Python or open the .user.js files from another local web server."
}

$Server = Start-Process `
    -FilePath $Python.Source `
    -ArgumentList @("-m", "http.server", "$Port", "--bind", "127.0.0.1") `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -PassThru

$KeepServer = $false
try {
    Start-Sleep -Seconds 1
    Start-Process -FilePath $Chrome -ArgumentList "http://127.0.0.1:$Port/ExtraNet-Login-KeepAlive.user.js"
    Start-Sleep -Seconds 1
    Start-Process -FilePath $Chrome -ArgumentList "http://127.0.0.1:$Port/ExtraNet-BoardAlert.user.js"

    Write-Host ""
    Write-Host "Chrome에 Tampermonkey 업데이트 화면 2개를 열었습니다."
    if ($OpenOnly) {
        $KeepServer = $true
        $StopCommand = "Start-Sleep -Seconds $AutoStopSeconds; Stop-Process -Id $($Server.Id) -Force -ErrorAction SilentlyContinue"
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $StopCommand) -WindowStyle Hidden | Out-Null
        Write-Host "임시 서버는 $AutoStopSeconds 초 뒤 자동 종료됩니다."
    }
    else {
        Write-Host "각 화면에서 Update/Install 버튼을 누른 뒤 Enter를 누르면 임시 서버를 종료합니다."
        Read-Host "완료 후 Enter"
    }
}
finally {
    if (-not $KeepServer -and $Server -and -not $Server.HasExited) {
        Stop-Process -Id $Server.Id -Force
    }
}
