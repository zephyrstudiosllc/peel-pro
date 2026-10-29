param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
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

$ResultPath = Join-Path $BundleRoot "paired-device-ui-result.txt"
$StatePath = Join-Path $BundleRoot "paired-device-ui-state.txt"
$ClientExecutable = Install-StableWpfRuntime -SourceRoot (Join-Path $BundleRoot "client")
$ClientTests = Join-Path $BundleRoot "client-tests-paired\Peel.Windows.Client.Tests.exe"
$ClientProcess = $null
$UiDiagnostic = @()

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-AutomationElementById {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$AutomationId
    )

    $Root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $Condition)
}

function Invoke-AutomationButtonById {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$AutomationId
    )

    $Element = Get-AutomationElementById -Window $Window -AutomationId $AutomationId
    if ($null -eq $Element) {
        throw "UI Automation button '$AutomationId' was not found."
    }

    $Invoke = [System.Windows.Automation.InvokePattern]$Element.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
    $Invoke.Invoke()
    Start-Sleep -Milliseconds 150
}

function Get-AutomationElementByName {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Automation.AutomationElement]$Root,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $Condition)
}

function Wait-AutomationElementByName {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Automation.AutomationElement]$Root,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 20
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Element = Get-AutomationElementByName -Root $Root -Name $Name
        if ($null -ne $Element) {
            return $Element
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "UI Automation element '$Name' did not appear within $TimeoutSeconds seconds."
}

function Wait-AutomationElementAbsent {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Automation.AutomationElement]$Root,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 20
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ($null -eq (Get-AutomationElementByName -Root $Root -Name $Name)) {
            return
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "UI Automation element '$Name' remained after paired-device revocation."
}

function Wait-PeelListeners {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessIdentifier,

        [int]$TimeoutSeconds = 20
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Count = @(Get-NetTCPConnection `
            -State Listen `
            -OwningProcess $ProcessIdentifier `
            -ErrorAction SilentlyContinue).Count
        if ($Count -ge 2) {
            return $Count
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "Peel did not restore both secure listeners after paired-device revocation."
}

try {
    $CleanupOutput = @(
        & $ClientTests --native-host-paired-device-validation-cleanup 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        -not ($CleanupOutput -match
            "^PASS native paired-device validation cleanup: removed=[0-9]+$")) {
        throw "Paired-device validation cleanup failed. $($CleanupOutput -join ' ')"
    }

    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    $SeedOutput = @(& $ClientTests --native-host-paired-device-ui-seed $StatePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or $SeedOutput -notcontains "PASS native paired-device UI seed") {
        throw "Paired-device UI seed failed. $($SeedOutput -join ' ')"
    }

    $ClientProcess = Start-Process -FilePath $ClientExecutable -PassThru
    $Deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $ClientProcess.Refresh()
    } while (-not $ClientProcess.HasExited -and
             $ClientProcess.MainWindowHandle -eq [IntPtr]::Zero -and
             [DateTime]::UtcNow -lt $Deadline)
    if ($ClientProcess.HasExited -or $ClientProcess.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "Peel did not create its WPF window for paired-device validation."
    }

    $Root = [System.Windows.Automation.AutomationElement]::FromHandle(
        $ClientProcess.MainWindowHandle)
    [void](Wait-AutomationElementByName -Root $Root -Name "Available")
    Invoke-AutomationButtonById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostDevicesDisclosure"
    [void](Wait-AutomationElementByName `
        -Root $Root `
        -Name "Peel validation device")
    $PairedList = Get-AutomationElementById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostPairedDevices"
    if ($null -eq $PairedList) {
        throw "Peel did not expose its paired-device list."
    }
    $PairedDevice = $null
    $ListItemCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $ListItems = $PairedList.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $ListItemCondition)
    foreach ($ListItem in $ListItems) {
        $NamedChild = Get-AutomationElementByName `
            -Root $ListItem `
            -Name "Peel validation device"
        if ($ListItem.Current.Name -like "Peel validation device*" -or
            $null -ne $NamedChild) {
            $PairedDevice = $ListItem
            break
        }
    }
    if ($null -eq $PairedDevice) {
        throw "The validation pairing did not expose a selectable list item."
    }
    $Selection = [System.Windows.Automation.SelectionItemPattern]$PairedDevice.GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern)
    $Selection.Select()

    $ForgetButton = Get-AutomationElementById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostForgetPairedDevice"
    if ($null -eq $ForgetButton) {
        throw "Peel did not expose the paired-device revocation action."
    }
    $EnableDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $ForgetButton.Current.IsEnabled -and
           [DateTime]::UtcNow -lt $EnableDeadline) {
        Start-Sleep -Milliseconds 100
        $ForgetButton = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostForgetPairedDevice"
    }
    if (-not $ForgetButton.Current.IsEnabled) {
        throw "The paired-device revocation action did not enable after selection."
    }

    Invoke-AutomationButtonById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostSetupDisclosure"
    $InputGate = Get-AutomationElementById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostRemoteInputGate"
    $InputGate.SetFocus()
    $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern)
    $Toggle.Toggle()
    $InputDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On -and
           [DateTime]::UtcNow -lt $InputDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Remote input could not be enabled before paired-device revocation."
    }

    Invoke-AutomationButtonById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostDevicesDisclosure"
    $ForgetButton = Get-AutomationElementById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostForgetPairedDevice"
    if ($null -eq $ForgetButton -or -not $ForgetButton.Current.IsEnabled) {
        throw "The paired-device revocation action was not restored after reopening Devices."
    }
    $ForgetButton.SetFocus()
    $Invoke = [System.Windows.Automation.InvokePattern]$ForgetButton.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
    $Invoke.Invoke()

    $Desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $ConfirmationCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        "ForgetPairedDeviceConfirmation")
    $ConfirmationDeadline = [DateTime]::UtcNow.AddSeconds(20)
    $Confirmation = $null
    do {
        $Confirmation = $Desktop.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            $ConfirmationCondition)
        if ($null -eq $Confirmation) {
            Start-Sleep -Milliseconds 200
        }
    } while ($null -eq $Confirmation -and
             [DateTime]::UtcNow -lt $ConfirmationDeadline)
    if ($null -eq $Confirmation) {
        throw "The paired-device confirmation did not appear."
    }
    $UiDiagnostic +=
        "ConfirmationWindow=" +
        "$($Confirmation.Current.ControlType.ProgrammaticName);" +
        "$($Confirmation.Current.ClassName);" +
        "$($Confirmation.Current.NativeWindowHandle)"
    $YesCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        "ConfirmForgetPairedDevice")
    $YesAction = $Confirmation.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $YesCondition)
    if ($null -eq $YesAction) {
        throw "The paired-device confirmation did not expose its Yes action."
    }
    $YesPatternIds =
        @($YesAction.GetSupportedPatterns() | ForEach-Object { $_.Id }) -join ","
    $UiDiagnostic +=
        "YesAction=" +
        "$($YesAction.Current.ControlType.ProgrammaticName);" +
        "$($YesAction.Current.ClassName);" +
        "$($YesAction.Current.NativeWindowHandle);" +
        $YesPatternIds
    $YesInvoke = [System.Windows.Automation.InvokePattern]$YesAction.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
    $YesInvoke.Invoke()
    Wait-AutomationElementAbsent -Root $Desktop -Name "Unpair device?"

    $ProbeDeadline = [DateTime]::UtcNow.AddSeconds(20)
    $ProbeOutput = @()
    do {
        $ProbeOutput = @(
            & $ClientTests --native-host-paired-device-ui-probe $StatePath 2>&1)
        if ($LASTEXITCODE -eq 0 -and
            $ProbeOutput -contains "PASS native paired-device UI removal probe") {
            break
        }

        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $ProbeDeadline)
    if ($LASTEXITCODE -ne 0 -or
        $ProbeOutput -notcontains "PASS native paired-device UI removal probe") {
        throw "The product UI did not persist paired-device removal. $($ProbeOutput -join ' ')"
    }

    Wait-AutomationElementAbsent -Root $Root -Name "Peel validation device"
    $FinalListenerCount = Wait-PeelListeners -ProcessIdentifier $ClientProcess.Id
    [void](Wait-AutomationElementByName -Root $Root -Name "Available")
    Invoke-AutomationButtonById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostSetupDisclosure"
    $InputGate = Get-AutomationElementById `
        -Window $ClientProcess.MainWindowHandle `
        -AutomationId "HostRemoteInputGate"
    $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern)
    if ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "Paired-device revocation restored remote input."
    }

    Stop-Process -Id $ClientProcess.Id -Force
    if (-not $ClientProcess.WaitForExit(10000)) {
        throw "Peel did not stop after paired-device UI validation."
    }
    $ClientProcess = $null

    $VerifyOutput = @(& $ClientTests --native-host-paired-device-ui-verify $StatePath 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        $VerifyOutput -notcontains "PASS native paired-device UI verification") {
        throw "Paired-device UI persistence verification failed. $($VerifyOutput -join ' ')"
    }

    @(
        "PAIRED_DEVICE_UI_TASK_PASSED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        "PairedDeviceVisible=True",
        "ConfirmationVisible=True",
        "CredentialRemoved=True",
        "RemoteInputAfterRevocation=Off",
        "FinalListenerCount=$FinalListenerCount"
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}
catch {
    @(
        "PAIRED_DEVICE_UI_TASK_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message,
        $_.ScriptStackTrace,
        $UiDiagnostic
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
finally {
    if ($null -ne $ClientProcess -and -not $ClientProcess.HasExited) {
        [void]$ClientProcess.CloseMainWindow()
        if (-not $ClientProcess.WaitForExit(5000)) {
            $ClientProcess.Kill()
            [void]$ClientProcess.WaitForExit(5000)
        }
    }

    if (Test-Path $StatePath) {
        [void](& $ClientTests --native-host-paired-device-ui-verify $StatePath 2>&1)
    }
}
