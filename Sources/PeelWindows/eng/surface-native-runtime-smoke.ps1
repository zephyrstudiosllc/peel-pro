param(
    [string]$BundleRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ResultPath = Join-Path $BundleRoot "native-runtime-result.txt"
$HostTests = Join-Path $BundleRoot "host-tests\Peel.Windows.Host.Tests.exe"

try {
    $Output = @(& $HostTests --native-runtime-smoke 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "Native runtime smoke exited with code $ExitCode. $($Output -join ' ')"
    }

    $Expected = "PASS native Host runtime: stable identity, exact DNS-SD, rotating PIN, credential reconnect, window list, input default off, clean goodbye"
    if ($Output -notcontains $Expected) {
        throw "Native runtime smoke did not emit its success boundary."
    }

    @(
        "NATIVE_RUNTIME_TASK_PASSED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $Output
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_RUNTIME_TASK_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
