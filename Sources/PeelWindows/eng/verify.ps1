$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$Solution = Join-Path $RepositoryRoot "Peel.Windows.slnx"
$ClientTests = Join-Path $RepositoryRoot "tests/Peel.Windows.Client.Tests/Peel.Windows.Client.Tests.csproj"
$ProtocolTests = Join-Path $RepositoryRoot "tests/Peel.Windows.Protocol.Tests/Peel.Windows.Protocol.Tests.csproj"
$HostTests = Join-Path $RepositoryRoot "tests/Peel.Windows.Host.Tests/Peel.Windows.Host.Tests.csproj"
$DiscoveryTests = Join-Path $RepositoryRoot "tests/Peel.Windows.Discovery.Tests/Peel.Windows.Discovery.Tests.csproj"
$TransportTests = Join-Path $RepositoryRoot "tests/Peel.Windows.Transport.Tests/Peel.Windows.Transport.Tests.csproj"

Push-Location $RepositoryRoot
try {
    dotnet --info
    dotnet restore $Solution
    dotnet build $Solution --configuration Debug --no-restore
    dotnet run --project $ClientTests --configuration Debug --no-build
    dotnet run --project $ProtocolTests --configuration Debug --no-build
    dotnet run --project $HostTests --configuration Debug --no-build
    dotnet run --project $DiscoveryTests --configuration Debug --no-build
    dotnet run --project $TransportTests --configuration Debug --no-build
    git diff --check
}
finally {
    Pop-Location
}
