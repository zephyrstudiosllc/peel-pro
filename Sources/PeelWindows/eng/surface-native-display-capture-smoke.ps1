param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Executable = Join-Path $BundleRoot "host-tests\Peel.Windows.Host.Tests.exe"
$ResultPath = Join-Path $BundleRoot "native-display-capture-result.txt"

try {
    $BoundaryOutput = & $Executable 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Host boundary tests exited with code $LASTEXITCODE. $($BoundaryOutput -join ' ')"
    }

    $DisplayOutput = & $Executable --native-display-capture-smoke 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Native display capture smoke exited with code $LASTEXITCODE. $($DisplayOutput -join ' ')"
    }

    @(
        "NATIVE_DISPLAY_CAPTURE_TASK_PASSED"
        $BoundaryOutput
        $DisplayOutput
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_DISPLAY_CAPTURE_TASK_FAILED"
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
