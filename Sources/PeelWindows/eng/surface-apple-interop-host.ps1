param(
    [string]$BundleRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ResultPath = Join-Path $BundleRoot "apple-interop-result.txt"
$StateRoot = Join-Path $BundleRoot "apple-interop-state"
$HostTests = Join-Path $BundleRoot "host-tests\Peel.Windows.Host.Tests.exe"

try {
    $Output = @(& $HostTests --apple-interop-host $StateRoot 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "Apple interoperability Host exited with code $ExitCode. $($Output -join ' ')"
    }

    $Expected = "PASS Apple interoperability Host: production discovery, pairing, credential reconnect, window list, input default off"
    if ($Output -notcontains $Expected) {
        throw "Apple interoperability Host did not emit its success boundary."
    }

    @(
        "APPLE_INTEROP_HOST_PASSED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $Output
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "APPLE_INTEROP_HOST_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
