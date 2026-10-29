param(
    [string]$BundleRoot = $PSScriptRoot
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

$ResultPath = Join-Path $BundleRoot "interactive-result.txt"
$ScreenshotPath = Join-Path $BundleRoot "peel-header.png"
$HostExecutable = Join-Path $BundleRoot "host\Peel.Windows.Host.exe"
$ClientExecutable = Install-StableWpfRuntime -SourceRoot (Join-Path $BundleRoot "client")

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PeelWindowRectReader
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr window, out RECT rectangle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr window,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeoutMilliseconds,
        out UIntPtr result);
}
"@

function Wait-AutomationElementName {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 20
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-AutomationElementName -Window $Window -Name $Name) {
            return
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "UI Automation element '$Name' did not appear within $TimeoutSeconds seconds."
}

function Send-PeelWindowMessage {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [uint32]$Message,

        [Parameter(Mandatory)]
        [uint64]$Value
    )

    $Result = [UIntPtr]::Zero
    $ReturnValue = [PeelWindowRectReader]::SendMessageTimeout(
        $Window,
        $Message,
        [UIntPtr]::new($Value),
        [IntPtr]::Zero,
        2,
        5000,
        [ref]$Result)
    if ($ReturnValue -eq [IntPtr]::Zero) {
        $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SendMessageTimeout failed for message $Message with error $ErrorCode."
    }
}

function Wait-PeelListenerState {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessIdentifier,

        [Parameter(Mandatory)]
        [bool]$Listening,

        [int]$TimeoutSeconds = 20
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Count = @(Get-NetTCPConnection `
            -State Listen `
            -OwningProcess $ProcessIdentifier `
            -ErrorAction SilentlyContinue).Count
        if (($Listening -and $Count -ge 2) -or (-not $Listening -and $Count -eq 0)) {
            return $Count
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Deadline)

    throw "Peel Pro listener state did not become Listening=$Listening within $TimeoutSeconds seconds."
}

function Test-AutomationElementName {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if ($Root.Current.Name -eq $Name) {
        return $true
    }
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $null -ne $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $Condition)
}

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

function Invoke-DesktopAutomationElementById {
    param(
        [Parameter(Mandatory)]
        [string]$AutomationId
    )

    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    $Element = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $Condition)
    if ($null -eq $Element) {
        throw "Desktop UI Automation element '$AutomationId' was not found."
    }

    $Invoke = [System.Windows.Automation.InvokePattern]$Element.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern)
    $Invoke.Invoke()
    Start-Sleep -Milliseconds 250
}

function Assert-AutomationControl {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$AutomationId,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [System.Windows.Automation.ControlType]$ControlType,

        [switch]$MustBeEnabled,

        [switch]$MustBeKeyboardFocusable
    )

    $Element = Get-AutomationElementById -Window $Window -AutomationId $AutomationId
    if ($null -eq $Element) {
        throw "UI Automation element '$AutomationId' was not found."
    }
    if ($Element.Current.Name -ne $Name) {
        throw "UI Automation element '$AutomationId' exposed name '$($Element.Current.Name)' instead of '$Name'."
    }
    if ($Element.Current.ControlType -ne $ControlType) {
        throw "UI Automation element '$AutomationId' exposed control type '$($Element.Current.ControlType.ProgrammaticName)' instead of '$($ControlType.ProgrammaticName)'."
    }
    if ($MustBeEnabled -and -not $Element.Current.IsEnabled) {
        throw "UI Automation element '$AutomationId' was not enabled."
    }
    if ($MustBeKeyboardFocusable -and -not $Element.Current.IsKeyboardFocusable) {
        throw "UI Automation element '$AutomationId' was not keyboard focusable."
    }
}

function Get-AutomationElementBounds {
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Window,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
    if ($Root.Current.Name -eq $Name) {
        $RootBounds = $Root.Current.BoundingRectangle
        return "{0},{1},{2},{3}" -f `
            $RootBounds.X, $RootBounds.Y, $RootBounds.Width, $RootBounds.Height
    }
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    $Element = $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $Condition)
    if ($null -eq $Element) {
        throw "UI Automation element '$Name' disappeared before bounds validation."
    }

    $Bounds = $Element.Current.BoundingRectangle
    return "{0},{1},{2},{3}" -f $Bounds.X, $Bounds.Y, $Bounds.Width, $Bounds.Height
}

try {
    $HostOutput = & $HostExecutable --dry-run
    if ($LASTEXITCODE -ne 0) {
        throw "Host dry run exited with code $LASTEXITCODE."
    }

    $InputLine = $HostOutput | Where-Object { $_ -like "Input injection:*" } | Select-Object -First 1
    $WindowLine = $HostOutput | Where-Object { $_ -like "User windows:*" } | Select-Object -First 1
    if ($InputLine -ne "Input injection: disabled") {
        throw "Host did not report its input gate as disabled."
    }
    if ($WindowLine -notmatch "^User windows: [1-9][0-9]*$") {
        throw "Interactive Host did not enumerate any user windows."
    }

    $ClientProcess = Start-Process -FilePath $ClientExecutable -PassThru
    try {
        $Deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $ClientProcess.Refresh()
        } while (-not $ClientProcess.HasExited -and
                 $ClientProcess.MainWindowHandle -eq [IntPtr]::Zero -and
                 [DateTime]::UtcNow -lt $Deadline)

        if ($ClientProcess.HasExited) {
            throw "Peel Pro exited before creating its WPF window."
        }
        if ($ClientProcess.MainWindowHandle -eq [IntPtr]::Zero) {
            throw "Peel Pro did not create a main WPF window within ten seconds."
        }
        if (-not (Test-AutomationElementName -Window $ClientProcess.MainWindowHandle -Name "Peel Pro")) {
            throw "Peel Pro did not open on the Host surface."
        }
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Available"
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSettingsButton" `
            -Name "Settings" `
            -ControlType ([System.Windows.Automation.ControlType]::Button) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSettingsButton"
        Invoke-DesktopAutomationElementById -AutomationId "ClientModeMenuItem"
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Peel Pro"
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Paid Windows client"
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSettingsButton"
        Invoke-DesktopAutomationElementById -AutomationId "HostModeMenuItem"
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Peel Pro"
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Available"
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostAboutButton" `
            -Name "About Peel Pro" `
            -ControlType ([System.Windows.Automation.ControlType]::Button) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "MacCloseButton" `
            -Name "Close" `
            -ControlType ([System.Windows.Automation.ControlType]::Button) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostPairDisclosure"
        $PairingPin = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostPairingPin"
        if ($null -eq $PairingPin -or $PairingPin.Current.Name -notmatch "^[0-9]{6}$") {
            throw "Peel Pro did not expose a bounded six-digit pairing PIN."
        }
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRefreshPairingPin" `
            -Name "Generate new pairing PIN" `
            -ControlType ([System.Windows.Automation.ControlType]::Button) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSetupDisclosure"
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostWindowsOptionsDisclosure"
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRefreshWindows" `
            -Name "Refresh available windows" `
            -ControlType ([System.Windows.Automation.ControlType]::Button) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostAvailableWindows" `
            -Name "Available windows" `
            -ControlType ([System.Windows.Automation.ControlType]::List) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate" `
            -Name "Allow the connected device to control this PC" `
            -ControlType ([System.Windows.Automation.ControlType]::CheckBox) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        $InputGate = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate"
        $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
            throw "Peel Pro remote input did not default off."
        }
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostDevicesDisclosure"
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostPairedDevices" `
            -Name "Paired devices" `
            -ControlType ([System.Windows.Automation.ControlType]::List) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSetupDisclosure"
        $InputGate = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate"
        $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        Assert-AutomationControl `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostLaunchAtLogin" `
            -Name "Start Peel Pro when I sign in" `
            -ControlType ([System.Windows.Automation.ControlType]::CheckBox) `
            -MustBeEnabled `
            -MustBeKeyboardFocusable
        $InitialListenerCount = Wait-PeelListenerState `
            -ProcessIdentifier $ClientProcess.Id `
            -Listening $true

        $InputGate.SetFocus()
        $Toggle.Toggle()
        $InputDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
        } while ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On -and
                 [DateTime]::UtcNow -lt $InputDeadline)
        if ($Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
            throw "Peel Pro remote input could not be explicitly enabled before lock validation."
        }

        Send-PeelWindowMessage `
            -Window $ClientProcess.MainWindowHandle `
            -Message 0x02B1 `
            -Value 0x7
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Hosting paused"
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Paused while Windows is locked"
        $LockListenerCount = Wait-PeelListenerState `
            -ProcessIdentifier $ClientProcess.Id `
            -Listening $false
        $InputGate = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate"
        $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if ($InputGate.Current.IsEnabled -or
            $Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
            throw "Session lock did not disable and close the visible remote-input gate."
        }

        Send-PeelWindowMessage `
            -Window $ClientProcess.MainWindowHandle `
            -Message 0x02B1 `
            -Value 0x8
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Available"
        $UnlockListenerCount = Wait-PeelListenerState `
            -ProcessIdentifier $ClientProcess.Id `
            -Listening $true
        $InputGate = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate"
        $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if (-not $InputGate.Current.IsEnabled -or
            $Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
            throw "Session unlock did not restore hosting with remote input still off."
        }

        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostPairDisclosure"
        $PairingPin = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostPairingPin"
        if ($null -eq $PairingPin -or $PairingPin.Current.Name -notmatch "^[0-9]{6}$") {
            throw "Session unlock did not expose a fresh bounded pairing PIN."
        }
        Invoke-AutomationButtonById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostSetupDisclosure"

        Send-PeelWindowMessage `
            -Window $ClientProcess.MainWindowHandle `
            -Message 0x0218 `
            -Value 0x4
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Paused while this PC sleeps"
        $SuspendListenerCount = Wait-PeelListenerState `
            -ProcessIdentifier $ClientProcess.Id `
            -Listening $false
        Send-PeelWindowMessage `
            -Window $ClientProcess.MainWindowHandle `
            -Message 0x0218 `
            -Value 0x12
        Wait-AutomationElementName `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Available"
        $ResumeListenerCount = Wait-PeelListenerState `
            -ProcessIdentifier $ClientProcess.Id `
            -Listening $true
        $InputGate = Get-AutomationElementById `
            -Window $ClientProcess.MainWindowHandle `
            -AutomationId "HostRemoteInputGate"
        $Toggle = [System.Windows.Automation.TogglePattern]$InputGate.GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        if (-not $InputGate.Current.IsEnabled -or
            $Toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
            throw "Resume did not restore hosting with remote input still off."
        }
        $HostHeadingBounds = Get-AutomationElementBounds `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Peel Pro"
        $HostingStateBounds = Get-AutomationElementBounds `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Available"
        $SettingsBounds = Get-AutomationElementBounds `
            -Window $ClientProcess.MainWindowHandle `
            -Name "Settings"
        Start-Sleep -Seconds 1

        $Rectangle = New-Object PeelWindowRectReader+RECT
        if (-not [PeelWindowRectReader]::GetWindowRect($ClientProcess.MainWindowHandle, [ref]$Rectangle)) {
            throw "GetWindowRect failed for the Peel Pro window."
        }

        $Width = $Rectangle.Right - $Rectangle.Left
        $Height = $Rectangle.Bottom - $Rectangle.Top
        if ($Width -lt 100 -or $Height -lt 100) {
            throw "Peel Pro window bounds are unexpectedly small: ${Width}x${Height}."
        }

        $CaptureHeight = $Height
        $Bitmap = New-Object System.Drawing.Bitmap($Width, $CaptureHeight)
        try {
            $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
            try {
                $Graphics.CopyFromScreen($Rectangle.Left, $Rectangle.Top, 0, 0, $Bitmap.Size)
            }
            finally {
                $Graphics.Dispose()
            }
            $Bitmap.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $Bitmap.Dispose()
        }

        @(
            "INTERACTIVE_SMOKE_PASSED",
            "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
            $InputLine,
            $WindowLine,
            "DefaultMode=Host",
            "SecureRuntimeOnline=True",
            "PairingPinVisible=True",
            "RemoteInputDefaultOff=True",
            "HostAccessibilityContract=True",
            "InitialListenerCount=$InitialListenerCount",
            "SessionLockListeners=$LockListenerCount",
            "SessionUnlockListeners=$UnlockListenerCount",
            "SuspendListeners=$SuspendListenerCount",
            "ResumeListeners=$ResumeListenerCount",
            "SessionLockFailClosed=True",
            "SuspendResumeFailClosed=True",
            "HostHeadingBounds=$HostHeadingBounds",
            "HostingStateBounds=$HostingStateBounds",
            "SettingsBounds=$SettingsBounds",
            "PeelWindow=${Width}x${Height}",
            "HeaderScreenshot=$ScreenshotPath"
        ) | Set-Content -Path $ResultPath -Encoding UTF8
    }
    finally {
        if ($null -ne $ClientProcess) {
            $ClientProcess.Refresh()
            if (-not $ClientProcess.HasExited) {
                if ($ClientProcess.CloseMainWindow()) {
                    [void]$ClientProcess.WaitForExit(10000)
                    $ClientProcess.Refresh()
                }

                if (-not $ClientProcess.HasExited) {
                    Stop-Process -Id $ClientProcess.Id -Force
                    [void]$ClientProcess.WaitForExit(5000)
                }
            }
        }
    }
}
catch {
    @(
        "INTERACTIVE_SMOKE_FAILED",
        "SessionId=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)",
        $_.Exception.Message
    ) | Set-Content -Path $ResultPath -Encoding UTF8
    exit 1
}
