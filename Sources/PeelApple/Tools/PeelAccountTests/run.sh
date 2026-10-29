#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
repo_dir=${script_dir:h:h}
test_dir=$(mktemp -d /tmp/peel-account-checks.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_dir"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor \
    Shared/Account/PeelAccountModels.swift Shared/Account/PeelAccountService.swift \
    Shared/Account/PeelCompanyAccountModels.swift Shared/Account/PeelCompanyAccountHTTP.swift Shared/Account/PeelCompanyAccountService.swift \
    Tools/PeelAccountTests/Checks.swift -o "$test_dir/account-checks"
"$test_dir/account-checks"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor \
    Shared/Account/PeelAccountModels.swift Shared/Account/PeelAccountService.swift \
    Shared/Account/PeelCompanyAccountModels.swift Shared/Account/PeelCompanyAccountHTTP.swift Shared/Account/PeelCompanyAccountService.swift \
    Tools/PeelAccountTests/CompanyChecks.swift -o "$test_dir/company-checks"
"$test_dir/company-checks"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -default-isolation MainActor \
    Shared/Account/PeelCompanyAccountModels.swift Shared/Account/PeelCompanyAccountHTTP.swift \
    Tools/PeelAccountTests/HTTPWorkerChecks.swift -o "$test_dir/http-checks"
"$test_dir/http-checks"
if [[ -d ../../Integration/Account ]]; then
    for name in PeelAccountModels.swift PeelAccountService.swift PeelAccountView.swift PeelAccountClientLifecycle.swift PeelCompanyAccountModels.swift PeelCompanyAccountHTTP.swift PeelCompanyAccountService.swift PeelCompanyAccountView.swift; do
        cmp "Shared/Account/$name" "../../Integration/Account/$name"
    done
fi
