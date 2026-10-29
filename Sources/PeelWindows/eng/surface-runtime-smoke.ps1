param(
    [string]$BundleRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Install-StableWpfRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $RuntimeRoot = Join-Path $env:LOCALAPPDATA "Programs\Peel Development"
    $Executable = Join-Path $RuntimeRoot "Peel.Windows.exe"
    $RunningRuntime = @(
        Get-Process -Name "Peel.Windows" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $Executable })
    if ($RunningRuntime.Count -ne 0) {
        throw "Refusing to replace the stable Surface validation runtime while it is running."
    }

    Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $RuntimeRoot) -Force)
    Copy-Item -LiteralPath $SourceRoot -Destination $RuntimeRoot -Recurse
    return $Executable
}

function Invoke-CheckedExecutable {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string[]]$Arguments = @()
    )

    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Path exited with code $LASTEXITCODE."
    }
}

$ClientTests = Join-Path $BundleRoot "client-tests\Peel.Windows.Client.Tests.exe"
$ProtocolTests = Join-Path $BundleRoot "protocol-tests\Peel.Windows.Protocol.Tests.exe"
$HostTests = Join-Path $BundleRoot "host-tests\Peel.Windows.Host.Tests.exe"
$DiscoveryTests = Join-Path $BundleRoot "discovery-tests\Peel.Windows.Discovery.Tests.exe"
$TransportTests = Join-Path $BundleRoot "transport-tests\Peel.Windows.Transport.Tests.exe"
$HostExecutable = Join-Path $BundleRoot "host\Peel.Windows.Host.exe"
$Client = Install-StableWpfRuntime -SourceRoot (Join-Path $BundleRoot "client")

Write-Output "Peel Windows Surface runtime smoke"
Get-Item $ClientTests, $ProtocolTests, $HostTests, $DiscoveryTests, $TransportTests, $HostExecutable, $Client |
    Select-Object Name, Length |
    Format-Table -AutoSize

Invoke-CheckedExecutable -Path $ClientTests
Invoke-CheckedExecutable -Path $ProtocolTests
Invoke-CheckedExecutable -Path $HostTests
Invoke-CheckedExecutable -Path $DiscoveryTests
Invoke-CheckedExecutable -Path $TransportTests

$HostOutput = & $HostExecutable --dry-run
if ($LASTEXITCODE -ne 0) {
    throw "Host dry run exited with code $LASTEXITCODE."
}

$InputLine = $HostOutput | Where-Object { $_ -like "Input injection:*" } | Select-Object -First 1
$WindowLine = $HostOutput | Where-Object { $_ -like "User windows:*" } | Select-Object -First 1
if ($InputLine -ne "Input injection: disabled") {
    throw "Host did not report its input gate as disabled."
}
if ($WindowLine -notmatch "^User windows: [0-9]+$") {
    throw "Host did not return a valid user-window count."
}
Write-Output $InputLine
Write-Output $WindowLine
if ($WindowLine -eq "User windows: 0") {
    Write-Output "OpenSSH session has no interactive desktop; user-session enumeration remains pending."
}
Write-Output "Window titles redacted by smoke script."

$ClientProcess = Start-Process -FilePath $Client -PassThru
try {
    Start-Sleep -Seconds 5
    $ClientProcess.Refresh()
    if ($ClientProcess.HasExited) {
        throw "Client exited during its five-second WPF launch smoke."
    }
    Write-Output "Unified Peel WPF process remained alive for five seconds."
}
finally {
    $ClientProcess.Refresh()
    if (-not $ClientProcess.HasExited) {
        Stop-Process -Id $ClientProcess.Id -Force
        [void]$ClientProcess.WaitForExit(5000)
    }
}

Write-Output "SURFACE_RUNTIME_SMOKE_PASSED"
