param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TaskName = "PeelWindowsPairedDeviceValidation20260802"
$ResultPath = Join-Path $BundleRoot "native-paired-device-result.txt"
$SmokeScript = Join-Path $BundleRoot "surface-native-paired-device-revocation-smoke.ps1"
$Registered = $false

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    throw "Refusing to replace existing scheduled task $TaskName."
}

Remove-Item $ResultPath -Force -ErrorAction SilentlyContinue

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

    $Deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path $ResultPath) -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 250
    }

    if (-not (Test-Path $ResultPath)) {
        $Info = Get-ScheduledTaskInfo -TaskName $TaskName
        throw "Native paired-device task did not return a result. LastTaskResult=$($Info.LastTaskResult)."
    }

    $Result = Get-Content $ResultPath
    $Result | Write-Output
    if ($Result[0] -ne "NATIVE_PAIRED_DEVICE_TASK_PASSED") {
        throw "Native paired-device revocation smoke reported failure."
    }
}
finally {
    if ($Registered) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}
