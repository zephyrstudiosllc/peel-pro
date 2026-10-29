param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TaskName = "PeelWindowsValidation20260801"
$ResultPath = Join-Path $BundleRoot "interactive-result.txt"
$ScreenshotPath = Join-Path $BundleRoot "peel-header.png"
$SmokeScript = Join-Path $BundleRoot "surface-interactive-smoke.ps1"
$Registered = $false

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    throw "Refusing to replace existing scheduled task $TaskName."
}

Remove-Item $ResultPath, $ScreenshotPath -Force -ErrorAction SilentlyContinue

$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$ActionArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SmokeScript`" -BundleRoot `"$BundleRoot`""
$Action = New-ScheduledTaskAction -Execute $PowerShell -Argument $ActionArguments
$Principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited
$Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

try {
    [void](Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Principal $Principal `
        -Settings $Settings)
    $Registered = $true

    Start-ScheduledTask -TaskName $TaskName

    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $ResultPath) -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 250
    }

    if (-not (Test-Path $ResultPath)) {
        $Info = Get-ScheduledTaskInfo -TaskName $TaskName
        throw "Interactive task did not return a result. LastTaskResult=$($Info.LastTaskResult)."
    }

    $Result = Get-Content $ResultPath
    $Result | Write-Output
    if ($Result[0] -ne "INTERACTIVE_SMOKE_PASSED") {
        throw "Interactive smoke reported failure."
    }
}
finally {
    if ($Registered) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}
