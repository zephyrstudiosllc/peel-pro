param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
$Executable = Join-Path $BundleRoot "host-tests-wgc\Peel.Windows.Host.Tests.exe"
$ResultPath = Join-Path $BundleRoot "native-capture-result.txt"

try {
    $Output = & $Executable --native-capture-smoke 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Native capture smoke exited with code $LASTEXITCODE. $($Output -join ' ')"
    }

    @(
        "NATIVE_CAPTURE_TASK_PASSED"
        $Output
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_CAPTURE_TASK_FAILED"
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
