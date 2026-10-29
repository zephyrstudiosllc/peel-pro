param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ResultPath = Join-Path $BundleRoot "native-network-recovery-result.txt"
$ClientTests = Join-Path $BundleRoot "client-tests-network\Peel.Windows.Client.Tests.exe"

try {
    $Output = @(& $ClientTests --native-host-network-restart-smoke 2>&1)
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "Native Host network recovery smoke exited with code $ExitCode. $($Output -join ' ')"
    }

    $Expected = "PASS native Host network recovery: listeners restarted, discovery re-registered, input stayed off"
    if ($Output -notcontains $Expected) {
        throw "Native Host network recovery smoke did not emit its success boundary."
    }

    @(
        "NATIVE_NETWORK_RECOVERY_TASK_PASSED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $Output
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_NETWORK_RECOVERY_TASK_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
