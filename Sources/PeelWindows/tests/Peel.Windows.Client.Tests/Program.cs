using System.Collections.Concurrent;
using System.ComponentModel;
using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Win32;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Pairing;
using Peel.Windows.Host.Security;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static readonly (string Name, Func<Task> Test)[] Tests =
    {
        ("lighting libraries preserve bounded Mac archives and atomic profile edits", Sync(LightingProfilePersistence)),
        ("agent allocations preserve occupancy, residency, expiry and simple priority", Sync(LightingAllocationSemantics)),
        ("lighting profile controls refresh composed Pro and Dot outputs", LightingProfileCompositionAsync),
        ("lighting output matches live Mac compiler and allocator vectors", Sync(MacLightingVectors)),
        ("battery previews preserve firmware gauges and known power-transition rules", Sync(BatteryIndicatorSemantics)),
        ("microphone observation distinguishes unknown, mute capability and stale data", Sync(MicrophoneObservationSemantics)),
        ("command progress parses bounded stdout without stderr or partial-line confusion", Sync(ProgressParsing)),
        ("countdown preserves pause/completion semantics and firmware scenes", Sync(CountdownAndScenes)),
        ("USB light output binds one device generation and releases consent", SidePulseOutputOwnershipAsync),
        ("signal renderer matches firmware timing, indices, brightness and bounds", Sync(SignalFirmwareRendering)),
        ("signal presentation retains source identity, freshness and validated profiles", SignalPresentationSelectionAsync),
        ("stream diagnostics bind generations, consent and measured intervals", Sync(StreamDiagnosticsOwnership)),
        ("metric history requires observed coverage, weights intervals and bounds preferences", Sync(MetricHistoryCoverage)),
        ("Host audio requires current consent, proof and ticket with bounded packets and complete stop", HostAudioAuthorizationAsync),
        ("Host PCM framing preserves samples and discards discontinuous partial packets", Sync(HostPcmFramesAreBounded)),
        ("signal publishing preserves both pairing identities and rejects ambiguity", Sync(SignalPublishingUsesPairingIdentity)),
        ("signal sharing cannot restart after consent cancellation", SignalPublishingCancelDuringStartAsync),
        ("GPU leases recycle only after every compositor releases ownership", Sync(GpuLeaseOwnership)),
        ("local agent observations are bounded, partial-safe and metadata-only", Sync(LocalActivityObservations)),
        ("SIMD pixel conversion matches scalar colors, strides and tails", Sync(SimdPixelConversionMatchesScalar)),
        ("usage history is bounded and retains unavailable pinned identity", Sync(UsageHistoryIsBounded)),
        ("local chat metadata uses bounded read-only native queries", Sync(LocalHistoryIsReadOnly)),
        ("utility shutdown cancels pending dispatcher work without deadlock", UtilityShutdownAsync),
        ("audio authorization requires pending playback consent and exact mode", AudioConsentAsync),
        ("source media binds one viewer's stream, fences epochs and bounds pending replies", SourceMediaControllerBindsOwnerAndFencesRepliesAsync),
        ("source volume transport accepts only actual, monotonic, same-scope state", SourceVolumeTransportUsesActualMonotonicStateAsync),
        ("a fenced source command never leaves a blocked writer; the reopened owner's does", SourceMediaFencedCommandNeverLeavesBlockedWriterAsync),
        ("a volume gesture commits only its captured owner and intended value", SourceVolumeGestureBindsOwnerAndIntendedValueAsync),
        ("default Listen is playback-only and fenced to the admitting generation", DefaultListenIsPlaybackOnlyAndGenerationFencedAsync),
        ("explicit Listen Off persists per pairing and unreadable state fails closed", Sync(ClientAudioPreferencesPreserveExplicitOff)),
        ("source control visibility toggles hide only presentation", Sync(SourceControlsHideOnlyPresentation)),
        ("app alert streaks bind process identity and memory protection requires opt-in", Sync(AlertRulesRequireSustainedIdentity)),
        ("Machine Status proof requires explicit pending consent", MachineStatusClientConsentAsync),
        ("HEVC Annex-B conversion preserves parameter sets and rejects hostile lengths", Sync(HevcFramingIsBounded)),
        ("usage windows preserve bucket identity and unavailable readings", Sync(UsageBucketsPreserveUnavailable)),
        ("utility actions reject self, system, background and foreign session targets", Sync(UtilityActionsRejectUnsafeIdentity)),
        ("free client sends clientHello first and hostHello gates Connected", HelloGateAndWindowListAsync),
        ("immediate window list is accepted while request write is in progress", ImmediateWindowListAsync),
        ("PIN pairing persists only validated accepted credentials", ClientPinPairingPersistsAsync),
        ("PIN pairing rejects hostile responses and partial-read cancellation", ClientPinPairingHostileAsync),
        ("discovery isolates service removal and pins exact video endpoint", ClientDiscoveryPinsEndpointAsync),
        ("private addresses reject public and malformed endpoints", Sync(PrivateAddressesFailClosed)),
        ("letterboxing rejects black-bar clicks and clamps captured drag", Sync(ViewportLetterboxing)),
        ("input waits for Host focus and releases held input", ClientInputFocusAndReleaseAsync),
        ("pending focus cannot restore revoked control", ClientInputFocusCancellationAsync),
        ("Host input rejection releases held input", ClientInputRejectionAsync),
        ("pairing revocation closes only the matching session", ClientPairingRevocationAsync),
        ("stream stops when a window ID belongs to a new app instance", ReusedWindowIdentityStopsAsync),
        ("incompatible hostHello fails closed", IncompatibleHostHelloFailsClosedAsync),
        ("stable host and pairing identities stay separate", HostIdentityMismatchFailsBeforeTlsAsync),
        ("missing credentials fail before TLS", MissingCredentialFailsBeforeTlsAsync),
        ("hostile NDJSON closes the session", HostileNdjsonFailsClosedAsync),
        ("generic IO preserves credentials and reconnect resolves fresh", IoPreservesCredentialAndFreshResolveAsync),
        ("connect cancellation tears down", ConnectCancellationAsync),
        ("free client preserves unavailable receiver readiness", UnavailableReceiverFailsClosedAsync),
        ("single-instance lease excludes a second app", Sync(SingleInstanceLeaseExcludesSecondApp)),
        ("tray close policy hides until explicit exit", Sync(TrayClosePolicyHidesUntilExit)),
        ("launch-at-login value is exact and reversible", Sync(LaunchAtLoginValueIsExactAndReversible)),
        ("Host startup failure retries with a fresh runtime", HostStartupFailureRetriesFreshAsync),
        ("Host initially locked session opens no runtime before unlock", HostInitiallyLockedSessionDefersRuntimeAsync),
        ("Host initial session query failure cannot be bypassed by retry", HostInitialSessionFailureCannotBeBypassedAsync),
        ("Windows initial session snapshot validates state and identity", Sync(WindowsInitialSessionSnapshotValidatesState)),
        ("Host lifecycle pauses fail closed and restart fresh", HostLifecyclePausesAndRestartsAsync),
        ("Host network restart is fail closed and coalesced", HostNetworkRestartIsFailClosedAsync),
        ("Host paired-device revocation restarts fail closed", HostPairedDeviceRevocationRestartsFailClosedAsync),
        ("Windows lifecycle messages classify fail closed", Sync(WindowsLifecycleMessagesClassifyFailClosed)),
        ("Windows network notifications coalesce", Sync(WindowsNetworkNotificationsCoalesce)),
        ("latest decoded frame mailbox drops superseded UI work", Sync(LatestFrameMailboxDropsSupersededWork)),
        ("H.264 payloads convert to bounded Annex-B", Sync(H264PayloadsConvertToAnnexB)),
        ("NV12 output converts to bounded BGRA32", Sync(Nv12OutputConvertsToBgra32)),
        ("video hello precedes bounded binary and resize configs", VideoHelloThenBinaryAsync),
        ("video negotiation fails before TLS", VideoNegotiationFailsBeforeTlsAsync),
        ("wrong video window and codec fail closed", WrongVideoIdentityFailsClosedAsync),
        ("hostile video packet length fails closed", HostileVideoLengthFailsClosedAsync),
        ("hostile video metadata fails closed", HostileVideoMetadataFailsClosedAsync),
        ("stale video generation cannot restore streaming state", StaleVideoGenerationIsSuppressedAsync),
        ("video connect cancellation tears down", VideoConnectCancellationAsync),
        ("stream controller orders video hello start and stop", StreamControllerOrdersWireAsync),
        ("stream controller disconnect and reconnect resolve fresh", StreamControllerReconnectAsync),
        ("stream controller cancellation tears down", StreamControllerCancellationAsync),
        ("active stream lifetime cancellation sends stop", ActiveStreamCancellationAsync),
        ("stream controller rejects malformed and unsupported starts", StreamControllerRejectsInvalidStartsAsync),
        ("local computer control needs fresh UI consent, a quiet person and exact window tokens", LocalComputerConsentAndTokensAsync),
        ("person input after a completed inspection voids it between requests", LocalComputerHumanInputVoidsAuthorityAsync),
        ("own injected input is attributed to its batch; later input is the person's", LocalComputerOwnInputIsAccountedAsync),
        ("local control refuses moved windows, reused process identity and old generations", LocalComputerIdentityReuseIsRefusedAsync),
        ("local inspections expire, are single-use and cannot be guessed", LocalComputerInspectionsExpireAndAreSingleUseAsync),
        ("local control refuses elevated, covered, secure-desktop and credential targets", LocalComputerRefusesProtectedTargetsAsync),
        ("local Stop and person input release only owned held input", LocalComputerCancellationReleasesOwnedInputAsync),
        ("local AI and paired-device input gates are isolated", Sync(LocalAndRemoteInputGatesAreIsolated)),
        ("local control vocabulary matches Mac bounds and refuses shell shortcuts", Sync(LocalControlVocabularyIsBounded)),
        ("inspection JPEG is bounded and fails closed", Sync(BoundedJpegFailsClosed)),
        ("a person's key inside the agent's own-input window still voids authority", LocalComputerPersonInsideOwnWindowIsNeverAbsorbedAsync),
        ("keyboard-only person input stops a drag without pointer drift", LocalComputerKeyboardDuringDragInterruptsAsync),
        ("local control requires an owned activity monitor and stops when it is lost", LocalComputerRequiresOwnedActivityMonitorAsync),
        ("Stop before a gated send releases nothing that batch never pressed", LocalComputerStopBeforeGatedSendReleasesNothingAsync),
        ("partial sends release exactly the presses Windows accepted", LocalComputerPartialSendReleasesExactlyItsPressesAsync),
        ("local agent pipe stays current-user with the CurrentUserOnly owner", Sync(LocalAgentPipeSecurityStaysCurrentUser)),
        ("raw input headers count whatever the device handle; unreadable headers fault", Sync(RawInputHeadersCountWhateverTheDevice)),
        ("unknown raw input registrations are never empty, ownership or replaceable", Sync(RawInputRegistrationUnknownIsNotEmpty)),
        ("zero-device raw input inside the own-input window voids authority", LocalComputerZeroDeviceInsideOwnWindowVoidsAuthorityAsync),
        ("own input reported as raw input self-interrupts and fails closed", LocalComputerOwnRawInputSelfInterruptsAsync),
        ("launches recheck this request's authority before every side effect", Sync(LocalLaunchRechecksRequestAuthority)),
        ("MCP configuration starts the installed companion and keeps the dotnet fallback", Sync(AgentConfigurationStartsInstalledCompanion)),
    };

    public static async Task<int> Main(string[] args)
    {
        if (args is ["--native-lighting-profile-smoke"]) return await NativeLightingProfileAsync();
        if (args is ["--lighting-tests"])
        {
            LightingProfilePersistence(); LightingAllocationSemantics(); await LightingProfileCompositionAsync();
            Console.WriteLine("PASS lighting profile persistence, allocation and composed controls."); return 0;
        }
        if (args is ["--export-lighting-test-archive", var archivePath])
        {
            File.WriteAllBytes(archivePath, Peel.Windows.Client.Utilities.LightingProfileStore.Export([
                Peel.Windows.Client.Utilities.LightingProfile.Factory, Peel.Windows.Client.Utilities.LightingProfile.Quiet, Peel.Windows.Client.Utilities.LightingProfile.High]));
            Console.WriteLine("Exported three fixture profiles for the Mac importer."); return 0;
        }
        if (args is ["--verify-lighting-test-archive", var archiveResult])
        {
            var imported = Peel.Windows.Client.Utilities.LightingProfileStore.Import(File.ReadAllBytes(archiveResult));
            Equal(3, imported.Length);
            foreach (var expected in new[] { Peel.Windows.Client.Utilities.LightingProfile.Factory, Peel.Windows.Client.Utilities.LightingProfile.Quiet, Peel.Windows.Client.Utilities.LightingProfile.High })
            {
                var actual = imported.Single(p => p.Id == expected.Id);
                Equal(expected.Name, actual.Name); Equal(expected.Strategy, actual.Strategy); Equal(expected.DeviceBrightness, actual.DeviceBrightness);
                SequenceEqual(expected.Styles, actual.Styles);
            }
            Console.WriteLine("PASS Mac-to-Windows archive round trip preserves every fixture profile and style."); return 0;
        }
        if (args is ["--native-power-status-smoke"])
        {
            using var monitor = new Peel.Windows.Client.Utilities.SystemMonitor(); var power = await Task.Run(monitor.Sample);
            True(power.BatteryPercent is null or (>= 0 and <= 100), "Battery must be bounded or unavailable.");
            Console.WriteLine($"PASS native power status: battery={power.BatteryPercent?.ToString("F0") ?? "unavailable"}%, external={power.ExternallyPowered?.ToString() ?? "unavailable"}, charging={power.Charging?.ToString() ?? "unavailable"}."); return 0;
        }
        if (args is ["--native-microphone-status-smoke"])
        {
            var observed = await Task.Run(Peel.Windows.Client.Utilities.MicrophoneActivity.Read);
            True(observed.State is "active" or "idle" or "muted", "Native fixture requires an observable Windows input endpoint. " + observed.Detail);
            Console.WriteLine("PASS native read-only capture-session/endpoint-mute observation: " + observed.State + ". No microphone stream opened or mute state changed."); return 0;
        }
        if (args is ["--native-progress-tasks-smoke"]) return await NativeProgressTasksAsync();
        if (args is ["--native-keep-awake-smoke"]) return NativeKeepAwake();
        if (args is ["--native-light-file-smoke"]) return await NativeLightFileAsync();
        if (args is ["--native-signal-lights-smoke"]) return await NativeSignalLightsAsync();
        if (args is ["--native-host-audio-smoke"]) return await NativeHostAudioAsync();
        if (args is ["--native-host-loopback-audio-smoke"]) return await NativeHostAudioAsync(true);
        if (args is ["--audio-expiration-smoke"]) return await NativeAudioExpiryAsync();
        if (args is ["--pixel-conversion-benchmark"]) return PixelConversionBenchmark();
        if (args is ["--native-gpu-color-smoke"]) return GpuColorConversionSmoke();
        if (args is ["--native-gpu-presentation-smoke"]) return await GpuPresentationSmokeAsync();
        if (args is ["--native-gpu-pipeline-benchmark"]) return await NativeGpuPipelineBenchmarkAsync();
        if (args is ["--native-gpu-ownership-smoke"]) return await GpuOwnershipSmokeAsync();
        if (args is ["--native-trusted-signals-smoke"]) return await NativeTrustedSignalsAsync();
        if (args is ["--native-signal-publishing-smoke"]) return await NativeSignalPublishingAsync();
        if (args is ["--native-signal-advertisement-smoke"]) return await NativeSignalAdvertisementAsync();
        if (args is ["--native-agent-activity-smoke"])
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var rows = new Peel.Windows.Client.Utilities.LocalAgentActivity().Read(timeout.Token);
            True(rows.Count > 0, "This native fixture requires current local Codex activity.");
            Console.WriteLine("PASS native local Codex event metadata: " + rows.Count + " recent sessions; states=" + string.Join(",", rows.Select(r => r.State).Distinct()));
            return 0;
        }
        if (args is ["--native-agent-history-smoke"])
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var rows = Peel.Windows.Client.Utilities.LocalAgentHistory.Read(timeout.Token);
            True(rows.Count is > 0 and <= 128, "Native local history must return bounded metadata.");
            Console.WriteLine($"PASS native Windows SQLite: {rows.Count} recent chat metadata records read; no chat bodies emitted."); return 0;
        }
        if (args is ["--native-audio-output-smoke"]) return NativeAudioOutputSmoke();
        if (args is ["--native-process-loopback-smoke"]) return await NativeProcessLoopbackAsync();
        if (args is ["--native-audio-receive-smoke"]) return await NativeAudioReceiveAsync();
        if (args is ["--native-voice-duplex-smoke"]) return await NativeAudioReceiveAsync(true);
        if (args is ["--native-microphone-format-query"])
        {
            True(WaveMicrophoneCapture.QueryFormat(), "Default microphone must support the 48kHz mono PCM format query.");
            Console.WriteLine("PASS Windows microphone format query (device was not opened or recorded)."); return 0;
        }
        if (args is ["--process-action-fixture"]) return await ProcessActionFixtureAsync();
        if (args is ["--native-process-actions-smoke"]) return await NativeProcessActionsAsync();
        if (args is ["--native-local-agent-smoke"]) return await NativeLocalAgentBridgeAsync();
        if (args is ["--native-local-computer-smoke"]) return await NativeLocalComputerBridgeAsync();
        if (args is ["--native-detached-viewer-smoke"]) return await NativeDetachedViewerLifecycleAsync();
        if (args is ["--native-raw-input-registration-smoke"]) return await NativeRawInputRegistrationAsync();
        if (args is ["--attended-raw-input-attribution-smoke"]) return await AttendedRawInputAttributionAsync();
        if (args is ["--native-machine-status-smoke"]) return await NativeMachineStatusAsync();
        if (args is ["--native-hevc-smoke"]) return await NativeHevcRoundTripAsync();
        if (args is ["--native-hevc-5k-smoke"]) return await NativeHevcRoundTripAsync(5120, 2880, true);
        if (args is ["--native-hevc-gpu-input-smoke"]) return await NativeHevcRoundTripAsync(5120, 2880, true, true, true);
        if (args is ["--native-hevc-software-decode-smoke"]) return await NativeHevcRoundTripAsync(1920, 1080, true, false);
        if (args is ["--native-hevc-hardware-smoke"]) return await NativeHevcRoundTripAsync(1920, 1080, true);
        if (args is ["--codec-inventory"])
        {
            foreach (var codec in new[] { VideoCodec.H264, VideoCodec.Hevc })
                foreach (bool encoder in new[] { false, true })
                    foreach (var item in MediaFoundationCodecCatalog.Inspect(codec, encoder))
                        Console.WriteLine($"{codec} {(encoder ? "encode" : "decode")}: {item.Name} (hardware={item.Hardware})");
            return 0;
        }
        if (args is ["--native-utilities-smoke"]) return await NativeUtilitiesSmokeAsync();
        if (args is ["--utilities-layout", var utilitiesPath]) return await RenderUtilitiesLayoutAsync(utilitiesPath);
        if (args is ["--utilities-layout", var utilitiesSectionPath, var utilitiesSection]) return await RenderUtilitiesLayoutAsync(utilitiesSectionPath, int.Parse(utilitiesSection));
        if (args is ["--native-client-receive-smoke"]) return await NativeClientReceiveSmokeAsync();
        if (args is ["--native-client-5k-gpu-receive-smoke"]) return await NativeClientReceiveSmokeAsync(true, true);
        if (args is ["--native-client-diagnostics-smoke"]) return await NativeClientDiagnosticsAsync();
        if (args is ["--native-peer-diagnostics-smoke"]) return await NativePeerDiagnosticsAsync();
        if (args is ["--native-client-5k-receive-smoke"]) return await NativeClientReceiveSmokeAsync(true);
        if (args is ["--client-layout", var layoutPath]) return await RenderClientLayoutAsync(layoutPath);
        if (args is ["--studio-layout", var studioPath, var studioSection, var studioWidth, var studioHeight]) return await RenderClientLayoutAsync(studioPath, int.Parse(studioSection), int.Parse(studioWidth), int.Parse(studioHeight));

        if (args is ["--native-h264-decode-smoke"])
        {
            return await RunNativeH264DecodeSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-host-network-restart-smoke"])
        {
            return await RunNativeHostNetworkRestartSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-host-paired-device-revocation-smoke"])
        {
            return await RunNativeHostPairedDeviceRevocationSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-host-paired-device-ui-seed", var seedStatePath])
        {
            return RunNativeHostPairedDeviceUiSeed(seedStatePath);
        }

        if (args is ["--native-host-paired-device-ui-verify", var verifyStatePath])
        {
            return RunNativeHostPairedDeviceUiVerify(verifyStatePath);
        }

        if (args is ["--native-host-paired-device-ui-probe", var probeStatePath])
        {
            return RunNativeHostPairedDeviceUiProbe(probeStatePath);
        }

        if (args is ["--native-host-paired-device-validation-cleanup"])
        {
            return RunNativeHostPairedDeviceValidationCleanup();
        }

        if (args.Length != 0)
        {
            Console.Error.WriteLine(
                "Usage: Peel.Windows.Client.Tests " +
                "[--native-h264-decode-smoke|--native-host-network-restart-smoke|" +
                "--native-host-paired-device-revocation-smoke|" +
                "--native-host-paired-device-ui-seed <state-path>|" +
                "--native-host-paired-device-ui-verify <state-path>|" +
                "--native-host-paired-device-ui-probe <state-path>|" +
                "--native-host-paired-device-validation-cleanup]");
            return 2;
        }

        var failures = 0;
        foreach (var (name, test) in Tests)
        {
            try
            {
                await test();
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception}");
            }
        }

        Console.WriteLine($"{Tests.Length - failures}/{Tests.Length} client session tests passed");
        return failures == 0 ? 0 : 1;
    }

    private static async Task<int> RunNativeHostNetworkRestartSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host network recovery requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await using var lifecycle = new HostRuntimeLifecycleController();
            await lifecycle.StartAsync(timeout.Token).WaitAsync(timeout.Token)
                .ConfigureAwait(false);

            HostRuntimeLifecycleState initial = lifecycle.State;
            RequireActiveHostListeners(initial);
            HostPairingPin initialPin = initial.PairingPin ??
                throw new InvalidOperationException(
                    "The initial Host runtime must publish a pairing PIN.");

            lifecycle.SetInputEnabled(true);
            Task restart = lifecycle.RestartAsync(timeout.Token);
            HostRuntimeLifecycleState restarting = lifecycle.State;
            True(!restarting.IsRunning,
                "A requested network generation must immediately hide the stale runtime.");
            True(!restarting.IsInputEnabled,
                "A requested network generation must immediately close remote input.");
            await restart.WaitAsync(timeout.Token).ConfigureAwait(false);

            HostRuntimeLifecycleState recovered = lifecycle.State;
            RequireActiveHostListeners(recovered);
            HostPairingPin recoveredPin = recovered.PairingPin ??
                throw new InvalidOperationException(
                    "The recovered Host runtime must publish a pairing PIN.");
            True(!string.Equals(
                    initialPin.SaltBase64,
                    recoveredPin.SaltBase64,
                    StringComparison.Ordinal),
                "The recovered Host runtime must publish a fresh pairing generation.");
            True(!recovered.IsInputEnabled,
                "Network recovery must not restore remote input.");

            Console.WriteLine(
                "PASS native Host network recovery: listeners restarted, " +
                "discovery re-registered, input stayed off");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"FAIL native Host network recovery: {exception.GetType().Name}: {message}");
            return 1;
        }
    }

    private static void RequireActiveHostListeners(HostRuntimeLifecycleState state)
    {
        True(state.IsRunning, "The secure Host runtime must be running.");
        int controlPort = state.ControlPort ??
            throw new InvalidOperationException("The control listener port is unavailable.");
        int pairingPort = state.PairingPort ??
            throw new InvalidOperationException("The pairing listener port is unavailable.");
        IPEndPoint[] listeners =
            IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners();
        True(listeners.Any(listener => listener.Port == controlPort),
            "The control listener must be active in Windows.");
        True(listeners.Any(listener => listener.Port == pairingPort),
            "The pairing listener must be active in Windows.");
    }

    private static async Task<int> RunNativeHostPairedDeviceRevocationSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native paired-device revocation requires Windows 10 version 2004 or later.");
            return 2;
        }

        string uniqueId = Guid.NewGuid().ToString("N");
        string pairingId = $"peel-revocation-{uniqueId}";
        string deviceId = $"peel-revocation-device-{uniqueId}";
        string credentialTarget = WindowsPairedClientStore.CredentialTarget(
            WindowsPairedClientStore.DefaultCredentialTargetPrefix,
            pairingId);
        byte[] preSharedKey = RandomNumberGenerator.GetBytes(
            WindowsPairedClientStore.PreSharedKeyBytes);
        var credential = new PeelPskCredential(pairingId, preSharedKey);
        var vault = new WindowsCredentialManager();

        try
        {
            var setupStore = new WindowsPairedClientStore();
            _ = setupStore.AddOrReplace(
                pairingId,
                "Peel validation device",
                deviceId,
                preSharedKey);
            True(vault.TryRead(credentialTarget, out byte[]? storedSecret),
                "The validation credential must be present before revocation.");
            if (storedSecret is not null)
            {
                CryptographicOperations.ZeroMemory(storedSecret);
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await using var lifecycle = new HostRuntimeLifecycleController();
            await lifecycle.StartAsync(timeout.Token).WaitAsync(timeout.Token)
                .ConfigureAwait(false);
            HostRuntimeLifecycleState initial = lifecycle.State;
            RequireActiveHostListeners(initial);
            True(initial.PairedClients.Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    pairingId)),
                "The production Host must surface the paired device before revocation.");

            int controlPort = initial.ControlPort ??
                throw new InvalidOperationException("The control listener port is unavailable.");
            var transport = new BouncyCastlePskTransportFactory();
            await using Stream controlStream = await transport.ConnectAsync(
                    new DnsEndPoint(IPAddress.Loopback.ToString(), controlPort),
                    credential,
                    timeout.Token)
                .ConfigureAwait(false);
            await controlStream.WriteAsync(
                    PeelJson.SerializeLine(PeelHello.CreateClient(
                        pairingId,
                        "Peel validation device",
                        "Windows")),
                    timeout.Token)
                .ConfigureAwait(false);
            await controlStream.FlushAsync(timeout.Token).ConfigureAwait(false);
            ReadOnlyMemory<byte> hostHello = await ReadNativeControlLineAsync(
                    controlStream,
                    timeout.Token)
                .ConfigureAwait(false);
            Equal(PeelMessageType.HostHello, PeelJson.ReadEnvelope(hostHello.Span).Type);

            lifecycle.SetInputEnabled(true);
            True(await lifecycle.RevokePairedClientAsync(pairingId, timeout.Token)
                .ConfigureAwait(false),
                "The production lifecycle must remove the selected paired device.");
            await RequireNativeControlDisconnectAsync(controlStream, timeout.Token)
                .ConfigureAwait(false);

            HostRuntimeLifecycleState recovered = lifecycle.State;
            RequireActiveHostListeners(recovered);
            True(!recovered.PairedClients.Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    pairingId)),
                "The recovered Host must exclude the revoked pairing.");
            True(!recovered.IsInputEnabled,
                "Paired-device revocation must not restore remote input.");
            var verifiedStore = new WindowsPairedClientStore();
            True(!verifiedStore.Snapshot().Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    pairingId)),
                "Revoked paired-device metadata must remain removed.");
            bool removedSecretPresent = vault.TryRead(
                credentialTarget,
                out byte[]? removedSecret);
            if (removedSecret is not null)
            {
                CryptographicOperations.ZeroMemory(removedSecret);
            }
            True(!removedSecretPresent,
                "The revoked paired-device secret must be absent from Credential Manager.");

            Console.WriteLine(
                "PASS native Host paired-device revocation: active peer disconnected, " +
                "credential removed, listeners restarted, input stayed off");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"FAIL native Host paired-device revocation: " +
                $"{exception.GetType().Name}: {message}");
            return 1;
        }
        finally
        {
            try
            {
                _ = new WindowsPairedClientStore().Remove(pairingId);
            }
            catch
            {
            }

            try
            {
                _ = vault.Delete(credentialTarget);
            }
            catch
            {
            }

            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            CryptographicOperations.ZeroMemory(preSharedKey);
        }
    }

    private static async Task<ReadOnlyMemory<byte>> ReadNativeControlLineAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var reader = new BoundedNdjsonLineReader(
            HostControlSessionOptions.DefaultMaximumFirstLineBytes);
        var buffer = new byte[4096];
        while (true)
        {
            int byteCount = await stream.ReadAsync(buffer, cancellationToken)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new EndOfStreamException(
                    "The production Host disconnected before sending Host hello.");
            }

            if (reader.TryAppend(
                    buffer.AsSpan(0, byteCount),
                    out _,
                    out ReadOnlyMemory<byte> line))
            {
                return line;
            }
        }
    }

    private static int RunNativeHostPairedDeviceValidationCleanup()
    {
        try
        {
            var store = new WindowsPairedClientStore();
            HostPairedClient[] validationPeers = store.Snapshot()
                .Where(IsPairedDeviceValidationPeer)
                .ToArray();
            foreach (HostPairedClient peer in validationPeers)
            {
                _ = store.Remove(peer.PairingId);
            }

            True(!store.Snapshot().Any(IsPairedDeviceValidationPeer),
                "A paired-device validation record survived cleanup.");
            Console.WriteLine(
                $"PASS native paired-device validation cleanup: removed={validationPeers.Length}");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"FAIL native paired-device validation cleanup: " +
                $"{exception.GetType().Name}: {message}");
            return 1;
        }
    }

    private static bool IsPairedDeviceValidationPeer(HostPairedClient peer) =>
        StringComparer.Ordinal.Equals(peer.DisplayName, "Peel validation device") &&
        ((peer.PairingId.StartsWith("peel-revocation-", StringComparison.Ordinal) &&
            peer.DeviceId.StartsWith(
                "peel-revocation-device-",
                StringComparison.Ordinal)) ||
        (peer.PairingId.StartsWith("peel-ui-revocation-", StringComparison.Ordinal) &&
            peer.DeviceId.StartsWith(
                "peel-ui-revocation-device-",
                StringComparison.Ordinal)));

    private static async Task RequireNativeControlDisconnectAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[1];
        try
        {
            int byteCount = await stream.ReadAsync(buffer, cancellationToken)
                .ConfigureAwait(false);
            Equal(0, byteCount);
        }
        catch (IOException)
        {
            // TLS close may surface as EOF or an authenticated transport error.
        }
    }

    private static int RunNativeHostPairedDeviceUiSeed(string statePath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native paired-device UI setup requires Windows 10 version 2004 or later.");
            return 2;
        }

        string fullStatePath = Path.GetFullPath(statePath);
        if (File.Exists(fullStatePath))
        {
            Console.Error.WriteLine("Paired-device UI state already exists.");
            return 1;
        }

        string uniqueId = Guid.NewGuid().ToString("N");
        string pairingId = $"peel-ui-revocation-{uniqueId}";
        string deviceId = $"peel-ui-revocation-device-{uniqueId}";
        byte[] preSharedKey = RandomNumberGenerator.GetBytes(
            WindowsPairedClientStore.PreSharedKeyBytes);
        try
        {
            var store = new WindowsPairedClientStore();
            _ = store.AddOrReplace(
                pairingId,
                "Peel validation device",
                deviceId,
                preSharedKey);
            File.WriteAllText(fullStatePath, pairingId, new UTF8Encoding(false));
            Console.WriteLine("PASS native paired-device UI seed");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"FAIL native paired-device UI seed: {exception.GetType().Name}: {message}");
            try
            {
                _ = new WindowsPairedClientStore().Remove(pairingId);
            }
            catch
            {
            }

            return 1;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(preSharedKey);
        }
    }

    private static int RunNativeHostPairedDeviceUiVerify(string statePath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native paired-device UI verification requires Windows 10 version 2004 or later.");
            return 2;
        }

        string fullStatePath = Path.GetFullPath(statePath);
        string? pairingId = null;
        string? credentialTarget = null;
        var vault = new WindowsCredentialManager();
        try
        {
            var info = new FileInfo(fullStatePath);
            if (!info.Exists || info.Length is <= 0 or > 4096)
            {
                throw new InvalidDataException(
                    "The paired-device UI state is missing or oversized.");
            }

            pairingId = File.ReadAllText(fullStatePath, Encoding.UTF8).Trim();
            credentialTarget = WindowsPairedClientStore.CredentialTarget(
                WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                pairingId);
            var store = new WindowsPairedClientStore();
            True(!store.Snapshot().Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    pairingId)),
                "The product UI did not remove the paired-device metadata.");
            bool secretPresent = vault.TryRead(credentialTarget, out byte[]? secret);
            if (secret is not null)
            {
                CryptographicOperations.ZeroMemory(secret);
            }
            True(!secretPresent,
                "The product UI did not remove the paired-device secret.");

            Console.WriteLine("PASS native paired-device UI verification");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"FAIL native paired-device UI verification: " +
                $"{exception.GetType().Name}: {message}");
            return 1;
        }
        finally
        {
            if (pairingId is not null)
            {
                try
                {
                    _ = new WindowsPairedClientStore().Remove(pairingId);
                }
                catch
                {
                }
            }

            if (credentialTarget is not null)
            {
                try
                {
                    _ = vault.Delete(credentialTarget);
                }
                catch
                {
                }
            }

            try
            {
                File.Delete(fullStatePath);
            }
            catch
            {
            }
        }
    }

    private static int RunNativeHostPairedDeviceUiProbe(string statePath)
    {
        try
        {
            string fullStatePath = Path.GetFullPath(statePath);
            var info = new FileInfo(fullStatePath);
            if (!info.Exists || info.Length is <= 0 or > 4096)
            {
                throw new InvalidDataException(
                    "The paired-device UI state is missing or oversized.");
            }

            string pairingId = File.ReadAllText(fullStatePath, Encoding.UTF8).Trim();
            var store = new WindowsPairedClientStore();
            True(!store.Snapshot().Any(peer => StringComparer.Ordinal.Equals(
                    peer.PairingId,
                    pairingId)),
                "The product UI has not removed the paired-device metadata yet.");
            string credentialTarget = WindowsPairedClientStore.CredentialTarget(
                WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                pairingId);
            var vault = new WindowsCredentialManager();
            bool secretPresent = vault.TryRead(credentialTarget, out byte[]? secret);
            if (secret is not null)
            {
                CryptographicOperations.ZeroMemory(secret);
            }

            True(!secretPresent,
                "The product UI has not removed the paired-device secret yet.");
            Console.WriteLine("PASS native paired-device UI removal probe");
            return 0;
        }
        catch (Exception exception)
        {
            string message = exception.Message.Replace('\r', ' ').Replace('\n', ' ');
            Console.Error.WriteLine(
                $"WAIT native paired-device UI removal probe: " +
                $"{exception.GetType().Name}: {message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeH264DecodeSmokeAsync()
    {
        const int width = 64;
        const int height = 64;
        const int targetDecodedFrames = 10;
        const uint windowId = 1;

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine("Native H.264 decode smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            var settings = new VideoEncodingSettings(
                VideoCodec.H264,
                width,
                height,
                30,
                1_000_000);
            var encoderFactory = new MediaFoundationH264EncoderFactory();
            await using IVideoEncoder encoder =
                await encoderFactory.CreateAsync(settings, CancellationToken.None)
                    .ConfigureAwait(false);
            await using var decoder = new MediaFoundationH264DecoderSink();
            var decodedFrames = new List<DecodedVideoFrame>();
            decoder.FrameDecoded += (_, eventArgs) => decodedFrames.Add(eventArgs.Frame);

            VideoConfigPacket? configuration = null;
            long frameDuration = 10_000_000 / settings.FramesPerSecond;
            for (var inputIndex = 0;
                inputIndex < 60 && decodedFrames.Count < targetDecodedFrames;
                inputIndex++)
            {
                byte[] bgra32 = CreateNativeDecodeInput(width, height, inputIndex);
                var captured = new CapturedFrame(
                    width,
                    height,
                    width * 4,
                    inputIndex * frameDuration,
                    CapturePixelFormat.Bgra8,
                    bgra32);
                EncodedVideoFrame? encoded = await encoder.EncodeAsync(
                        captured,
                        CancellationToken.None)
                    .ConfigureAwait(false);
                if (encoded is null)
                {
                    continue;
                }

                if (configuration is null)
                {
                    VideoEncoderConfiguration encoderConfiguration = encoded.Configuration ??
                        throw new InvalidDataException(
                            "The encoder did not configure the first H.264 keyframe.");
                    configuration = new VideoConfigPacket(
                        windowId,
                        PeelVideoCodec.H264,
                        checked((uint)encoderConfiguration.Width),
                        checked((uint)encoderConfiguration.Height),
                        encoderConfiguration.Timescale,
                        encoderConfiguration.NalUnitHeaderLength,
                        encoderConfiguration.SequenceParameterSet.ToArray(),
                        encoderConfiguration.PictureParameterSet.ToArray());
                    await decoder.ConfigureAsync(configuration, CancellationToken.None)
                        .ConfigureAwait(false);
                }

                await decoder.SubmitAsync(
                        new VideoFramePacket(
                            windowId,
                            encoded.IsKeyFrame,
                            encoded.Timestamp100Nanoseconds,
                            encoded.Duration100Nanoseconds,
                            encoded.Bytes.ToArray()),
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }

            True(decodedFrames.Count >= targetDecodedFrames,
                "The decoder did not produce enough frames.");
            long previousTimestamp = -1;
            foreach (DecodedVideoFrame decoded in decodedFrames)
            {
                Equal(width, decoded.PixelWidth);
                Equal(height, decoded.PixelHeight);
                Equal(width * 4, decoded.Stride);
                Equal(width * height * 4, decoded.Bgra32Pixels.Length);
                True(decoded.PresentationTimestamp > previousTimestamp,
                    "Decoded timestamps must increase.");
                var hasColor = false;
                for (var alpha = 3; alpha < decoded.Bgra32Pixels.Length; alpha += 4)
                {
                    hasColor |= decoded.Bgra32Pixels.Span[alpha - 3] != 0 ||
                        decoded.Bgra32Pixels.Span[alpha - 2] != 0 ||
                        decoded.Bgra32Pixels.Span[alpha - 1] != 0;
                    Equal((byte)255, decoded.Bgra32Pixels.Span[alpha]);
                }

                True(hasColor, "Decoded color channels must not be all zero.");

                previousTimestamp = decoded.PresentationTimestamp;
            }

            await VerifyWpfFramePresentationAsync(decodedFrames[^1]).ConfigureAwait(false);

            await decoder.ResetAsync(windowId, CancellationToken.None).ConfigureAwait(false);
            Console.WriteLine(
                "PASS native H.264 decode round-trip: " +
                $"{width}x{height}, frames={decodedFrames.Count}, stride={width * 4}, WPF=BGRA32");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"FAIL native H.264 decode round-trip: {exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static byte[] CreateNativeDecodeInput(int width, int height, int frameIndex)
    {
        var pixels = new byte[checked(width * height * 4)];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                int offset = ((y * width) + x) * 4;
                pixels[offset] = (byte)((x * 3 + frameIndex * 7) & 0xFF);
                pixels[offset + 1] = (byte)((y * 4 + frameIndex * 5) & 0xFF);
                pixels[offset + 2] = (byte)(((x + y) * 2 + frameIndex * 11) & 0xFF);
                pixels[offset + 3] = 255;
            }
        }

        return pixels;
    }

    private static async Task VerifyWpfFramePresentationAsync(DecodedVideoFrame frame)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                Type writerType = typeof(ClientVideoSocketSession).Assembly.GetType(
                    "Peel.Windows.Client.ViewModels.WpfDecodedFrameWriter",
                    throwOnError: true)!;
                MethodInfo write = writerType.GetMethod(
                    "Write",
                    BindingFlags.Static | BindingFlags.NonPublic) ??
                    throw new InvalidOperationException("The WPF frame writer is unavailable.");
                object bitmap = write.Invoke(null, [null, frame]) ??
                    throw new InvalidOperationException("The WPF frame writer returned no bitmap.");
                object reused = write.Invoke(null, [bitmap, frame]) ??
                    throw new InvalidOperationException("The WPF frame writer returned no reused bitmap.");
                True(ReferenceEquals(bitmap, reused),
                    "The WPF surface must reuse a same-size bitmap.");
                var pixels = new byte[checked(frame.Stride * frame.PixelHeight)];
                MethodInfo copyPixels = reused.GetType().GetMethod(
                    "CopyPixels",
                    BindingFlags.Instance | BindingFlags.Public,
                    binder: null,
                    types: [typeof(Array), typeof(int), typeof(int)],
                    modifiers: null) ??
                    throw new InvalidOperationException("The WPF bitmap copy boundary is unavailable.");
                _ = copyPixels.Invoke(reused, [pixels, frame.Stride, 0]);
                SequenceEqual(frame.Bgra32Pixels.ToArray(), pixels);
                completion.TrySetResult();
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        })
        {
            IsBackground = true,
            Name = "Peel WPF decoded-frame smoke",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
    }

    private static async Task HelloGateAndWindowListAsync()
    {
        var stale = Candidate("host-1", "stale.local", 1111);
        var fresh = Candidate("host-1", "fresh.local", 2222);
        var stream = new ScriptedDuplexStream(writeDelay: TimeSpan.FromMilliseconds(5));
        var fixture = new Fixture(fresh, stream);
        await using var session = fixture.CreateSession(pingInterval: TimeSpan.FromMilliseconds(20));

        var connect = session.ConnectAsync(stale, CancellationToken.None);
        await stream.WaitForWritesAsync(1);

        Equal(PeelConnectionState.Connecting, session.State);
        Equal(1, stream.Writes.Count);
        var hello = DeserializeWrite<ClientHelloMessage>(stream, 0);
        Equal(PeelMessageType.ClientHello, hello.Type);
        Equal(Fixture.PairingId, hello.PairingId);
        SequenceEqual(PeelHello.SortedCapabilities([PeelCapability.ClientVisibility, PeelCapability.H264Video, PeelCapability.BinaryVideoTransportV2, PeelCapability.PerWindowVideoConnections, PeelCapability.PairingRevocation, PeelCapability.InputFocus, PeelCapability.ExpandedKeyboard, PeelCapability.MachineStatus]), hello.Capabilities ?? []);
        Equal("fresh.local", fixture.Transport.Endpoints.Single().Host);
        Equal(Fixture.PairingId, fixture.Transport.Identities.Single());

        var hostHello = PeelJson.SerializeLine(PeelHello.CreateHost("Real Host"));
        stream.EnqueueRead(hostHello.AsSpan(0, 3).ToArray());
        stream.EnqueueRead(hostHello.AsSpan(3).ToArray());
        await connect.WaitAsync(TimeSpan.FromSeconds(2));

        Equal(PeelConnectionState.Connected, session.State);
        Equal(fresh, session.ConnectedHost);
        await stream.WaitForWritesAsync(2);
        Equal(PeelMessageType.ClientVisibility, ReadWriteType(stream, 1));

        var windowsChanged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.WindowsChanged += (_, _) => windowsChanged.TrySetResult();
        await ((IWindowListService)session).StartAsync(CancellationToken.None);
        await stream.WaitForWritesAsync(3);
        Equal(PeelMessageType.RequestWindowList, ReadWriteType(stream, 2));

        stream.EnqueueRead(PeelJson.SerializeLine(new WindowListMessage(
            [new PeelWindow(42, "Finder", "Downloads", 1280, 720)])));
        await windowsChanged.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var window = session.Windows.Single();
        Equal(42u, window.Id);
        Equal("Downloads", window.Title);
        Equal("Finder", window.OwnerName);
        Equal(1280, window.PixelWidth);
        await stream.WaitForWritesAsync(4);
        True(stream.MaximumConcurrentWrites == 1, "All hello, visibility, request, and ping writes must be serialized.");
        foreach (var write in SnapshotWrites(stream))
        {
            _ = PeelJson.ReadEnvelope(TrimLine(write));
        }
    }

    private static async Task IncompatibleHostHelloFailsClosedAsync()
    {
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(Candidate("host-1", "fresh.local", 2222), stream);
        await using var session = fixture.CreateSession();

        var connect = session.ConnectAsync(fixture.Resolver.Current, CancellationToken.None);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(new HostHelloMessage(
            "Old Host",
            ProtocolVersion: 1,
            MinimumSupportedProtocolVersion: 1)));

        await ThrowsAsync<InvalidDataException>(() => connect);
        Equal(PeelConnectionState.Error, session.State);
        Equal<HostCandidate?>(null, session.ConnectedHost);
        Equal(1, stream.Writes.Count);
    }

    private static async Task HostIdentityMismatchFailsBeforeTlsAsync()
    {
        var host = Candidate("host-a", "host.local", 3333);
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(host, stream);
        var maliciousStore = new FixedPairedHostCredentialStore(
            new PairedHostCredential("host-b", Fixture.PairingId, Fixture.Key));
        await using var session = fixture.CreateSession(credentialStore: maliciousStore);

        await ThrowsAsync<InvalidDataException>(() =>
            session.ConnectAsync(host, CancellationToken.None));

        Equal(0, fixture.Transport.Endpoints.Count);
        Equal(PeelConnectionState.Error, session.State);
    }

    private static async Task MissingCredentialFailsBeforeTlsAsync()
    {
        var host = Candidate("host-a", "host.local", 3334);
        var fixture = new Fixture(host, new ScriptedDuplexStream());
        await using var session = fixture.CreateSession(
            credentialStore: new FixedPairedHostCredentialStore(null));

        await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
            session.ConnectAsync(host, CancellationToken.None));

        Equal(0, fixture.Transport.Endpoints.Count);
        Equal(PeelConnectionState.Error, session.State);
    }

    private static async Task HostileNdjsonFailsClosedAsync()
    {
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(Candidate("host-1", "host.local", 4444), stream);
        await using var session = fixture.CreateSession(maximumLineBytes: 256);
        await ConnectAsync(session, stream, fixture.Resolver.Current);

        stream.EnqueueRead(Enumerable.Repeat((byte)'x', 257).ToArray());
        await WaitUntilAsync(() => session.State == PeelConnectionState.Error);

        Equal(1, fixture.Credentials.Count);
        Equal<HostCandidate?>(null, session.ConnectedHost);
    }

    private static async Task IoPreservesCredentialAndFreshResolveAsync()
    {
        var first = Candidate("host-1", "first.local", 5001);
        var firstStream = new ScriptedDuplexStream();
        var secondStream = new ScriptedDuplexStream();
        var fixture = new Fixture(first, firstStream, secondStream);
        await using var session = fixture.CreateSession();

        await ConnectAsync(session, firstStream, first);
        firstStream.CompleteReads();
        await WaitUntilAsync(() => session.State == PeelConnectionState.Error);
        Equal(1, fixture.Credentials.Count);

        var second = Candidate("host-1", "second.local", 5002);
        fixture.Resolver.Current = second;
        var reconnect = session.ConnectAsync(first, CancellationToken.None);
        await secondStream.WaitForWritesAsync(1);
        secondStream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Moved Host")));
        await reconnect.WaitAsync(TimeSpan.FromSeconds(2));

        Equal(2, fixture.Resolver.CallCount);
        Equal("first.local", fixture.Transport.Endpoints[0].Host);
        Equal("second.local", fixture.Transport.Endpoints[1].Host);
        Equal(second, session.ConnectedHost);
        Equal(1, fixture.Credentials.Count);
    }

    private static async Task ConnectCancellationAsync()
    {
        var host = Candidate("host-1", "host.local", 6001);
        var fixture = new Fixture(host, new ScriptedDuplexStream())
        {
            Transport = new FakeTransportFactory(blockConnect: true)
        };
        await using var session = fixture.CreateSession();
        using var cancellation = new CancellationTokenSource();

        var connect = session.ConnectAsync(host, cancellation.Token);
        await WaitUntilAsync(() => fixture.Transport.Endpoints.Count == 1);
        cancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => connect);

        Equal(PeelConnectionState.Disconnected, session.State);
        Equal<HostCandidate?>(null, session.ConnectedHost);
    }

    private static async Task UnavailableReceiverFailsClosedAsync()
    {
        var services = new UnavailableClientServices("Receiver adapters are not configured.");
        IStreamControlService streams = services;
        Equal(0, services.DiscoveredHosts.Count);
        Equal(0, services.SavedHosts.Count);
        Equal(0, services.Windows.Count);
        await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
            services.StartAsync(CancellationToken.None));
        await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
            services.ConnectAsync(Candidate("host-1", "host.local", 7001), CancellationToken.None));
        await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
            streams.StartAsync(new RemoteWindowDescriptor(1, "Fixture", "Test", 640, 480),
                CancellationToken.None));
        Equal(PeelConnectionState.Error, services.State);
        Equal(PeelStreamState.Error, streams.State);
        Equal<HostCandidate?>(null, services.ConnectedHost);
        Equal<uint?>(null, services.StreamingWindowId);
    }

    private static async Task HostStartupFailureRetriesFreshAsync()
    {
        var created = new List<FakeHostRuntimeInstance>();
        await using var lifecycle = new HostRuntimeLifecycleController(() =>
        {
            var next = new FakeHostRuntimeInstance
            {
                ThrowWhenStarting = created.Count == 0,
            };
            created.Add(next);
            return next;
        });

        await lifecycle.StartAsync(CancellationToken.None);
        Equal(1, created.Count);
        True(created[0].IsDisposed,
            "A failed Host runtime must be disposed before recovery is offered.");
        True(!lifecycle.State.IsRunning, "A failed Host start must remain visibly offline.");
        True(lifecycle.State.Error?.Contains("failed", StringComparison.OrdinalIgnoreCase) == true,
            "A failed Host start must preserve a useful error for the retry surface.");

        await lifecycle.RetryAsync(CancellationToken.None);
        Equal(2, created.Count);
        True(created[1].IsRunning, "Retry must start a fresh Host runtime.");
        True(!created[1].IsInputEnabled, "Retry must keep remote input disabled.");
        True(lifecycle.State.IsRunning, "Retry must publish the recovered Host state.");
        Equal<string?>(null, lifecycle.State.Error);
    }

    private static async Task HostInitiallyLockedSessionDefersRuntimeAsync()
    {
        var created = new List<FakeHostRuntimeInstance>();
        var reads = 0;
        await using var lifecycle = new HostRuntimeLifecycleController(
            () =>
            {
                var next = new FakeHostRuntimeInstance();
                created.Add(next);
                return next;
            },
            () =>
            {
                reads++;
                return WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(
                    level: 1,
                    reportedSessionId: 7,
                    sessionState: 0,
                    sessionFlags: 0,
                    expectedSessionId: 7);
            });

        await lifecycle.StartAsync();
        Equal(0, created.Count);
        Equal(HostRuntimePauseReason.SessionLocked, lifecycle.State.PauseReason);
        True(!lifecycle.State.IsRunning, "An already-locked session must never open Host listeners.");
        Equal<int?>(null, lifecycle.State.ControlPort);
        Equal<int?>(null, lifecycle.State.PairingPort);
        Throws<InvalidOperationException>(() => lifecycle.SetInputEnabled(true));

        await lifecycle.RetryAsync();
        await lifecycle.RestartAsync();
        Equal(0, created.Count);
        await lifecycle.SetPausedAsync(HostRuntimePauseReason.SystemSuspended, paused: true);
        await lifecycle.SetPausedAsync(HostRuntimePauseReason.SessionLocked, paused: false);
        Equal(0, created.Count);
        Equal(HostRuntimePauseReason.SystemSuspended, lifecycle.State.PauseReason);

        await lifecycle.SetPausedAsync(HostRuntimePauseReason.SystemSuspended, paused: false);
        Equal(1, created.Count);
        True(lifecycle.State.IsRunning, "Unlock and resume must start the first fresh Host runtime.");
        True(!lifecycle.State.IsInputEnabled, "Initial unlock must keep remote input off.");
        await lifecycle.RestartAsync();
        Equal(2, created.Count);
        Equal(1, reads);
        True(lifecycle.State.IsRunning,
            "A later restart must not replay the old locked startup snapshot after unlock.");
    }

    private static async Task HostInitialSessionFailureCannotBeBypassedAsync()
    {
        Func<bool>[] failedQueries =
        [
            static () => throw new Win32Exception(5, "The fixture session query was denied."),
            static () => WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, -1, 7),
            static () => throw new InvalidOperationException("The fixture session monitor is unavailable."),
        ];

        foreach (Func<bool> failedQuery in failedQueries)
        {
            var created = new List<FakeHostRuntimeInstance>();
            var reads = 0;
            var queryFails = true;
            await using var lifecycle = new HostRuntimeLifecycleController(
                () =>
                {
                    var next = new FakeHostRuntimeInstance();
                    created.Add(next);
                    return next;
                },
                () =>
                {
                    reads++;
                    return queryFails ? failedQuery() : false;
                });

            await ThrowsAsync<Exception>(() => lifecycle.StartAsync());
            await ThrowsAsync<Exception>(() => lifecycle.RetryAsync());
            await lifecycle.RestartAsync();
            await lifecycle.SetPausedAsync(HostRuntimePauseReason.SessionLocked, paused: false);
            Equal(0, created.Count);
            Equal(2, reads);
            True(!lifecycle.State.IsRunning, "Failed initial monitoring must keep every start route offline.");
            True(!lifecycle.State.IsInputEnabled, "Failed initial monitoring must keep input off.");
            True(lifecycle.State.Error is not null, "Failed initial monitoring must expose a retry error.");

            queryFails = false;
            await lifecycle.RestartAsync();
            Equal(0, created.Count);
            Equal(2, reads);
            True(lifecycle.State.Error is not null,
                "A no-op network restart must retain the failed startup error and visible Retry action.");
            await lifecycle.RetryAsync();
            Equal(3, reads);
            Equal(1, created.Count);
            True(lifecycle.State.IsRunning,
                "A successful unlocked query may recover a previously failed startup.");
            True(!lifecycle.State.IsInputEnabled, "Recovered startup must keep input off.");
            Equal<string?>(null, lifecycle.State.Error);
        }
    }

    private static void WindowsInitialSessionSnapshotValidatesState()
    {
        True(WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, 0, 7),
            "Windows 10+ lock flag zero means locked even while the session is active.");
        True(!WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, 1, 7),
            "Windows 10+ unlock flag one means unlocked.");
        Throws<InvalidDataException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(2, 7, 0, 1, 7));
        Throws<InvalidDataException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 8, 0, 1, 7));
        Throws<InvalidDataException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, 1, -1));
        Throws<InvalidDataException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, -1, 7));
        Throws<InvalidDataException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 0, 2, 7));
        Throws<InvalidOperationException>(() =>
            WindowsHostSystemLifecycleMonitor.ClassifyInitialSessionLocked(1, 7, 4, 1, 7));
    }

    private static void SingleInstanceLeaseExcludesSecondApp()
    {
        string directory = Path.Combine(
            Path.GetTempPath(),
            "Peel.Windows.Client.Tests",
            Guid.NewGuid().ToString("N"));
        string filePath = Path.Combine(directory, "app-instance.lock");
        try
        {
            using SingleInstanceLease first = SingleInstanceLease.TryAcquire(filePath) ??
                throw new InvalidOperationException("The first app must acquire the instance lease.");
            using SingleInstanceLease? second = SingleInstanceLease.TryAcquire(filePath);
            True(second is null, "A second app must not acquire the active instance lease.");

            first.Dispose();
            using SingleInstanceLease replacement = SingleInstanceLease.TryAcquire(filePath) ??
                throw new InvalidOperationException("A replacement app must acquire a released lease.");
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    private static void TrayClosePolicyHidesUntilExit()
    {
        var policy = new TrayWindowClosePolicy();
        True(policy.ShouldHideWindow, "Ordinary window close must keep the background Host alive.");
        policy.AllowExit();
        True(!policy.ShouldHideWindow, "Explicit exit must allow the real window teardown.");
        policy.AllowExit();
        True(!policy.ShouldHideWindow, "Exit permission must remain idempotent.");
    }

    private static void LaunchAtLoginValueIsExactAndReversible()
    {
        string registryPath = $@"Software\Zephyr Studios\Peel\Tests\{Guid.NewGuid():N}";
        const string valueName = "Peel launch test";
        const string executablePath = @"C:\Program Files\Peel Test\Peel.Windows.exe";
        try
        {
            var service = new WindowsLaunchAtLoginService(
                executablePath,
                registryPath,
                valueName);
            True(!service.IsEnabled, "Launch at login must default off.");
            Equal(
                "\"C:\\Program Files\\Peel Test\\Peel.Windows.exe\" --background",
                service.CommandLine);
            service.SetEnabled(true);
            True(service.IsEnabled, "The exact current executable command must enable startup.");
            using (RegistryKey? key = Registry.CurrentUser.OpenSubKey(registryPath, writable: false))
            {
                Equal(
                    service.CommandLine,
                    key?.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames));
            }

            True(WindowsLaunchAtLoginService.IsBackgroundStart(["--BACKGROUND"]),
                "The registered background argument must be case-insensitive.");
            True(!WindowsLaunchAtLoginService.IsBackgroundStart([]),
                "A normal launch must remain visible.");

            service.SetEnabled(false);
            True(!service.IsEnabled, "Disabling startup must delete Peel's owned value.");
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(registryPath, throwOnMissingSubKey: false);
        }
    }

    private static async Task HostLifecyclePausesAndRestartsAsync()
    {
        var created = new List<FakeHostRuntimeInstance>();
        await using var lifecycle = new HostRuntimeLifecycleController(() =>
        {
            var next = new FakeHostRuntimeInstance();
            created.Add(next);
            return next;
        });

        await lifecycle.StartAsync(CancellationToken.None);
        Equal(1, created.Count);
        True(created[0].IsRunning, "The first Host runtime must start.");
        True(lifecycle.State.IsRunning, "The lifecycle must report the running Host.");
        created[0].IsClientVisible = true;
        created[0].IsPreventingSleep = true;
        HostRuntimeLifecycleState awakeState = lifecycle.State;
        True(awakeState.IsClientVisible,
            "The lifecycle must publish the active client's visibility.");
        True(awakeState.IsPreventingSleep,
            "The lifecycle must publish the Windows awake-request state.");
        Equal<string?>(null, awakeState.AwakeError);
        lifecycle.SetInputEnabled(true);
        True(created[0].IsInputEnabled, "The explicit local gate must enable input.");

        Task lockPause = lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SessionLocked,
            paused: true,
            CancellationToken.None);
        True(!created[0].IsInputEnabled,
            "Session lock must close the input gate before asynchronous teardown.");
        await lockPause;
        True(created[0].IsDisposed, "Session lock must dispose the active Host runtime.");
        Equal(HostRuntimePauseReason.SessionLocked, lifecycle.State.PauseReason);
        True(!lifecycle.State.IsRunning, "A paused Host must report offline.");
        Throws<InvalidOperationException>(() => lifecycle.SetInputEnabled(true));

        await lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SystemSuspended,
            paused: true,
            CancellationToken.None);
        await lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SessionLocked,
            paused: false,
            CancellationToken.None);
        Equal(1, created.Count);
        Equal(HostRuntimePauseReason.SystemSuspended, lifecycle.State.PauseReason);

        await lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SystemSuspended,
            paused: false,
            CancellationToken.None);
        Equal(2, created.Count);
        True(created[1].IsRunning, "Clearing every pause reason must start a fresh runtime.");
        True(!created[1].IsInputEnabled, "A restarted runtime must keep input off.");
        True(lifecycle.State.IsRunning, "The restarted Host must report running.");
        Equal<HostRuntimePauseReason?>(null, lifecycle.State.PauseReason);

        lifecycle.SetInputEnabled(true);
        Task suspendPause = lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SystemSuspended,
            paused: true,
            CancellationToken.None);
        True(!created[1].IsInputEnabled,
            "Suspend must close the input gate before asynchronous teardown.");
        await suspendPause;
        True(created[1].IsDisposed, "Suspend must dispose the active Host runtime.");
        await lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SystemSuspended,
            paused: false,
            CancellationToken.None);
        Equal(3, created.Count);
        True(created[2].IsRunning, "Resume must start another fresh Host runtime.");
        True(!created[2].IsInputEnabled, "Resume must never restore remote input.");

        lifecycle.SetInputEnabled(true);
        created[2].ThrowWhenDisablingInput = true;
        await lifecycle.SetPausedAsync(
            HostRuntimePauseReason.SessionLocked,
            paused: true,
            CancellationToken.None);
        True(created[2].IsDisposed,
            "A failed input-gate call must not prevent fail-closed runtime teardown.");
    }

    private static void WindowsLifecycleMessagesClassifyFailClosed()
    {
        Equal(
            HostSystemLifecycleEvent.SessionLocked,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(
                WindowsHostSystemLifecycleMonitor.SessionChangeMessage,
                WindowsHostSystemLifecycleMonitor.SessionLock));
        Equal(
            HostSystemLifecycleEvent.SessionUnlocked,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(
                WindowsHostSystemLifecycleMonitor.SessionChangeMessage,
                WindowsHostSystemLifecycleMonitor.SessionUnlock));
        Equal(
            HostSystemLifecycleEvent.Suspending,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(
                WindowsHostSystemLifecycleMonitor.PowerBroadcastMessage,
                WindowsHostSystemLifecycleMonitor.PowerSuspend));
        Equal(
            HostSystemLifecycleEvent.Resumed,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(
                WindowsHostSystemLifecycleMonitor.PowerBroadcastMessage,
                WindowsHostSystemLifecycleMonitor.PowerResumeAutomatic));
        Equal<HostSystemLifecycleEvent?>(
            null,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(
                WindowsHostSystemLifecycleMonitor.PowerBroadcastMessage,
                0xFFFF));
        Equal<HostSystemLifecycleEvent?>(
            null,
            WindowsHostSystemLifecycleMonitor.ClassifyMessage(0x1234, 0));
    }

    private static async Task HostNetworkRestartIsFailClosedAsync()
    {
        var created = new List<FakeHostRuntimeInstance>();
        await using var lifecycle = new HostRuntimeLifecycleController(() =>
        {
            var next = new FakeHostRuntimeInstance();
            created.Add(next);
            return next;
        });

        await lifecycle.StartAsync(CancellationToken.None);
        lifecycle.SetInputEnabled(true);
        var releaseDispose = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        created[0].DisposeBlocker = releaseDispose;

        Task firstRestart = lifecycle.RestartAsync(CancellationToken.None);
        await created[0].DisposeStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        True(!created[0].IsInputEnabled,
            "A network restart must close input before waiting for runtime teardown.");
        True(!lifecycle.State.IsRunning,
            "A pending network generation must not expose the stale runtime.");
        Throws<InvalidOperationException>(() => lifecycle.SetInputEnabled(true));
        Task coalescedRestart = lifecycle.RestartAsync(CancellationToken.None);
        releaseDispose.TrySetResult();
        await Task.WhenAll(firstRestart, coalescedRestart).WaitAsync(TimeSpan.FromSeconds(2));

        Equal(2, created.Count);
        True(created[0].IsDisposed, "The old network generation must be disposed.");
        True(created[1].IsRunning, "The coalesced network generation must be running.");
        True(!created[1].IsInputEnabled, "Network recovery must never restore remote input.");
        True(lifecycle.State.IsRunning, "The lifecycle must publish the recovered Host.");
        True(lifecycle.State.ControlPort is not null, "The recovered control listener must be visible.");
        True(lifecycle.State.PairingPort is not null, "The recovered pairing listener must be visible.");
    }

    private static async Task HostPairedDeviceRevocationRestartsFailClosedAsync()
    {
        var pairedClients = new List<HostPairedClient>
        {
            new(
                "paired-client-to-forget",
                "Living Room iPad",
                "device-to-forget",
                DateTimeOffset.UtcNow),
        };
        var created = new List<FakeHostRuntimeInstance>();
        await using var lifecycle = new HostRuntimeLifecycleController(() =>
        {
            var next = new FakeHostRuntimeInstance(pairedClients);
            created.Add(next);
            return next;
        });

        await lifecycle.StartAsync(CancellationToken.None);
        Equal(1, lifecycle.State.PairedClients.Count);
        lifecycle.SetInputEnabled(true);
        True(await lifecycle.RevokePairedClientAsync(
            "paired-client-to-forget",
            CancellationToken.None),
            "The selected paired device must be removed.");

        Equal(2, created.Count);
        True(created[0].IsDisposed,
            "Revocation must dispose the generation that accepted the forgotten credential.");
        Equal(0, pairedClients.Count);
        True(lifecycle.State.IsRunning,
            "Revocation must restore a fresh secure Host generation.");
        Equal(0, lifecycle.State.PairedClients.Count);
        True(!lifecycle.State.IsInputEnabled,
            "Revocation must never restore remote input.");
    }

    private static void WindowsNetworkNotificationsCoalesce()
    {
        var scheduled = new List<Action>();
        var callbackCount = 0;
        using var monitor = new WindowsHostNetworkMonitor(
            () => callbackCount++,
            scheduled.Add);

        monitor.NotifyAddressChangedForTesting();
        monitor.NotifyAddressChangedForTesting();
        Equal(1, scheduled.Count);
        scheduled[0]();
        Equal(1, callbackCount);

        monitor.NotifyAddressChangedForTesting();
        Equal(2, scheduled.Count);
        monitor.Dispose();
        scheduled[1]();
        Equal(1, callbackCount);
    }

    private static void H264PayloadsConvertToAnnexB()
    {
        var configuration = new VideoConfigPacket(
            9,
            PeelVideoCodec.H264,
            64,
            64,
            10_000_000,
            4,
            [0x67, 0x42],
            [0x68, 0xCE]);
        var frame = new VideoFramePacket(
            9,
            true,
            100,
            10,
            [0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x41, 0xCC]);

        SequenceEqual(
            new byte[]
            {
                0, 0, 0, 1, 0x67, 0x42,
                0, 0, 0, 1, 0x68, 0xCE,
                0, 0, 0, 1, 0x65, 0xAA, 0xBB,
                0, 0, 0, 1, 0x41, 0xCC,
            },
            H264LengthPrefixed.ConvertFrame(configuration, frame));
        SequenceEqual(
            new byte[]
            {
                0, 0, 0, 1, 0x67, 0x42,
                0, 0, 0, 1, 0x68, 0xCE,
            },
            H264LengthPrefixed.CreateSequenceHeader(configuration));
        Throws<InvalidDataException>(() => H264LengthPrefixed.ConvertFrame(
            configuration,
            frame with { Payload = [0, 0, 0, 9, 0x65] }));
    }

    private static void LatestFrameMailboxDropsSupersededWork()
    {
        var first = new DecodedVideoFrame(2, 2, 8, new byte[16], 1);
        var latest = first with { PresentationTimestamp = 2 };
        var mailbox = new LatestDecodedFrameMailbox();

        True(mailbox.Publish(first), "The first frame must schedule presentation.");
        True(!mailbox.Publish(latest), "A pending presentation must not queue twice.");
        True(ReferenceEquals(latest, mailbox.TakeLatest()),
            "Only the newest pending frame may be presented.");
        True(!mailbox.CompletePresentation(),
            "Presentation should quiesce when no newer frame is pending.");

        True(mailbox.Publish(first), "A quiesced mailbox must schedule again.");
        _ = mailbox.TakeLatest();
        True(mailbox.Publish(latest) == false,
            "A frame published during presentation must reuse the scheduled slot.");
        True(mailbox.CompletePresentation(),
            "A newer frame must schedule one follow-up presentation.");
        True(ReferenceEquals(latest, mailbox.TakeLatest()),
            "The follow-up presentation must receive the newest frame.");
        True(!mailbox.CompletePresentation(),
            "The mailbox must become idle after the latest frame is consumed.");
    }

    private static void Nv12OutputConvertsToBgra32()
    {
        byte[] converted = Nv12ToBgra32Converter.Convert(
            [82, 82, 82, 82, 90, 240],
            2,
            2);
        Equal(16, converted.Length);
        for (var offset = 0; offset < converted.Length; offset += 4)
        {
            SequenceEqual(new byte[] { 0, 1, 255, 255 }, converted.AsSpan(offset, 4).ToArray());
        }

        Throws<InvalidDataException>(() => Nv12ToBgra32Converter.Convert(new byte[5], 2, 2));
        Throws<InvalidDataException>(() => Nv12ToBgra32Converter.Convert(new byte[9], 3, 2));
    }

    private static async Task VideoHelloThenBinaryAsync()
    {
        var stale = Candidate("host-video", "stale-video.local", 8101);
        var fresh = Candidate("host-video", "fresh-video.local", 8102);
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(fresh, stream);
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder);

        await session.StartAsync(
            VideoRequest(stale.StableHostId, 91, PeelVideoCodec.H264),
            CancellationToken.None);

        Equal(ClientVideoSocketState.WaitingForConfiguration, session.State);
        Equal(91u, session.WindowId);
        Equal(1, stream.Writes.Count);
        var hello = DeserializeWrite<VideoStreamHelloMessage>(stream, 0);
        Equal(PeelMessageType.VideoStreamHello, hello.Type);
        Equal(91u, hello.WindowId);
        Equal(Fixture.PairingId, hello.PairingId);
        Equal(PeelProtocol.CurrentProtocolVersion, hello.ProtocolVersion);
        SequenceEqual(
            PeelHello.SortedCapabilities(
                [PeelCapability.BinaryVideoTransportV2, PeelCapability.H264Video, PeelCapability.PerWindowVideoConnections]),
            hello.Capabilities ?? []);
        Equal("fresh-video.local", fixture.Transport.Endpoints.Single().Host);

        var config = new VideoConfigPacket(91, PeelVideoCodec.H264, 1920, 1080, 600, 4, [1], [2]);
        var preKeyframe = new VideoFramePacket(91, false, 1, 1, [3]);
        var keyframe = new VideoFramePacket(91, true, 2, 1, [4]);
        var delta = new VideoFramePacket(91, false, 3, 1, [5]);
        var resizedConfig = new VideoConfigPacket(
            91,
            PeelVideoCodec.H264,
            1280,
            720,
            600,
            4,
            [6],
            [7]);
        var resizedPreKeyframe = new VideoFramePacket(91, false, 4, 1, [8]);
        var resizedKeyframe = new VideoFramePacket(91, true, 5, 1, [9]);
        var resizedDelta = new VideoFramePacket(91, false, 6, 1, [10]);
        var binary = config.Encode()
            .Concat(preKeyframe.Encode())
            .Concat(keyframe.Encode())
            .Concat(delta.Encode())
            .Concat(resizedConfig.Encode())
            .Concat(resizedPreKeyframe.Encode())
            .Concat(resizedKeyframe.Encode())
            .Concat(resizedDelta.Encode())
            .ToArray();
        stream.EnqueueRead(binary.AsSpan(0, 11).ToArray());
        stream.EnqueueRead(binary.AsSpan(11).ToArray());

        await WaitUntilAsync(() => decoder.Configurations.Count == 2 && decoder.Frames.Count == 4);
        Equal(ClientVideoSocketState.Streaming, session.State);
        Equal(true, decoder.Frames[0].IsKeyframe);
        Equal(false, decoder.Frames[1].IsKeyframe);
        Equal(1280U, decoder.Configurations[1].Width);
        Equal(720U, decoder.Configurations[1].Height);
        Equal(true, decoder.Frames[2].IsKeyframe);
        Equal(false, decoder.Frames[3].IsKeyframe);
        Equal(1, stream.Writes.Count);
    }

    private static async Task VideoNegotiationFailsBeforeTlsAsync()
    {
        var host = Candidate("host-video", "video.local", 8201);
        var fixture = new Fixture(host, new ScriptedDuplexStream());
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder);

        var incompatible = VideoRequest(host.StableHostId, 1, PeelVideoCodec.H264) with
        {
            RemoteProtocolVersion = 1,
            RemoteMinimumSupportedProtocolVersion = 1,
        };
        await ThrowsAsync<InvalidDataException>(() =>
            session.StartAsync(incompatible, CancellationToken.None));

        var missingCapability = VideoRequest(host.StableHostId, 1, PeelVideoCodec.H264) with
        {
            RemoteCapabilities = new HashSet<string>(StringComparer.Ordinal)
            {
                PeelCapability.H264Video,
            },
        };
        await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
            session.StartAsync(missingCapability, CancellationToken.None));

        Equal(0, fixture.Transport.Endpoints.Count);
    }

    private static async Task WrongVideoIdentityFailsClosedAsync()
    {
        var host = Candidate("host-video", "video.local", 8301);
        var wrongWindowStream = new ScriptedDuplexStream();
        var wrongCodecStream = new ScriptedDuplexStream();
        var fixture = new Fixture(host, wrongWindowStream, wrongCodecStream);
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder);

        await session.StartAsync(VideoRequest(host.StableHostId, 7, PeelVideoCodec.H264), CancellationToken.None);
        wrongWindowStream.EnqueueRead(
            new VideoConfigPacket(8, PeelVideoCodec.H264, 640, 480, 600, 4, [1], [2]).Encode());
        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);
        Equal(0, decoder.Configurations.Count);

        await session.StartAsync(VideoRequest(host.StableHostId, 7, PeelVideoCodec.H264), CancellationToken.None);
        wrongCodecStream.EnqueueRead(
            new VideoConfigPacket(7, PeelVideoCodec.Hevc, 640, 480, 600, 4, [1], [2], [3]).Encode());
        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);
        Equal(0, decoder.Configurations.Count);
    }

    private static async Task HostileVideoLengthFailsClosedAsync()
    {
        var host = Candidate("host-video", "video.local", 8401);
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(host, stream);
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder, maximumPacketBytes: 128);
        await session.StartAsync(VideoRequest(host.StableHostId, 9, PeelVideoCodec.H264), CancellationToken.None);

        var hostileHeader = new byte[VideoFramePacket.HeaderLength];
        hostileHeader[0] = (byte)PeelBinaryPacketType.VideoFrame;
        BinaryPrimitives.WriteUInt32LittleEndian(hostileHeader.AsSpan(1, 4), 9);
        BinaryPrimitives.WriteUInt32LittleEndian(hostileHeader.AsSpan(22, 4), 1024);
        stream.EnqueueRead(hostileHeader);

        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);
        Equal(0, decoder.Frames.Count);
        Equal(1, fixture.Credentials.Count);
    }

    private static async Task HostileVideoMetadataFailsClosedAsync()
    {
        var host = Candidate("host-video", "video.local", 8402);
        var invalidConfigStream = new ScriptedDuplexStream();
        var negativeTimestampStream = new ScriptedDuplexStream();
        var overflowTimestampStream = new ScriptedDuplexStream();
        var fixture = new Fixture(
            host,
            invalidConfigStream,
            negativeTimestampStream,
            overflowTimestampStream);
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder);

        await session.StartAsync(
            VideoRequest(host.StableHostId, 12, PeelVideoCodec.H264),
            CancellationToken.None);
        invalidConfigStream.EnqueueRead(
            new VideoConfigPacket(12, PeelVideoCodec.H264, 640, 480, 600, 3, [0x67], [0x68])
                .Encode());
        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);

        byte[] validConfiguration =
            new VideoConfigPacket(12, PeelVideoCodec.H264, 640, 480, 600, 4, [0x67], [0x68])
                .Encode();
        await session.StartAsync(
            VideoRequest(host.StableHostId, 12, PeelVideoCodec.H264),
            CancellationToken.None);
        negativeTimestampStream.EnqueueRead(validConfiguration
            .Concat(new VideoFramePacket(12, true, -1, 1, [1]).Encode())
            .ToArray());
        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);

        await session.StartAsync(
            VideoRequest(host.StableHostId, 12, PeelVideoCodec.H264),
            CancellationToken.None);
        overflowTimestampStream.EnqueueRead(validConfiguration
            .Concat(new VideoFramePacket(12, true, long.MaxValue, 1, [1]).Encode())
            .ToArray());
        await WaitUntilAsync(() => session.State == ClientVideoSocketState.Error);

        Equal(2, decoder.Configurations.Count);
        Equal(0, decoder.Frames.Count);
    }

    private static async Task VideoConnectCancellationAsync()
    {
        var host = Candidate("host-video", "video.local", 8501);
        var fixture = new Fixture(host, new ScriptedDuplexStream())
        {
            Transport = new FakeTransportFactory(blockConnect: true),
        };
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        await using var session = fixture.CreateVideoSession(decoder);
        using var cancellation = new CancellationTokenSource();

        var start = session.StartAsync(
            VideoRequest(host.StableHostId, 11, PeelVideoCodec.H264),
            cancellation.Token);
        await WaitUntilAsync(() => fixture.Transport.Endpoints.Count == 1);
        cancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => start);

        Equal(ClientVideoSocketState.Stopped, session.State);
        Equal<uint?>(null, session.WindowId);
    }

    private static async Task StaleVideoGenerationIsSuppressedAsync()
    {
        var host = Candidate("host-video", "video.local", 8451);
        var stream = new ScriptedDuplexStream();
        var fixture = new Fixture(host, stream);
        var decoder = new BlockingVideoDecoderSink();
        await using var session = fixture.CreateVideoSession(decoder);
        await session.StartAsync(VideoRequest(host.StableHostId, 10, PeelVideoCodec.H264), CancellationToken.None);

        var config = new VideoConfigPacket(10, PeelVideoCodec.H264, 640, 480, 600, 4, [1], [2]);
        var keyframe = new VideoFramePacket(10, true, 1, 1, [3]);
        stream.EnqueueRead(config.Encode().Concat(keyframe.Encode()).ToArray());
        await decoder.SubmitStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var stop = session.StopAsync(CancellationToken.None);
        await Task.Delay(25);
        True(!stop.IsCompleted, "Stop must wait for an in-flight decoder delivery before reset.");
        decoder.ReleaseSubmit.TrySetResult();
        await stop.WaitAsync(TimeSpan.FromSeconds(2));

        Equal(ClientVideoSocketState.Stopped, session.State);
        Equal<uint?>(null, session.WindowId);
    }

    private static async Task StreamControllerOrdersWireAsync()
    {
        var operations = new ConcurrentQueue<string>();
        var host = Candidate("host-orchestration", "orchestration.local", 8601);
        var controlStream = new ScriptedDuplexStream(
            onWrite: bytes => operations.Enqueue($"control:{ReadType(bytes)}"));
        var videoStream = new ScriptedDuplexStream(
            onWrite: bytes => operations.Enqueue($"video:{ReadType(bytes)}"),
            onDispose: () => operations.Enqueue("video:disposed"));
        var fixture = new Fixture(host, controlStream, videoStream);
        await using var control = fixture.CreateSession();
        await ConnectAndPublishWindowAsync(control, controlStream, host, windowId: 61);

        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        var video = fixture.CreateVideoSession(decoder);
        await using var controller = new ClientStreamController(
            control,
            control,
            control,
            video,
            PeelVideoCodec.H264);
        var window = control.Windows.Single();

        await controller.StartAsync(window, CancellationToken.None);
        Equal(PeelStreamState.Starting, controller.State);
        Equal(61u, controller.StreamingWindowId);
        var startRequest = FindControlRequest(controlStream, PeelMessageType.StartStream);
        Equal(61u, startRequest.WindowId);
        AssertBefore(operations, "video:videoStreamHello", "control:startStream");

        videoStream.EnqueueRead(
            new VideoConfigPacket(61, PeelVideoCodec.H264, 1280, 720, 600, 4, [1], [2])
                .Encode()
                .Concat(new VideoFramePacket(61, true, 1, 1, [3]).Encode())
                .ToArray());
        await WaitUntilAsync(() => controller.State == PeelStreamState.Streaming);

        videoStream.CompleteReads();
        await WaitUntilAsync(() => controller.State == PeelStreamState.Error);
        Equal(1, fixture.Credentials.Count);
        await controller.StopAsync(CancellationToken.None);

        var stopRequest = FindControlRequest(controlStream, PeelMessageType.StopStream);
        Equal(61u, stopRequest.WindowId);
        AssertBefore(operations, "video:disposed", "control:stopStream");
        Equal(PeelStreamState.Stopped, controller.State);
    }

    private static async Task StreamControllerReconnectAsync()
    {
        var first = Candidate("host-reconnect", "first-reconnect.local", 8701);
        var second = Candidate("host-reconnect", "second-reconnect.local", 8702);
        var firstControl = new ScriptedDuplexStream();
        var firstVideo = new ScriptedDuplexStream();
        var secondControl = new ScriptedDuplexStream();
        var secondVideo = new ScriptedDuplexStream();
        var fixture = new Fixture(first, firstControl, firstVideo, secondControl, secondVideo);
        await using var control = fixture.CreateSession();
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        var video = fixture.CreateVideoSession(decoder);
        await using var controller = new ClientStreamController(
            control,
            control,
            control,
            video,
            PeelVideoCodec.H264);

        await ConnectAndPublishWindowAsync(control, firstControl, first, windowId: 71);
        await controller.StartAsync(control.Windows.Single(), CancellationToken.None);
        await control.DisconnectAsync(CancellationToken.None);
        await WaitUntilAsync(() => controller.State == PeelStreamState.Stopped);
        Equal<uint?>(null, controller.StreamingWindowId);

        fixture.Resolver.Current = second;
        await ConnectAndPublishWindowAsync(control, secondControl, first, windowId: 72);
        await controller.StartAsync(control.Windows.Single(), CancellationToken.None);

        Equal(4, fixture.Resolver.CallCount);
        SequenceEqual(
            ["first-reconnect.local", "first-reconnect.local", "second-reconnect.local", "second-reconnect.local"],
            fixture.Transport.Endpoints.Select(endpoint => endpoint.Host));
        Equal(72u, controller.StreamingWindowId);
        Equal(1, fixture.Credentials.Count);
    }

    private static async Task StreamControllerCancellationAsync()
    {
        var host = Candidate("host-controller", "controller.local", 8801);
        var fixture = new Fixture(host, new ScriptedDuplexStream())
        {
            Transport = new FakeTransportFactory(blockConnect: true),
        };
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        var video = fixture.CreateVideoSession(decoder);
        var context = new StubClientContext(host, new RemoteWindowDescriptor(81, "Window", "App", 640, 480));
        await using var controller = new ClientStreamController(
            context,
            context,
            context,
            video,
            PeelVideoCodec.H264);
        using var cancellation = new CancellationTokenSource();

        var start = controller.StartAsync(context.Windows.Single(), cancellation.Token);
        await WaitUntilAsync(() => fixture.Transport.Endpoints.Count == 1);
        cancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => start);

        Equal(PeelStreamState.Stopped, controller.State);
        Equal<uint?>(null, controller.StreamingWindowId);
        Equal(0, context.ControlRequests.Count);
        Equal(1, fixture.Credentials.Count);
    }

    private static async Task StreamControllerRejectsInvalidStartsAsync()
    {
        var host = Candidate("host-invalid", "invalid.local", 8901);
        var fixture = new Fixture(host, new ScriptedDuplexStream());
        var decoder = new RecordingVideoDecoderSink(PeelVideoCodec.H264);
        var video = fixture.CreateVideoSession(decoder);
        var context = new StubClientContext(host, new RemoteWindowDescriptor(91, "Window", "App", 640, 480));
        await using (var controller = new ClientStreamController(
            context,
            context,
            context,
            video,
            PeelVideoCodec.H264))
        {
            await ThrowsAsync<InvalidOperationException>(() =>
                controller.StartAsync(
                    new RemoteWindowDescriptor(92, "Forged", "App", 640, 480),
                    CancellationToken.None));
        }

        var unsupportedFixture = new Fixture(host, new ScriptedDuplexStream());
        var unsupportedVideo = unsupportedFixture.CreateVideoSession(
            new RecordingVideoDecoderSink(PeelVideoCodec.H264));
        await using (var unsupportedController = new ClientStreamController(
            context,
            context,
            context,
            unsupportedVideo,
            PeelVideoCodec.Hevc))
        {
            await ThrowsAsync<ClientCapabilityUnavailableException>(() =>
                unsupportedController.StartAsync(context.Windows.Single(), CancellationToken.None));
        }

        Equal(0, fixture.Transport.Endpoints.Count);
        Equal(0, unsupportedFixture.Transport.Endpoints.Count);
        Equal(0, context.ControlRequests.Count);
    }

    private static async Task ActiveStreamCancellationAsync()
    {
        var host = Candidate("host-active-cancel", "active-cancel.local", 8851);
        var fixture = new Fixture(host, new ScriptedDuplexStream());
        var video = fixture.CreateVideoSession(new RecordingVideoDecoderSink(PeelVideoCodec.H264));
        var context = new StubClientContext(
            host,
            new RemoteWindowDescriptor(86, "Window", "App", 640, 480));
        await using var controller = new ClientStreamController(
            context,
            context,
            context,
            video,
            PeelVideoCodec.H264);
        using var lifetime = new CancellationTokenSource();

        await controller.StartAsync(context.Windows.Single(), lifetime.Token);
        lifetime.Cancel();
        await WaitUntilAsync(() => controller.State == PeelStreamState.Stopped);

        SequenceEqual(
            [PeelMessageType.StartStream, PeelMessageType.StopStream],
            context.ControlRequests.Select(request => request.Type));
        Equal<uint?>(null, controller.StreamingWindowId);
        Equal(1, fixture.Credentials.Count);
    }

    private static async Task ConnectAndPublishWindowAsync(
        ClientSession session,
        ScriptedDuplexStream controlStream,
        HostCandidate requestedHost,
        uint windowId,
        bool includeInputFocus = false)
    {
        var connect = session.ConnectAsync(requestedHost, CancellationToken.None);
        await controlStream.WaitForWritesAsync(1);
        controlStream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost(
            "Video Host",
            capabilities:
            [
                PeelCapability.BinaryVideoTransportV2,
                PeelCapability.H264Video,
                PeelCapability.PerWindowVideoConnections,
                .. includeInputFocus ? new[] { PeelCapability.InputFocus } : Array.Empty<string>(),
            ])));
        await connect.WaitAsync(TimeSpan.FromSeconds(2));
        await ((IWindowListService)session).StartAsync(CancellationToken.None);
        controlStream.EnqueueRead(PeelJson.SerializeLine(new WindowListMessage(
            [new PeelWindow(windowId, "App", $"Window {windowId}", 1280, 720)])));
        await WaitUntilAsync(() => session.Windows.Count == 1 && session.Windows[0].Id == windowId);
    }

    private static byte[][] SnapshotWrites(ScriptedDuplexStream stream)
    {
        lock (stream.Writes) return stream.Writes.ToArray();
    }

    private static PeelRequest FindControlRequest(
        ScriptedDuplexStream stream,
        string messageType)
    {
        foreach (var write in SnapshotWrites(stream))
        {
            if (ReadType(write) == messageType)
            {
                return PeelJson.Deserialize<PeelRequest>(TrimLine(write));
            }
        }

        throw new InvalidOperationException($"Control request '{messageType}' was not written.");
    }

    private static string ReadType(byte[] line) =>
        PeelJson.ReadEnvelope(TrimLine(line)).Type;

    private static void AssertBefore(
        ConcurrentQueue<string> operations,
        string first,
        string second)
    {
        var snapshot = operations.ToArray();
        var firstIndex = Array.IndexOf(snapshot, first);
        var secondIndex = Array.IndexOf(snapshot, second);
        True(firstIndex >= 0 && secondIndex > firstIndex, $"Expected '{first}' before '{second}'.");
    }

    private static NegotiatedVideoStreamRequest VideoRequest(
        string stableHostId,
        uint windowId,
        PeelVideoCodec codec) =>
        new(
            stableHostId,
            windowId,
            codec,
            PeelProtocol.CurrentProtocolVersion,
            PeelProtocol.MinimumSupportedProtocolVersion,
            new HashSet<string>(StringComparer.Ordinal)
            {
                PeelCapability.BinaryVideoTransportV2,
                codec == PeelVideoCodec.Hevc ? PeelCapability.HevcVideo : PeelCapability.H264Video,
                PeelCapability.PerWindowVideoConnections,
            });

    private static async Task ConnectAsync(
        ClientSession session,
        ScriptedDuplexStream stream,
        HostCandidate host)
    {
        var connect = session.ConnectAsync(host, CancellationToken.None);
        await stream.WaitForWritesAsync(1);
        stream.EnqueueRead(PeelJson.SerializeLine(PeelHello.CreateHost("Test Host")));
        await connect.WaitAsync(TimeSpan.FromSeconds(2));
    }

    private static HostCandidate Candidate(string stableHostId, string address, int port) =>
        new(stableHostId, $"service-{stableHostId}", "Test Host", address, port, IsSaved: true);

    private static string ReadWriteType(ScriptedDuplexStream stream, int index) =>
        PeelJson.ReadEnvelope(TrimLine(stream.Writes[index])).Type;

    private static T DeserializeWrite<T>(ScriptedDuplexStream stream, int index) =>
        PeelJson.Deserialize<T>(TrimLine(stream.Writes[index]));

    private static ReadOnlySpan<byte> TrimLine(byte[] line) =>
        line.AsSpan(0, line.Length > 0 && line[^1] == (byte)'\n' ? line.Length - 1 : line.Length);

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!condition())
        {
            await Task.Delay(5, timeout.Token);
        }
    }

    private static async Task ThrowsAsync<TException>(Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static void Throws<TException>(Action action)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static Func<Task> Sync(Action action) => () =>
    {
        action();
        return Task.CompletedTask;
    };

    private static void True(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void SequenceEqual<T>(IEnumerable<T> expected, IEnumerable<T> actual)
    {
        if (!expected.SequenceEqual(actual))
        {
            throw new InvalidOperationException("Sequences differ.");
        }
    }

    private sealed class FakeHostRuntimeInstance : IHostRuntimeInstance
    {
        private readonly List<HostPairedClient> pairedClients;

        internal FakeHostRuntimeInstance(List<HostPairedClient>? pairedClients = null)
        {
            this.pairedClients = pairedClients ?? [];
        }

        public event Action? StateChanged;

        public bool IsRunning { get; private set; }

        public string? LastError => null;

        public IPEndPoint? ControlEndPoint => IsRunning
            ? new IPEndPoint(IPAddress.Loopback, 12345)
            : null;

        public IPEndPoint? PairingEndPoint => IsRunning
            ? new IPEndPoint(IPAddress.Loopback, 12346)
            : null;

        public string? ActivePeerIdentity => null;

        public int ActiveStreamCount { get; set; }

        public bool IsClientVisible { get; set; }

        public bool IsPreventingSleep { get; set; }

        public string? AwakeError { get; set; }

        public HostPairingPin? PairingPin => null;

        public IReadOnlyList<HostPairedClient> PairedClients => pairedClients.ToArray();

        public bool IsInputEnabled { get; private set; }

        public bool IsDisposed { get; private set; }

        public bool ThrowWhenDisablingInput { get; set; }

        public bool ThrowWhenStarting { get; set; }

        public TaskCompletionSource DisposeStarted { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource? DisposeBlocker { get; set; }

        public ValueTask StartAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            if (ThrowWhenStarting)
            {
                throw new InvalidOperationException("The fake Host runtime failed to start.");
            }

            IsRunning = true;
            IsInputEnabled = false;
            StateChanged?.Invoke();
            return ValueTask.CompletedTask;
        }

        public ValueTask RefreshPairingAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            if (!IsRunning)
            {
                throw new InvalidOperationException("The fake Host runtime is offline.");
            }

            return ValueTask.CompletedTask;
        }

        public void SetInputEnabled(bool enabled)
        {
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            if (!enabled && ThrowWhenDisablingInput)
            {
                throw new InvalidOperationException("The fake input gate failed closed.");
            }

            if (enabled && !IsRunning)
            {
                throw new InvalidOperationException("The fake Host runtime is offline.");
            }

            IsInputEnabled = enabled;
            StateChanged?.Invoke();
        }

        public bool RemovePairedClient(string pairingId) =>
            pairedClients.RemoveAll(peer => StringComparer.Ordinal.Equals(
                peer.PairingId,
                pairingId)) != 0;

        public async ValueTask DisposeAsync()
        {
            DisposeStarted.TrySetResult();
            if (DisposeBlocker is not null)
            {
                await DisposeBlocker.Task.ConfigureAwait(false);
            }

            IsInputEnabled = false;
            IsClientVisible = false;
            IsPreventingSleep = false;
            IsRunning = false;
            IsDisposed = true;
            StateChanged?.Invoke();
        }
    }

    private sealed class Fixture
    {
        public const string PairingId = "pairing-123";
        public static readonly byte[] Key = RandomNumberGenerator.GetBytes(32);

        public Fixture(HostCandidate current, params ScriptedDuplexStream[] streams)
        {
            Resolver = new MutableHostResolver(current);
            Credentials.Set(new PairedHostCredential(current.StableHostId, PairingId, Key));
            Transport = new FakeTransportFactory(streams: streams);
        }

        public InMemoryPairedHostCredentialStore Credentials { get; } = new();

        public MutableHostResolver Resolver { get; }

        public FakeTransportFactory Transport { get; set; }

        public ClientSession CreateSession(
            TimeSpan? pingInterval = null,
            int maximumLineBytes = 64 * 1024,
            IPairedHostCredentialStore? credentialStore = null) =>
            new(
                Transport,
                credentialStore ?? Credentials,
                Resolver,
                new ClientHelloProfile("Windows Test", "Test PC", "Windows Test", "0.1"),
                new ClientSessionOptions
                {
                    MaximumControlLineBytes = maximumLineBytes,
                    PingInterval = pingInterval ?? TimeSpan.FromHours(1),
                    HostHelloTimeout = TimeSpan.FromSeconds(1),
                });

        public ClientVideoSocketSession CreateVideoSession(
            IVideoDecoderSink decoderSink,
            int maximumPacketBytes = PeelBinaryFraming.DefaultMaximumPacketBytes) =>
            new(
                Transport,
                Credentials,
                Resolver,
                decoderSink,
                new ClientVideoSocketOptions
                {
                    MaximumPacketBytes = maximumPacketBytes,
                });
    }

    private sealed class InMemoryPairedHostCredentialStore : IPairedHostCredentialStore
    {
        private readonly Dictionary<string, PairedHostCredential> _credentials = new(StringComparer.Ordinal);

        public int Count => _credentials.Count;

        public void Set(PairedHostCredential credential)
        {
            _credentials.Clear();
            _credentials[credential.StableHostId] = credential;
        }

        public ValueTask<PairedHostCredential?> GetForHostAsync(
            string stableHostId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _credentials.TryGetValue(stableHostId, out var credential);
            return ValueTask.FromResult(credential);
        }
    }

    private sealed class FixedPairedHostCredentialStore : IPairedHostCredentialStore
    {
        private readonly PairedHostCredential? _credential;

        public FixedPairedHostCredentialStore(PairedHostCredential? credential)
        {
            _credential = credential;
        }

        public ValueTask<PairedHostCredential?> GetForHostAsync(
            string stableHostId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(_credential);
        }
    }

    private sealed class MutableHostResolver : IClientHostResolver
    {
        public MutableHostResolver(HostCandidate current)
        {
            Current = current;
        }

        public HostCandidate Current { get; set; }

        public int CallCount { get; private set; }

        public ValueTask<HostCandidate?> ResolveFreshAsync(
            string stableHostId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            return ValueTask.FromResult<HostCandidate?>(Current);
        }
    }

    private sealed class RecordingVideoDecoderSink : IVideoDecoderSink
    {
        public RecordingVideoDecoderSink(params PeelVideoCodec[] codecs)
        {
            SupportedCodecs = new HashSet<PeelVideoCodec>(codecs);
        }

        public IReadOnlySet<PeelVideoCodec> SupportedCodecs { get; }

        public event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded
        {
            add { }
            remove { }
        }

        public List<uint> Resets { get; } = [];

        public List<VideoConfigPacket> Configurations { get; } = [];

        public List<VideoFramePacket> Frames { get; } = [];

        public ValueTask ResetAsync(uint windowId, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (Resets)
            {
                Resets.Add(windowId);
            }

            return ValueTask.CompletedTask;
        }

        public ValueTask ConfigureAsync(
            VideoConfigPacket configuration,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (Configurations)
            {
                Configurations.Add(configuration);
            }

            return ValueTask.CompletedTask;
        }

        public ValueTask SubmitAsync(VideoFramePacket frame, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (Frames)
            {
                Frames.Add(frame);
            }

            return ValueTask.CompletedTask;
        }
    }

    private sealed class BlockingVideoDecoderSink : IVideoDecoderSink
    {
        public event EventHandler<DecodedVideoFrameEventArgs>? FrameDecoded
        {
            add { }
            remove { }
        }

        public IReadOnlySet<PeelVideoCodec> SupportedCodecs { get; } =
            new HashSet<PeelVideoCodec> { PeelVideoCodec.H264 };

        public TaskCompletionSource SubmitStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource ReleaseSubmit { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public ValueTask ResetAsync(uint windowId, CancellationToken cancellationToken) =>
            ValueTask.CompletedTask;

        public ValueTask ConfigureAsync(
            VideoConfigPacket configuration,
            CancellationToken cancellationToken) => ValueTask.CompletedTask;

        public async ValueTask SubmitAsync(
            VideoFramePacket frame,
            CancellationToken cancellationToken)
        {
            SubmitStarted.TrySetResult();
            await ReleaseSubmit.Task.ConfigureAwait(false);
        }
    }

    private sealed class StubClientContext :
        ISecureConnectionService,
        IWindowListService,
        IClientStreamControlChannel
    {
        public StubClientContext(HostCandidate host, params RemoteWindowDescriptor[] windows)
        {
            ConnectedHost = host;
            Windows = windows;
            NegotiatedHost = new NegotiatedClientHost(
                host.StableHostId,
                PeelProtocol.CurrentProtocolVersion,
                PeelProtocol.MinimumSupportedProtocolVersion,
                new HashSet<string>(StringComparer.Ordinal)
                {
                    PeelCapability.BinaryVideoTransportV2,
                    PeelCapability.H264Video,
                    PeelCapability.HevcVideo,
                    PeelCapability.PerWindowVideoConnections,
                });
        }

        public event EventHandler<ConnectionStateChangedEventArgs>? StateChanged
        {
            add { }
            remove { }
        }

        public event EventHandler? WindowsChanged
        {
            add { }
            remove { }
        }

        public PeelConnectionState State => PeelConnectionState.Connected;

        public HostCandidate? ConnectedHost { get; }

        public IReadOnlyList<RemoteWindowDescriptor> Windows { get; }

        public NegotiatedClientHost? NegotiatedHost { get; }

        public List<PeelRequest> ControlRequests { get; } = [];

        public Task ConnectAsync(HostCandidate host, CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task DisconnectAsync(CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task StartAsync(CancellationToken cancellationToken) =>
            throw new NotSupportedException();

        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task SendStartStreamAsync(uint windowId, CancellationToken cancellationToken) =>
            RecordAsync(PeelMessageType.StartStream, windowId, cancellationToken);

        public Task SendStopStreamAsync(uint windowId, CancellationToken cancellationToken) =>
            RecordAsync(PeelMessageType.StopStream, windowId, cancellationToken);

        private Task RecordAsync(
            string messageType,
            uint windowId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ControlRequests.Add(new PeelRequest(messageType, windowId));
            return Task.CompletedTask;
        }
    }

    private sealed class FakeTransportFactory : IPeelPskTransportFactory
    {
        private readonly ConcurrentQueue<ScriptedDuplexStream> _streams;
        private readonly bool _blockConnect;

        public FakeTransportFactory(
            bool blockConnect = false,
            params ScriptedDuplexStream[] streams)
        {
            _blockConnect = blockConnect;
            _streams = new ConcurrentQueue<ScriptedDuplexStream>(streams);
        }

        public List<DnsEndPoint> Endpoints { get; } = [];

        public List<string> Identities { get; } = [];

        public async ValueTask<Stream> ConnectAsync(
            DnsEndPoint endpoint,
            PeelPskCredential credential,
            CancellationToken cancellationToken = default)
        {
            lock (Endpoints)
            {
                Endpoints.Add(endpoint);
                Identities.Add(credential.Identity);
            }

            if (_blockConnect)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }

            if (!_streams.TryDequeue(out var stream))
            {
                throw new IOException("No scripted secure stream is available.");
            }

            return stream;
        }

        public ValueTask<IPeelPskListener> ListenAsync(
            IPEndPoint endpoint,
            IPeelPskCredentialResolver credentialResolver,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException<IPeelPskListener>(new NotSupportedException());
    }

    private sealed class ScriptedDuplexStream : Stream
    {
        private readonly Channel<byte[]> _reads = Channel.CreateUnbounded<byte[]>();
        private readonly SemaphoreSlim _writeSignal = new(0);
        private readonly TimeSpan _writeDelay;
        private readonly Action<byte[]>? _onWrite;
        private readonly Action? _onDispose;
        private byte[]? _currentRead;
        private int _currentReadOffset;
        private int _activeWrites;
        private int _maximumConcurrentWrites;
        private bool _disposed;

        public ScriptedDuplexStream(
            TimeSpan? writeDelay = null,
            Action<byte[]>? onWrite = null,
            Action? onDispose = null)
        {
            _writeDelay = writeDelay ?? TimeSpan.Zero;
            _onWrite = onWrite;
            _onDispose = onDispose;
        }

        public List<byte[]> Writes { get; } = [];

        public int MaximumConcurrentWrites => Volatile.Read(ref _maximumConcurrentWrites);

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => true;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public void EnqueueRead(byte[] bytes)
        {
            if (!_reads.Writer.TryWrite(bytes))
            {
                throw new InvalidOperationException("The scripted stream is closed.");
            }
        }

        public void CompleteReads() => _reads.Writer.TryComplete();

        public async Task WaitForWritesAsync(int count)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            while (true)
            {
                lock (Writes)
                {
                    if (Writes.Count >= count)
                    {
                        return;
                    }
                }

                await _writeSignal.WaitAsync(timeout.Token);
            }
        }

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            while (_currentRead is null || _currentReadOffset == _currentRead.Length)
            {
                _currentRead = null;
                _currentReadOffset = 0;
                try
                {
                    _currentRead = await _reads.Reader.ReadAsync(cancellationToken);
                }
                catch (ChannelClosedException)
                {
                    return 0;
                }
            }

            var count = Math.Min(buffer.Length, _currentRead.Length - _currentReadOffset);
            _currentRead.AsMemory(_currentReadOffset, count).CopyTo(buffer);
            _currentReadOffset += count;
            return count;
        }

        public override async ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var active = Interlocked.Increment(ref _activeWrites);
            UpdateMaximum(active);
            try
            {
                if (_writeDelay > TimeSpan.Zero)
                {
                    await Task.Delay(_writeDelay, cancellationToken);
                }

                var write = buffer.ToArray();
                lock (Writes)
                {
                    Writes.Add(write);
                }

                _onWrite?.Invoke(write);
                _writeSignal.Release();
            }
            finally
            {
                Interlocked.Decrement(ref _activeWrites);
            }
        }

        public override void Flush()
        {
        }

        public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing && !_disposed)
            {
                _disposed = true;
                _reads.Writer.TryComplete();
                _onDispose?.Invoke();
            }

            base.Dispose(disposing);
        }

        private void UpdateMaximum(int active)
        {
            while (true)
            {
                var observed = Volatile.Read(ref _maximumConcurrentWrites);
                if (active <= observed
                    || Interlocked.CompareExchange(ref _maximumConcurrentWrites, active, observed) == observed)
                {
                    return;
                }
            }
        }
    }
}
