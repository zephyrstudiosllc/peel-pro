param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ResultPath = Join-Path $BundleRoot "native-paired-device-result.txt"
$ClientTests = Join-Path $BundleRoot "client-tests-paired\Peel.Windows.Client.Tests.exe"

try {
    $Output = @(& $ClientTests --native-host-paired-device-revocation-smoke 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "Native paired-device revocation smoke exited with code $ExitCode. $($Output -join ' ')"
    }

    $Expected = "PASS native Host paired-device revocation: active peer disconnected, credential removed, listeners restarted, input stayed off"
    if ($Output -notcontains $Expected) {
        throw "Native paired-device revocation smoke did not emit its success boundary."
    }

    @(
        "NATIVE_PAIRED_DEVICE_TASK_PASSED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $Output
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_PAIRED_DEVICE_TASK_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
