param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = "Stop"
$Executable = Join-Path $BundleRoot "host-tests-encode\Peel.Windows.Host.Tests.exe"
$ResultPath = Join-Path $BundleRoot "native-encode-result.txt"

try {
    $EncodeOutput = & $Executable --native-encode-smoke 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Native H.264 smoke exited with code $LASTEXITCODE. $($EncodeOutput -join ' ')"
    }

    $StreamOutput = & $Executable --native-stream-smoke 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Native Host video smoke exited with code $LASTEXITCODE. $($StreamOutput -join ' ')"
    }

    $ResizeOutput = & $Executable --native-resize-stream-smoke 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Native Host resize smoke exited with code $LASTEXITCODE. $($ResizeOutput -join ' ')"
    }

    @(
        "NATIVE_ENCODE_TASK_PASSED"
        $EncodeOutput
        $StreamOutput
        $ResizeOutput
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "NATIVE_ENCODE_TASK_FAILED"
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
