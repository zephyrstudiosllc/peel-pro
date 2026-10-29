#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

dotnet build "$repository_root/src/Peel.Windows.Protocol/Peel.Windows.Protocol.csproj" \
  --configuration Debug
dotnet run \
  --project "$repository_root/tests/Peel.Windows.Protocol.Tests/Peel.Windows.Protocol.Tests.csproj" \
  --configuration Debug
dotnet build \
  "$repository_root/tests/Peel.Windows.Client.Tests/Peel.Windows.Client.Tests.csproj" \
  --configuration Debug
dotnet exec \
  --runtimeconfig "$repository_root/tests/Peel.Windows.Protocol.Tests/bin/Debug/net10.0/Peel.Windows.Protocol.Tests.runtimeconfig.json" \
  "$repository_root/tests/Peel.Windows.Client.Tests/bin/Debug/net10.0-windows10.0.19041.0/Peel.Windows.Client.Tests.dll"
dotnet run \
  --project "$repository_root/tests/Peel.Windows.Transport.Tests/Peel.Windows.Transport.Tests.csproj" \
  --configuration Debug
git -C "$repository_root" diff --check
