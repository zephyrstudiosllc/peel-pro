param(
    [Parameter(Mandatory)]
    [ValidateSet("Start", "Stop")]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$TaskName = "PeelWindowsAppleInteropValidation20260802"
$ResultPath = Join-Path $BundleRoot "apple-interop-result.txt"
$StateRoot = Join-Path $BundleRoot "apple-interop-state"
$ReadyPath = Join-Path $StateRoot "ready.txt"
$StopPath = Join-Path $StateRoot "stop.txt"
$SmokeScript = Join-Path $BundleRoot "surface-apple-interop-host.ps1"

if ($Action -eq "Start") {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        throw "Refusing to replace existing scheduled task $TaskName."
    }

    Remove-Item $ResultPath -Force -ErrorAction SilentlyContinue
    Remove-Item $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $StateRoot)

    $PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $ActionArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SmokeScript`" -BundleRoot `"$BundleRoot`""
    $TaskAction = New-ScheduledTaskAction -Execute $PowerShell -Argument $ActionArguments
    $Principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited
    $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 6)
    $Registered = $false

    try {
        [void](Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $TaskAction `
            -Principal $Principal `
            -Settings $Settings)
        $Registered = $true
        Start-ScheduledTask -TaskName $TaskName

        $Deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path $ReadyPath) -and
               -not (Test-Path $ResultPath) -and
               [DateTime]::UtcNow -lt $Deadline) {
            Start-Sleep -Milliseconds 250
        }

        if (Test-Path $ResultPath) {
            throw "Apple interoperability Host stopped early. $((Get-Content $ResultPath) -join ' ')"
        }
        if (-not (Test-Path $ReadyPath)) {
            $Info = Get-ScheduledTaskInfo -TaskName $TaskName
            throw "Apple interoperability Host did not become ready. LastTaskResult=$($Info.LastTaskResult)."
        }

        "APPLE_INTEROP_HOST_READY"
        $Registered = $false
    }
    finally {
        if ($Registered) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
    }
    exit 0
}

if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
    throw "Apple interoperability task $TaskName is not registered."
}

try {
    "stop" | Set-Content -Path $StopPath -Encoding ASCII
    $Deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $ResultPath) -and [DateTime]::UtcNow -lt $Deadline) {
        Start-Sleep -Milliseconds 250
    }

    if (-not (Test-Path $ResultPath)) {
        $Info = Get-ScheduledTaskInfo -TaskName $TaskName
        throw "Apple interoperability Host did not stop cleanly. LastTaskResult=$($Info.LastTaskResult)."
    }

    $Result = Get-Content $ResultPath
    $Result | Write-Output
    if ($Result[0] -ne "APPLE_INTEROP_HOST_PASSED") {
        throw "Apple interoperability Host reported failure."
    }
}
finally {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Remove-Item $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
