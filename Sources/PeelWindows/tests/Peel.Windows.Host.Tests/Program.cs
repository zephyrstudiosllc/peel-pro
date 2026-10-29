using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Input;
using Peel.Windows.Host.Interop;
using Peel.Windows.Host.Networking;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Host.Orchestration;
using Peel.Windows.Host.Pairing;
using Peel.Windows.Host.Runtime;
using Peel.Windows.Host.Security;
using Peel.Windows.Host.Windows;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Host.Tests;

internal static partial class Program
{
    private static readonly (string Name, Func<Task> Test)[] Tests =
    {
        ("Machine Status requires fresh proof and revokes consent", MachineStatusAuthorizationAsync),
        ("normalized center mapping", Sync(NormalizedCenterMapping)),
        ("normalized edge clamping", Sync(NormalizedEdgeClamping)),
        ("hostile coordinate rejection", Sync(HostileCoordinateRejection)),
        ("input gate defaults closed", Sync(InputGateDefaultsClosed)),
        ("paired credential metadata excludes secrets", Sync(PairedCredentialMetadataExcludesSecrets)),
        ("re-pair revokes previous identity", Sync(RePairRevokesPreviousIdentity)),
        ("credential targets preserve case-sensitive identity", Sync(CredentialTargetsPreserveCaseSensitiveIdentity)),
        ("corrupt paired metadata fails closed", Sync(CorruptPairedMetadataFailsClosed)),
        ("stable Host identity persists and fails closed", Sync(StableHostIdentityPersistsAndFailsClosed)),
        ("diagnostic Host points live hosting to unified app", Sync(DiagnosticHostPointsLiveHostingToUnifiedApp)),
        ("production runtime defaults to dual-stack listen", Sync(ProductionRuntimeDefaultsToDualStackListen)),
        ("pairing TXT matches Apple PIN contract", Sync(PairingTxtMatchesApplePinContract)),
        ("runtime advertises and rotates exact Host services", RuntimeAdvertisesAndRotatesExactHostServices),
        ("secure PIN pairing rejects bad proof and stores credential", SecurePinPairingRejectsBadProofAndStoresCredential),
        ("expired PIN pairing is rejected", ExpiredPinPairingIsRejected),
        ("PIN pairing listener survives hostile JSON", PinPairingListenerSurvivesHostileJson),
        ("network input defaults closed and reports rejection", NetworkInputDefaultsClosedAndReportsRejection),
        ("active-window focus honors input gate and window identity", ActiveWindowFocusHonorsInputGateAndWindowIdentity),
        ("authenticated control dispatches bounded input", AuthenticatedControlDispatchesBoundedInput),
        ("source media keys require an admitted stream, visibility and the input gate", SourceMediaKeysRequireAdmittedStreamAndInputGateAsync),
        ("source media limits slide per kind and volume sequence is monotonic", Sync(SourceMediaLimiterIsSlidingAndPerKind)),
        ("source media keys are allowlisted, gated and never take focus", Sync(SourceMediaKeysAreAllowlistedAndGated)),
        ("source system volume is gated, device-fenced and reports actual state", SourceSystemVolumeIsGatedFencedAndActualAsync),
        ("Mac held hardware keys accept modifier snapshots", MacHeldHardwareKeysAcceptModifierSnapshots),
        ("hardware Function metadata remains informational", HardwareFunctionMetadataIsInformational),
        ("hardware Function metadata preserves modifier ownership", HardwareFunctionMetadataPreservesModifierOwnership),
        ("hardware Function metadata rejects invalid and oversized lists", HardwareFunctionMetadataRejectsInvalidLists),
        ("hardware Function metadata rejects unknown wire names", HardwareFunctionMetadataRejectsUnknownWireNames),
        ("hardware modifier snapshots reject non-modifiers", Sync(HardwareModifierSnapshotsRejectNonModifiers)),
        ("held hardware modifiers release on revoke and disconnect", HeldHardwareModifiersReleaseOnRevokeAndDisconnect),
        ("keyboard delete commands preserve backward and forward direction", KeyboardDeleteCommandsPreserveDirection),
        ("scroll preserves fractional motion", Sync(ScrollPreservesFractionalMotion)),
        ("input session rejects hostile data and releases held state", Sync(InputSessionRejectsHostileDataAndReleasesHeldState)),
        ("secure hello and real window list", SecureHelloAndWindowList),
        ("authenticated hello records paired-client activity", AuthenticatedHelloRecordsPairedClientActivity),
        ("client hello must be first", ClientHelloMustBeFirst),
        ("same-peer hello refresh preserves session and hidden state", SamePeerHelloRefreshPreservesSessionAndHiddenState),
        ("hello refresh rejects identity and protocol changes", HelloRefreshRejectsIdentityAndProtocolChanges),
        ("diagnostics refresh retains ownership and replay guards", Sync(DiagnosticsRefreshRetainsOwnershipAndGuards)),
        ("control refresh updates bilateral diagnostics consent", ControlRefreshUpdatesDiagnosticsConsent),
        ("audio refresh revokes pending and active sharing", AudioRefreshRevokesPendingAndActive),
        ("Machine Status refresh requires fresh proof", MachineStatusRefreshRequiresFreshProof),
        ("old asynchronous status proof cannot cross replacement", OldStatusProofCannotCrossReplacement),
        ("TLS identity mismatch rejected", TlsIdentityMismatchRejected),
        ("incompatible protocol rejected", IncompatibleProtocolRejected),
        ("client visibility owns Host awake state", ClientVisibilityOwnsHostAwakeState),
        ("malformed client visibility fails soft", MalformedClientVisibilityFailsSoft),
        ("malformed and oversized lines fail soft", MalformedAndOversizedLinesFailSoft),
        ("replacement session suppresses stale response", ReplacementSessionSuppressesStaleResponse),
        ("replacement session aborts blocked transport", ReplacementSessionAbortsBlockedTransport),
        ("listener disposal aborts blocked authenticated transport", ListenerDisposalAbortsBlockedAuthenticatedTransport),
        ("authenticated router preserves control prefix", AuthenticatedRouterPreservesControlPrefix),
        ("authenticated router classifies video prefix", AuthenticatedRouterClassifiesVideoPrefix),
        ("authenticated router rejects hostile first lines", AuthenticatedRouterRejectsHostileFirstLines),
        ("capture frame layout validates dimensions and stride", Sync(CaptureFrameLayoutValidation)),
        ("capture timestamps remain monotonic", Sync(CaptureTimestampsRemainMonotonic)),
        ("BGRA capture converts to bounded NV12", Sync(BgraCaptureConvertsToNv12)),
        ("Annex-B access units become Apple-compatible payloads", Sync(AnnexBBecomesLengthPrefixed)),
        ("capture pump is serial and latest-frame-wins", CapturePumpIsSerialAndLatestFrameWins),
        ("capture pump completion is idempotent", Sync(CapturePumpCompletionIsIdempotent)),
        ("video session emits config then latest raw frames", VideoSessionEmitsConfigThenLatestRawFrames),
        ("video session uses capture pixel dimensions", VideoSessionUsesCapturePixelDimensions),
        ("video session reconfigures after resize", VideoSessionReconfiguresAfterResize),
        ("video hello rejects hostile identity and framing", VideoHelloRejectsHostileIdentityAndFraming),
        ("video writer rejects invalid config and frames", VideoWriterRejectsInvalidConfigAndFrames),
        ("replacement video session suppresses stale output", ReplacementVideoSessionSuppressesStaleOutput),
        ("video session follows control lifetime", VideoSessionFollowsControlLifetime),
        ("simultaneous video sessions remain independent", SimultaneousVideoSessionsRemainIndependent),
        ("control stop cancels video and start permits reconnect", ControlStopCancelsVideoAndStartPermitsReconnect),
        ("window IDs remain stable across control reconnect", WindowIdsRemainStableAcrossControlReconnect),
        ("window IDs bind HWND and process identity", Sync(WindowIdsBindHandleAndProcessIdentity)),
        ("display descriptors match Mac synthetic-source contract", Sync(DisplayDescriptorsMatchMacContract)),
        ("display IDs remain reserved beside session window IDs", Sync(DisplayIdsRemainReservedBesideSessionWindowIds)),
        ("replacement release precedes HostHello despite blocked observer", ReplacementReleaseBeforeHelloWithBlockedObserver),
        ("replacement proceeds during blocked old audio cleanup", ReplacementDoesNotAwaitAudioCleanup),
        ("A B C replacement waits for native release", ReplacementAbcWaitsForNativeRelease),
        ("replacement waits for admitted native operation", ReplacementWaitsForInFlightDispatch),
        ("replacement waits for permission recovery", ReplacementWaitsForPermissionRecovery),
        ("late old hello cannot restore ownership", ReplacementRejectsLateOldHello),
        ("cancelled transition waiter does not poison startup", ReplacementCancelledWaiter),
        ("cancelled input factory does not poison startup", ReplacementCancelledFactory),
        ("failed input factory does not poison startup", ReplacementFailedFactory),
        ("dispose releases input despite blocked observer", ReplacementDisposeIgnoresBlockedObserver),
        ("stop releases awake request before blocked audio cleanup", StopReleasesAwakeBeforeAudioCleanup),
    };

    public static async Task<int> Main(string[] args)
    {
        if (args is ["--focus-correlation-fake-tests"]) return await RunFocusCorrelationFakeTestsAsync();
        if (args is ["--hardware-function-fake-tests"]) return await RunHardwareFunctionFakeTestsAsync();
        if (args is ["--replacement-order-fake-tests"]) return await RunReplacementOrderFakeTestsAsync();
        if (args is ["--capability-refresh-fake-tests"]) return await RunCapabilityRefreshFakeTestsAsync();
        if (args is ["--native-source-volume-read-smoke"]) return await NativeSourceVolumeReadSmokeAsync();
        if (args is ["--native-gpu-stream-smoke"]) return await RunNativeStreamSmokeAsync(true);
        if (args is ["--native-stream-diagnostics-smoke"]) return await RunNativeStreamSmokeAsync(true, true);
        if (args is ["--native-gpu-resize-stream-smoke"]) return await RunNativeResizeStreamSmokeAsync(true);
        if (args is ["--native-capture-smoke"])
        {
            return await RunNativeCaptureSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-display-capture-smoke"])
        {
            return await RunNativeDisplayCaptureSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-encode-smoke"])
        {
            return await RunNativeEncodeSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-stream-smoke"])
        {
            return await RunNativeStreamSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-resize-stream-smoke"])
        {
            return await RunNativeResizeStreamSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-listener-stream-smoke"])
        {
            return await RunNativeListenerStreamSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-sustained-listener-stream-smoke"])
        {
            return await RunNativeListenerStreamSmokeAsync(TimeSpan.FromMinutes(10))
                .ConfigureAwait(false);
        }

        if (args is ["--native-sustained-multi-listener-stream-smoke"])
        {
            return await RunNativeSustainedMultiListenerStreamSmokeAsync(
                    TimeSpan.FromMinutes(10))
                .ConfigureAwait(false);
        }

        if (args is ["--native-input-smoke"])
        {
            return await RunNativeInputSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-keyboard-input-smoke"])
        {
            return await RunNativeKeyboardInputSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-elevated-input-target", var elevatedTargetStateDirectory])
        {
            return await RunNativeElevatedInputTargetAsync(elevatedTargetStateDirectory)
                .ConfigureAwait(false);
        }

        if (args is ["--native-elevated-input-smoke", var elevatedInputStateDirectory])
        {
            return await RunNativeElevatedInputSmokeAsync(elevatedInputStateDirectory)
                .ConfigureAwait(false);
        }

        if (args is ["--native-focus-smoke"])
        {
            return await RunNativeFocusSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-credential-smoke"])
        {
            return RunNativeCredentialSmoke();
        }

        if (args is ["--native-pairing-smoke"])
        {
            return await RunNativePairingSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-runtime-smoke"])
        {
            return await RunNativeRuntimeSmokeAsync().ConfigureAwait(false);
        }

        if (args is ["--native-external-multi-window-smoke", var externalStateDirectory])
        {
            return await RunNativeExternalMultiWindowSmokeAsync(externalStateDirectory)
                .ConfigureAwait(false);
        }

        if (args is ["--apple-interop-host", var stateDirectory])
        {
            return await RunAppleInteropHostAsync(stateDirectory).ConfigureAwait(false);
        }

        if (args.Length != 0)
        {
            Console.Error.WriteLine(
                "Usage: Peel.Windows.Host.Tests " +
                "[--focus-correlation-fake-tests|--hardware-function-fake-tests|--native-capture-smoke|--native-display-capture-smoke|" +
                "--native-encode-smoke|--native-stream-smoke|" +
                "--native-resize-stream-smoke|--native-listener-stream-smoke|" +
                "--native-sustained-listener-stream-smoke|" +
                "--native-sustained-multi-listener-stream-smoke|" +
                "--native-input-smoke|--native-keyboard-input-smoke|" +
                "--native-elevated-input-target <state-directory>|" +
                "--native-elevated-input-smoke <state-directory>|" +
                "--native-focus-smoke|--native-credential-smoke|" +
                "--native-pairing-smoke|--native-runtime-smoke|" +
                "--native-external-multi-window-smoke <state-directory>|" +
                "--apple-interop-host <state-directory>]");
            return 2;
        }

        var failures = 0;
        foreach ((string name, Func<Task> test) in Tests)
        {
            try
            {
                await test().ConfigureAwait(false);
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
            }
        }

        Console.WriteLine($"{Tests.Length - failures}/{Tests.Length} host boundary tests passed");
        return failures == 0 ? 0 : 1;
    }

    private static async Task<int> RunNativeCaptureSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine("Native capture smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            CapturedFrame capturedFrame = await CaptureNativeFrameAsync().ConfigureAwait(false);
            True(capturedFrame.PixelFormat is CapturePixelFormat.Bgra8 or CapturePixelFormat.Nv12);
            CaptureFrameLayout.ValidateCaptureSize(capturedFrame.Width, capturedFrame.Height);
            Equal(checked(capturedFrame.Width * (capturedFrame.PixelFormat == CapturePixelFormat.Nv12 ? 1 : CaptureFrameLayout.BytesPerPixel)),
                capturedFrame.BytesPerRow);
            Equal(checked(capturedFrame.PixelFormat == CapturePixelFormat.Nv12 ? capturedFrame.Width * capturedFrame.Height * 3 / 2 : capturedFrame.BytesPerRow * capturedFrame.Height),
                capturedFrame.Pixels.Length);
            True(capturedFrame.Timestamp100Nanoseconds >= 0);
            True(capturedFrame.Pixels.Span.IndexOfAnyExcept((byte)0) >= 0);

            Console.WriteLine(
                "PASS native capture smoke: " +
                $"{capturedFrame.Width}x{capturedFrame.Height} {capturedFrame.PixelFormat}, " +
                $"stride={capturedFrame.BytesPerRow}, " +
                $"timestamp100ns={capturedFrame.Timestamp100Nanoseconds}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"FAIL native capture smoke: {exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeDisplayCaptureSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native display capture smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            WindowDescriptor display = new Win32WindowEnumerator()
                .Enumerate()
                .FirstOrDefault(static source => source.IsDisplay) ??
                throw new InvalidDataException("Windows did not report an online display source.");
            WindowInputTargetResult target = new WindowsWindowInputTargetResolver().Resolve(
                display,
                WindowInputFocusMode.AcquireForeground);
            if (!target.Succeeded)
            {
                throw new InvalidDataException(target.Error);
            }

            Equal(display.Bounds, target.Bounds);
            CapturedFrame capturedFrame = await CaptureNativeFrameFromSourceAsync(display)
                .ConfigureAwait(false);
            True(capturedFrame.PixelFormat is CapturePixelFormat.Bgra8 or CapturePixelFormat.Nv12);
            CaptureFrameLayout.ValidateCaptureSize(capturedFrame.Width, capturedFrame.Height);
            Equal(checked(capturedFrame.Width * (capturedFrame.PixelFormat == CapturePixelFormat.Nv12 ? 1 : CaptureFrameLayout.BytesPerPixel)),
                capturedFrame.BytesPerRow);
            Equal(checked(capturedFrame.PixelFormat == CapturePixelFormat.Nv12 ? capturedFrame.Width * capturedFrame.Height * 3 / 2 : capturedFrame.BytesPerRow * capturedFrame.Height),
                capturedFrame.Pixels.Length);
            True(capturedFrame.Pixels.Span.IndexOfAnyExcept((byte)0) >= 0);

            Console.WriteLine(
                "PASS native display capture: reserved synthetic ID, focus-free input geometry, " +
                $"{capturedFrame.Width}x{capturedFrame.Height} {capturedFrame.PixelFormat} frame");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native display capture: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeEncodeSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine("Native H.264 smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            CapturedFrame capturedFrame = await CaptureNativeFrameAsync().ConfigureAwait(false);
            var settings = new VideoEncodingSettings(
                VideoCodec.H264,
                capturedFrame.Width,
                capturedFrame.Height,
                30,
                4_000_000);
            var factory = new MediaFoundationH264EncoderFactory();
            await using IVideoEncoder encoder =
                await factory.CreateAsync(settings, CancellationToken.None).ConfigureAwait(false);

            EncodedVideoFrame? encoded = null;
            long frameDuration = 10_000_000 / settings.FramesPerSecond;
            for (var attempt = 0; attempt < 5 && encoded is null; attempt++)
            {
                encoded = await encoder.EncodeAsync(
                    capturedFrame with
                    {
                        Timestamp100Nanoseconds = checked(
                            capturedFrame.Timestamp100Nanoseconds + (attempt * frameDuration)),
                    },
                    CancellationToken.None).ConfigureAwait(false);
            }

            if (encoded is null)
            {
                throw new InvalidDataException("Media Foundation requested more than five input frames.");
            }

            Equal(VideoCodec.H264, encoded.Codec);
            True(encoded.IsKeyFrame);
            True(encoded.Timestamp100Nanoseconds >= capturedFrame.Timestamp100Nanoseconds);
            True(encoded.Duration100Nanoseconds > 0);
            True(!encoded.Bytes.IsEmpty);
            VideoEncoderConfiguration configuration = encoded.Configuration ??
                throw new InvalidDataException("The first encoded keyframe has no configuration.");
            Equal(capturedFrame.Width, configuration.Width);
            Equal(capturedFrame.Height, configuration.Height);
            Equal(10_000_000U, configuration.Timescale);
            Equal((byte)4, configuration.NalUnitHeaderLength);
            Equal(7, configuration.SequenceParameterSet.Span[0] & 0x1F);
            Equal(8, configuration.PictureParameterSet.Span[0] & 0x1F);
            ValidateLengthPrefixedH264(encoded.Bytes.Span);

            Console.WriteLine(
                "PASS native H.264 smoke: " +
                $"{capturedFrame.Width}x{capturedFrame.Height}, " +
                $"payload={encoded.Bytes.Length}, " +
                $"sps={configuration.SequenceParameterSet.Length}, " +
                $"pps={configuration.PictureParameterSet.Length}, " +
                $"timestamp100ns={encoded.Timestamp100Nanoseconds}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"FAIL native H.264 smoke: {exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeStreamSmokeAsync(bool gpuInput = false, bool measure = false)
    {
        const int targetFrameCount = 30;
        const string identity = "native-stream-smoke-client";

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine("Native Host video smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            long gpuBefore = Interlocked.Read(ref MediaFoundationH264Transform.GpuInputsSubmitted);
            using var smokeWindow = new NativeCaptureSmokeWindow();
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            using var timeoutCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            smokeWindow.SetMinimized(minimized: true);
            await WaitForMinimumAsync(
                    () => NativeMethods.IsIconic(window.Handle) ? 1 : 0,
                    minimum: 1,
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            var settings = new VideoEncodingSettings(
                VideoCodec.H264,
                window.Bounds.Width,
                window.Bounds.Height,
                30,
                4_000_000, gpuInput);
            var options = new HostVideoSessionOptions(settings);
            HostVideoBinding binding = CreateVideoBinding(identity, window);
            using var sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCancellation.Token);
            var packetWriteCount = 0;
            var stream = new ScriptedDuplexStream(
                [],
                writeObserver: _ =>
                {
                    if (Interlocked.Increment(ref packetWriteCount) == targetFrameCount + 1)
                    {
                        sessionCancellation.Cancel();
                    }
                });
            await using var connection = new PeelPskConnection(stream, identity);
            using var writer = new HostVideoPacketWriter(
                connection,
                binding,
                options,
                static () => true);
            var orchestrator = new HostStreamOrchestrator(
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory());

            Task animation = AnimateNativeSmokeWindowAsync(
                smokeWindow,
                sessionCancellation.Token);
            if (measure) Peel.Windows.Host.Diagnostics.StreamDiagnostics.Shared.SetEnabled(true);
            using var diagnostics = measure ? Peel.Windows.Host.Diagnostics.StreamDiagnostics.Shared.Begin("host", 1, "H264", 30, 4_000_000) : null;
            try
            {
                await orchestrator.RunEncodedWindowStreamAsync(
                        window,
                        settings,
                        writer.SendEncodedFrameAsync,
                        static () => true,
                        sessionCancellation.Token, diagnostics)
                    .WaitAsync(TimeSpan.FromSeconds(25))
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
                when (Volatile.Read(ref packetWriteCount) >= targetFrameCount + 1)
            {
            }
            finally
            {
                sessionCancellation.Cancel();
                try
                {
                    await animation.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (sessionCancellation.IsCancellationRequested)
                {
                }
            }

            if (timeoutCancellation.IsCancellationRequested)
            {
                throw new TimeoutException(
                    $"The native Host pipeline did not emit {targetFrameCount} frames in time.");
            }

            if (Volatile.Read(ref packetWriteCount) < targetFrameCount + 1)
            {
                throw new InvalidDataException(
                    $"The native Host pipeline ended after {Math.Max(0, packetWriteCount - 1)} frames.");
            }

            IReadOnlyList<IPeelBinaryPacket> packets =
                new PeelBinaryPacketReader(options.MaximumEncodedPacketBytes)
                    .Append(stream.WrittenBytes);
            Equal(targetFrameCount + 1, packets.Count);
            var configuration = packets[0] as VideoConfigPacket ??
                throw new InvalidDataException("The native Host pipeline did not begin with video config.");
            Equal<uint>(1, configuration.WindowId);
            Equal(PeelVideoCodec.H264, configuration.Codec);
            True(configuration.Width > 0 &&
                configuration.Width <= (uint)CaptureFrameLayout.MaximumD3D11TextureDimension &&
                (configuration.Width & 1) == 0);
            True(configuration.Height > 0 &&
                configuration.Height <= (uint)CaptureFrameLayout.MaximumD3D11TextureDimension &&
                (configuration.Height & 1) == 0);
            Equal(10_000_000U, configuration.Timescale);
            Equal((byte)4, configuration.NalUnitHeaderLength);
            Equal(7, configuration.Sps[0] & 0x1F);
            Equal(8, configuration.Pps[0] & 0x1F);

            if (measure)
            {
                var stats = Peel.Windows.Host.Diagnostics.StreamDiagnostics.Shared.Snapshot().Streams.Single();
                True(stats.Stages.Single(s => s.Stage == "Captured").TotalEvents >= targetFrameCount);
                True(stats.Stages.Single(s => s.Stage == "Encoded").TotalEvents >= targetFrameCount);
                True(stats.Stages.Single(s => s.Stage == "Sent").TotalEvents >= targetFrameCount - 1);
                True(stats.Stages.Single(s => s.Stage == "Submitted").P95CallMilliseconds is > 0);
                Console.WriteLine("PASS native capture/encoder/send diagnostics: actual counts, bounded codec-call timing, and no frame content.");
                Peel.Windows.Host.Diagnostics.StreamDiagnostics.Shared.SetEnabled(false);
            }
            long previousTimestamp = -1;
            long encodedPayloadBytes = 0;
            for (var index = 1; index < packets.Count; index++)
            {
                var frame = packets[index] as VideoFramePacket ??
                    throw new InvalidDataException("The native Host pipeline emitted a non-frame packet.");
                Equal<uint>(1, frame.WindowId);
                True(frame.PtsValue > previousTimestamp);
                True(frame.DurationValue > 0);
                True(frame.Payload.Length > 0);
                ValidateLengthPrefixedH264(frame.Payload);
                previousTimestamp = frame.PtsValue;
                encodedPayloadBytes = checked(encodedPayloadBytes + frame.Payload.Length);
            }

            True(((VideoFramePacket)packets[1]).IsKeyframe);
            await WaitForMinimumAsync(
                    () => NativeMethods.IsIconic(window.Handle) ? 0 : 1,
                    minimum: 1,
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            long gpuInputs = Interlocked.Read(ref MediaFoundationH264Transform.GpuInputsSubmitted) - gpuBefore;
            if (gpuInput) True(gpuInputs >= targetFrameCount);
            Console.WriteLine(
                "PASS native Host initially-minimized video pipeline: " +
                $"{configuration.Width}x{configuration.Height}, " +
                $"frames={targetFrameCount}, " +
                $"payloadBytes={encodedPayloadBytes}, " +
                $"sps={configuration.Sps.Length}, " +
                $"pps={configuration.Pps.Length}, gpuInputs={gpuInputs}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"FAIL native Host video pipeline: {exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeListenerStreamSmokeAsync(
        TimeSpan? sustainedDuration = null)
    {
        const int targetFrameCount = 10;
        const string identity = "native-listener-smoke-client";
        byte[] preSharedKey = RandomNumberGenerator.GetBytes(
            PeelPskSecurityProfile.PreSharedKeyLength);
        PeelPskCredential? credential = null;

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native authenticated Host listener smoke requires Windows 10 version 2004 or later.");
            CryptographicOperations.ZeroMemory(preSharedKey);
            return 2;
        }

        try
        {
            if (sustainedDuration is { } requestedDuration && requestedDuration <= TimeSpan.Zero)
            {
                throw new ArgumentOutOfRangeException(nameof(sustainedDuration));
            }

            using var smokeWindow = new NativeCaptureSmokeWindow();
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            credential = new PeelPskCredential(identity, preSharedKey);
            var credentialResolver = new StaticPskCredentialResolver(credential);
            var transport = new BouncyCastlePskTransportFactory();
            var controlOptions = new HostControlSessionOptions(
                "Peel Windows Listener Smoke",
                Environment.OSVersion.VersionString,
                "validation");
            var controlSessions = new HostControlSessionManager(
                new FakeWindowEnumerator([window]),
                controlOptions);
            var videoOptions = new HostVideoSessionOptions(
                new VideoEncodingSettings(
                    VideoCodec.H264,
                    window.Bounds.Width,
                    window.Bounds.Height,
                    30,
                    4_000_000));
            var videoSessions = new HostVideoSessionManager(
                controlSessions,
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory(),
                videoOptions);
            await using var host = new HostAuthenticatedListener(
                transport,
                credentialResolver,
                controlSessions,
                videoSessions,
                new HostAuthenticatedListenerOptions(
                    acceptWorkerCount: 2,
                    maximumActiveConnections: 4));
            TimeSpan timeout = sustainedDuration is { } duration
                ? duration + TimeSpan.FromMinutes(2)
                : TimeSpan.FromSeconds(30);
            using var timeoutCancellation = new CancellationTokenSource(timeout);
            await host.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            var endpoint = host.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException("The Host listener did not publish a TCP endpoint.");

            await using Stream controlStream = await transport.ConnectAsync(
                    new DnsEndPoint(IPAddress.Loopback.ToString(), endpoint.Port),
                    credential,
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            byte[] controlRequest = CombineLines(
                PeelHello.CreateClient(
                    identity,
                    "Native Listener Client",
                    "Windows",
                    capabilities: VideoCapabilities()),
                new PeelRequest(PeelMessageType.RequestWindowList));
            await controlStream.WriteAsync(controlRequest, timeoutCancellation.Token)
                .ConfigureAwait(false);
            await controlStream.FlushAsync(timeoutCancellation.Token).ConfigureAwait(false);

            HostHelloMessage hostHello = PeelJson.Deserialize<HostHelloMessage>(
                await ReadNetworkLineAsync(
                        controlStream,
                        HostControlSessionOptions.DefaultMaximumFirstLineBytes,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false));
            True((hostHello.Capabilities ?? []).SequenceEqual(
                HostCapabilities().Order(StringComparer.Ordinal),
                StringComparer.Ordinal));
            WindowListMessage windowList = PeelJson.Deserialize<WindowListMessage>(
                await ReadNetworkLineAsync(
                        controlStream,
                        HostControlSessionOptions.DefaultMaximumControlLineBytes,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false));
            Equal(1, windowList.Windows.Count);
            Equal<uint>(1, windowList.Windows[0].WindowId);

            using var animationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCancellation.Token);
            Task animation = AnimateNativeSmokeWindowAsync(
                smokeWindow,
                animationCancellation.Token);
            IReadOnlyList<IPeelBinaryPacket>? packets = null;
            SustainedVideoObservation? sustainedObservation = null;
            try
            {
                await using Stream videoStream = await transport.ConnectAsync(
                        new DnsEndPoint(IPAddress.Loopback.ToString(), endpoint.Port),
                        credential,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                byte[] videoHello = PeelJson.SerializeLine(
                    PeelHello.CreateVideoStream(1, identity, VideoCapabilities()));
                await videoStream.WriteAsync(videoHello, timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await videoStream.FlushAsync(timeoutCancellation.Token).ConfigureAwait(false);
                if (sustainedDuration is { } observationDuration)
                {
                    sustainedObservation = await ObserveSustainedVideoStreamAsync(
                            videoStream,
                            videoOptions.MaximumEncodedPacketBytes,
                            windowId: 1,
                            observationDuration,
                            timeoutCancellation.Token)
                        .ConfigureAwait(false);
                }
                else
                {
                    packets = await ReadVideoPacketsAsync(
                            videoStream,
                            videoOptions.MaximumEncodedPacketBytes,
                            targetFrameCount + 1,
                            timeoutCancellation.Token)
                        .ConfigureAwait(false);
                }
                await controlStream.WriteAsync(
                        PeelJson.SerializeLine(new PeelRequest(
                            PeelMessageType.StopStream,
                            WindowId: 1)),
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await controlStream.FlushAsync(timeoutCancellation.Token).ConfigureAwait(false);
                await WaitForStreamEndAsync(
                        videoStream,
                        videoOptions.MaximumEncodedPacketBytes,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
            }
            finally
            {
                animationCancellation.Cancel();
                try
                {
                    await animation.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (animationCancellation.IsCancellationRequested)
                {
                }
            }

            if (sustainedObservation is { } observation)
            {
                Console.WriteLine(
                    "PASS native sustained authenticated Host listener: " +
                    $"durationSeconds={observation.Duration.TotalSeconds:F0}, " +
                    $"configs={observation.ConfigurationCount}, " +
                    $"frames={observation.FrameCount}, " +
                    $"payloadMiB={observation.PayloadBytes / (1024d * 1024d):F1}, " +
                    $"privateMiB={observation.BaselineResources.PrivateBytes / (1024d * 1024d):F1}->" +
                    $"{observation.FinalResources.PrivateBytes / (1024d * 1024d):F1}, " +
                    $"privatePeakMiB={observation.PeakPrivateBytes / (1024d * 1024d):F1}, " +
                    $"managedMiB={observation.BaselineResources.ManagedBytes / (1024d * 1024d):F1}->" +
                    $"{observation.FinalResources.ManagedBytes / (1024d * 1024d):F1}, " +
                    $"managedPeakMiB={observation.PeakManagedBytes / (1024d * 1024d):F1}, " +
                    $"workingSetPeakMiB={observation.PeakWorkingSetBytes / (1024d * 1024d):F1}, " +
                    $"handles={observation.BaselineResources.HandleCount}->" +
                    $"{observation.FinalResources.HandleCount}, " +
                    $"handlePeak={observation.PeakHandleCount}");
                return 0;
            }

            IReadOnlyList<IPeelBinaryPacket> shortPackets = packets ??
                throw new InvalidDataException(
                    "The authenticated Host stream did not return short-run packets.");
            var configuration = shortPackets[0] as VideoConfigPacket ??
                throw new InvalidDataException(
                    "The authenticated Host stream did not begin with video configuration.");
            Equal<uint>(1, configuration.WindowId);
            Equal(PeelVideoCodec.H264, configuration.Codec);
            Equal((byte)4, configuration.NalUnitHeaderLength);
            Equal(7, configuration.Sps[0] & 0x1F);
            Equal(8, configuration.Pps[0] & 0x1F);

            long previousTimestamp = -1;
            long payloadBytes = 0;
            for (var index = 1; index <= targetFrameCount; index++)
            {
                var frame = shortPackets[index] as VideoFramePacket ??
                    throw new InvalidDataException(
                        "The authenticated Host stream emitted a non-frame packet.");
                Equal<uint>(1, frame.WindowId);
                True(frame.PtsValue > previousTimestamp);
                True(frame.DurationValue > 0);
                ValidateLengthPrefixedH264(frame.Payload);
                previousTimestamp = frame.PtsValue;
                payloadBytes = checked(payloadBytes + frame.Payload.Length);
            }

            True(((VideoFramePacket)shortPackets[1]).IsKeyframe);
            Console.WriteLine(
                "PASS native authenticated Host listener: " +
                $"loopback TLS-PSK, {configuration.Width}x{configuration.Height}, " +
                $"frames={targetFrameCount}, payloadBytes={payloadBytes}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native authenticated Host listener: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(preSharedKey);
            if (credential is not null)
            {
                CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            }
        }
    }

    private static async Task<int> RunNativeSustainedMultiListenerStreamSmokeAsync(
        TimeSpan duration)
    {
        const string identity = "native-sustained-multi-listener-smoke-client";
        byte[] preSharedKey = RandomNumberGenerator.GetBytes(
            PeelPskSecurityProfile.PreSharedKeyLength);
        PeelPskCredential? credential = null;

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native sustained multi-window Host listener smoke requires " +
                "Windows 10 version 2004 or later.");
            CryptographicOperations.ZeroMemory(preSharedKey);
            return 2;
        }

        try
        {
            if (duration <= TimeSpan.Zero)
            {
                throw new ArgumentOutOfRangeException(nameof(duration));
            }

            using var firstSmokeWindow = new NativeCaptureSmokeWindow(
                "Peel Sustained Multi-Window Smoke A");
            using var secondSmokeWindow = new NativeCaptureSmokeWindow(
                "Peel Sustained Multi-Window Smoke B");
            WindowDescriptor[] windows = await Task.WhenAll(
                    firstSmokeWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)),
                    secondSmokeWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)))
                .ConfigureAwait(false);
            credential = new PeelPskCredential(identity, preSharedKey);
            var credentialResolver = new StaticPskCredentialResolver(credential);
            var transport = new BouncyCastlePskTransportFactory();
            var controlOptions = new HostControlSessionOptions(
                "Peel Windows Sustained Multi-Window Listener Smoke",
                Environment.OSVersion.VersionString,
                "validation");
            var controlSessions = new HostControlSessionManager(
                new FakeWindowEnumerator(windows),
                controlOptions);
            var videoOptions = new HostVideoSessionOptions(
                new VideoEncodingSettings(
                    VideoCodec.H264,
                    windows[0].Bounds.Width,
                    windows[0].Bounds.Height,
                    30,
                    4_000_000));
            var videoSessions = new HostVideoSessionManager(
                controlSessions,
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory(),
                videoOptions);
            await using var host = new HostAuthenticatedListener(
                transport,
                credentialResolver,
                controlSessions,
                videoSessions,
                new HostAuthenticatedListenerOptions(
                    acceptWorkerCount: 2,
                    maximumActiveConnections: 4));
            using var timeoutCancellation = new CancellationTokenSource(
                duration + TimeSpan.FromMinutes(2));
            await host.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            var endpoint = host.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException(
                    "The Host listener did not publish a TCP endpoint.");

            await using Stream controlStream = await transport.ConnectAsync(
                    new DnsEndPoint(IPAddress.Loopback.ToString(), endpoint.Port),
                    credential,
                    timeoutCancellation.Token)
                .ConfigureAwait(false);
            byte[] controlRequest = CombineLines(
                PeelHello.CreateClient(
                    identity,
                    "Native Sustained Multi-Window Listener Client",
                    "Windows",
                    capabilities: VideoCapabilities()),
                new PeelRequest(PeelMessageType.RequestWindowList));
            await controlStream.WriteAsync(controlRequest, timeoutCancellation.Token)
                .ConfigureAwait(false);
            await controlStream.FlushAsync(timeoutCancellation.Token).ConfigureAwait(false);

            _ = PeelJson.Deserialize<HostHelloMessage>(
                await ReadNetworkLineAsync(
                        controlStream,
                        HostControlSessionOptions.DefaultMaximumFirstLineBytes,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false));
            WindowListMessage windowList = PeelJson.Deserialize<WindowListMessage>(
                await ReadNetworkLineAsync(
                        controlStream,
                        HostControlSessionOptions.DefaultMaximumControlLineBytes,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false));
            Equal(2, windowList.Windows.Count);
            uint[] windowIds = windowList.Windows
                .Select(static window => window.WindowId)
                .Order()
                .ToArray();
            True(windowIds.SequenceEqual([1U, 2U]));

            using var animationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCancellation.Token);
            Task firstAnimation = AnimateNativeSmokeWindowAsync(
                firstSmokeWindow,
                animationCancellation.Token);
            Task secondAnimation = AnimateNativeSmokeWindowAsync(
                secondSmokeWindow,
                animationCancellation.Token);
            SustainedVideoObservation[] observations;
            try
            {
                await using Stream firstVideoStream = await ConnectVideoStreamAsync(
                        transport,
                        credential,
                        endpoint.Port,
                        windowIds[0],
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await using Stream secondVideoStream = await ConnectVideoStreamAsync(
                        transport,
                        credential,
                        endpoint.Port,
                        windowIds[1],
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);

                Task<SustainedVideoObservation> firstObservation =
                    ObserveSustainedVideoStreamAsync(
                        firstVideoStream,
                        videoOptions.MaximumEncodedPacketBytes,
                        windowIds[0],
                        duration,
                        timeoutCancellation.Token);
                Task<SustainedVideoObservation> secondObservation =
                    ObserveSustainedVideoStreamAsync(
                        secondVideoStream,
                        videoOptions.MaximumEncodedPacketBytes,
                        windowIds[1],
                        duration,
                        timeoutCancellation.Token);
                observations = await Task.WhenAll(firstObservation, secondObservation)
                    .ConfigureAwait(false);

                await SendStreamRequestAsync(
                        controlStream,
                        PeelMessageType.StopStream,
                        windowIds[0],
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await SendStreamRequestAsync(
                        controlStream,
                        PeelMessageType.StopStream,
                        windowIds[1],
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await Task.WhenAll(
                        WaitForStreamEndAsync(
                            firstVideoStream,
                            videoOptions.MaximumEncodedPacketBytes,
                            timeoutCancellation.Token),
                        WaitForStreamEndAsync(
                            secondVideoStream,
                            videoOptions.MaximumEncodedPacketBytes,
                            timeoutCancellation.Token))
                    .ConfigureAwait(false);
            }
            finally
            {
                animationCancellation.Cancel();
                await IgnoreExpectedCancellationAsync(
                        firstAnimation,
                        animationCancellation.Token)
                    .ConfigureAwait(false);
                await IgnoreExpectedCancellationAsync(
                        secondAnimation,
                        animationCancellation.Token)
                    .ConfigureAwait(false);
            }

            long baselinePrivateBytes = observations.Min(
                static observation => observation.BaselineResources.PrivateBytes);
            long finalPrivateBytes = observations.Max(
                static observation => observation.FinalResources.PrivateBytes);
            long baselineManagedBytes = observations.Min(
                static observation => observation.BaselineResources.ManagedBytes);
            long finalManagedBytes = observations.Max(
                static observation => observation.FinalResources.ManagedBytes);
            int baselineHandles = observations.Min(
                static observation => observation.BaselineResources.HandleCount);
            int finalHandles = observations.Max(
                static observation => observation.FinalResources.HandleCount);
            Console.WriteLine(
                "PASS native sustained simultaneous authenticated Host listener: " +
                $"durationSeconds={observations.Min(static observation => observation.Duration.TotalSeconds):F0}, " +
                $"streams={observations.Length}, " +
                $"configs={observations.Sum(static observation => observation.ConfigurationCount)}, " +
                $"frames={string.Join('+', observations.Select(static observation => observation.FrameCount))}, " +
                $"payloadMiB={observations.Sum(static observation => observation.PayloadBytes) / (1024d * 1024d):F1}, " +
                $"privateMiB={baselinePrivateBytes / (1024d * 1024d):F1}->" +
                $"{finalPrivateBytes / (1024d * 1024d):F1}, " +
                $"privatePeakMiB={observations.Max(static observation => observation.PeakPrivateBytes) / (1024d * 1024d):F1}, " +
                $"managedMiB={baselineManagedBytes / (1024d * 1024d):F1}->" +
                $"{finalManagedBytes / (1024d * 1024d):F1}, " +
                $"managedPeakMiB={observations.Max(static observation => observation.PeakManagedBytes) / (1024d * 1024d):F1}, " +
                $"workingSetPeakMiB={observations.Max(static observation => observation.PeakWorkingSetBytes) / (1024d * 1024d):F1}, " +
                $"handles={baselineHandles}->{finalHandles}, " +
                $"handlePeak={observations.Max(static observation => observation.PeakHandleCount)}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native sustained simultaneous authenticated Host listener: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(preSharedKey);
            if (credential is not null)
            {
                CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            }
        }
    }

    private static async Task<int> RunNativeResizeStreamSmokeAsync(bool gpuInput = false)
    {
        const string identity = "native-resize-smoke-client";
        long gpuBefore = Interlocked.Read(ref MediaFoundationH264Transform.GpuInputsSubmitted);
        const int requiredFramesPerResize = 3;
        const int requiredFramesAfterRestore = 5;
        (int Width, int Height)[] resizeSequence =
        [
            (520, 380),
            (680, 460),
            (440, 620),
            (760, 340),
            (560, 540),
            (640, 420),
        ];

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host resize smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            using var smokeWindow = new NativeCaptureSmokeWindow();
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            var settings = new VideoEncodingSettings(
                VideoCodec.H264,
                window.Bounds.Width,
                window.Bounds.Height,
                30,
                4_000_000, gpuInput);
            var options = new HostVideoSessionOptions(settings);
            HostVideoBinding binding = CreateVideoBinding(identity, window);
            using var timeoutCancellation = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            using var sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                timeoutCancellation.Token);
            var restoredFrames = new TaskCompletionSource(
                TaskCreationOptions.RunContinuationsAsynchronously);
            var configurationCount = 0;
            var framesInCurrentConfiguration = 0;
            var restoreStarted = 0;
            var framesAfterRestore = 0;
            var stream = new ScriptedDuplexStream(
                [],
                writeObserver: bytes =>
                {
                    if (bytes.IsEmpty)
                    {
                        return;
                    }

                    if (bytes.Span[0] == (byte)PeelBinaryPacketType.VideoConfig)
                    {
                        Volatile.Write(ref framesInCurrentConfiguration, 0);
                        Interlocked.Increment(ref configurationCount);
                    }
                    else if (bytes.Span[0] == (byte)PeelBinaryPacketType.VideoFrame)
                    {
                        Interlocked.Increment(ref framesInCurrentConfiguration);
                        if (Volatile.Read(ref restoreStarted) != 0 &&
                            Interlocked.Increment(ref framesAfterRestore) >= requiredFramesAfterRestore)
                        {
                            restoredFrames.TrySetResult();
                        }
                    }
                });
            await using var connection = new PeelPskConnection(stream, identity);
            using var writer = new HostVideoPacketWriter(
                connection,
                binding,
                options,
                static () => true);
            var orchestrator = new HostStreamOrchestrator(
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory());
            Task animation = AnimateNativeSmokeWindowAsync(
                smokeWindow,
                sessionCancellation.Token);
            Task streaming = orchestrator.RunEncodedWindowStreamAsync(
                window,
                settings,
                writer.SendEncodedFrameAsync,
                static () => true,
                sessionCancellation.Token);

            try
            {
                await WaitForMinimumAsync(
                        () => Volatile.Read(ref configurationCount),
                        minimum: 1,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);
                await WaitForMinimumAsync(
                        () => Volatile.Read(ref framesInCurrentConfiguration),
                        requiredFramesPerResize,
                        timeoutCancellation.Token)
                    .ConfigureAwait(false);

                foreach ((int width, int height) in resizeSequence)
                {
                    int previousConfigurationCount = Volatile.Read(ref configurationCount);
                    smokeWindow.Resize(width, height);
                    await WaitForMinimumAsync(
                            () => Volatile.Read(ref configurationCount),
                            checked(previousConfigurationCount + 1),
                            timeoutCancellation.Token)
                        .ConfigureAwait(false);
                    await WaitForMinimumAsync(
                            () => Volatile.Read(ref framesInCurrentConfiguration),
                            requiredFramesPerResize,
                            timeoutCancellation.Token)
                        .ConfigureAwait(false);
                }

                smokeWindow.SetMinimized(minimized: true);
                await Task.Delay(TimeSpan.FromSeconds(1), timeoutCancellation.Token)
                    .ConfigureAwait(false);
                if (streaming.IsCompleted)
                {
                    throw new InvalidDataException(
                        "The Host video pipeline ended while the window was minimized.");
                }

                smokeWindow.SetMinimized(minimized: false);
                Volatile.Write(ref restoreStarted, 1);
                await restoredFrames.Task
                    .WaitAsync(TimeSpan.FromSeconds(10), timeoutCancellation.Token)
                    .ConfigureAwait(false);
            }
            finally
            {
                sessionCancellation.Cancel();
                try
                {
                    await streaming.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (sessionCancellation.IsCancellationRequested)
                {
                }

                try
                {
                    await animation.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (sessionCancellation.IsCancellationRequested)
                {
                }
            }

            IReadOnlyList<IPeelBinaryPacket> packets =
                new PeelBinaryPacketReader(options.MaximumEncodedPacketBytes)
                    .Append(stream.WrittenBytes);
            var configurations = packets.OfType<VideoConfigPacket>().ToArray();
            True(configurations.Length >= resizeSequence.Length + 1);
            True(configurations
                .Select(static configuration => (configuration.Width, configuration.Height))
                .Distinct()
                .Count() >= resizeSequence.Length + 1);

            long previousTimestamp = -1;
            var keyframesAfterConfiguration = 0;
            for (var index = 0; index < packets.Count; index++)
            {
                if (packets[index] is VideoConfigPacket)
                {
                    if (index + 1 >= packets.Count ||
                        packets[index + 1] is not VideoFramePacket { IsKeyframe: true })
                    {
                        throw new InvalidDataException(
                            "A resized Host encoder generation did not restart at a keyframe.");
                    }

                    keyframesAfterConfiguration++;
                    continue;
                }

                var frame = packets[index] as VideoFramePacket ??
                    throw new InvalidDataException("The Host emitted an unknown video packet.");
                True(frame.PtsValue > previousTimestamp);
                ValidateLengthPrefixedH264(frame.Payload);
                previousTimestamp = frame.PtsValue;
            }

            Equal(configurations.Length, keyframesAfterConfiguration);
            True(Volatile.Read(ref framesAfterRestore) >= requiredFramesAfterRestore);
            int distinctSizeCount = configurations
                .Select(static configuration => (configuration.Width, configuration.Height))
                .Distinct()
                .Count();
            long gpuInputs = Interlocked.Read(ref MediaFoundationH264Transform.GpuInputsSubmitted) - gpuBefore;
            if (gpuInput) True(gpuInputs >= configurations.Length * requiredFramesPerResize);
            Console.WriteLine(
                "PASS native Host repeated-resize/minimize recovery: " +
                $"configs={configurations.Length}, " +
                $"distinctSizes={distinctSizeCount}, " +
                $"framesAfterRestore={framesAfterRestore}, gpuInputs={gpuInputs}");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host resize/minimize recovery: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeElevatedInputTargetAsync(string stateDirectory)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native elevated input target requires Windows 10 version 2004 or later.");
            return 2;
        }

        string stateRoot = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(stateRoot);
        string readyPath = Path.Combine(stateRoot, "elevated-target-ready.json");
        string finishPath = Path.Combine(stateRoot, "elevated-target-finish.txt");
        string resultPath = Path.Combine(stateRoot, "elevated-target-result.json");
        string failurePath = Path.Combine(stateRoot, "elevated-target-failed.txt");
        foreach (string path in new[] { readyPath, finishPath, resultPath, failurePath })
        {
            File.Delete(path);
        }

        try
        {
            if (!IsCurrentProcessElevated())
            {
                throw new InvalidOperationException(
                    "The controlled elevated input target is not running with an administrator token.");
            }

            const string title = "Peel Elevated Input Target";
            using var smokeWindow = new NativeCaptureSmokeWindow(title);
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            var targetState = new ElevatedInputTargetState(
                window.Handle.ToInt64(),
                window.ProcessId,
                window.ClassName,
                window.Title,
                IsAdministrator: true);
            File.WriteAllText(
                readyPath,
                JsonSerializer.Serialize(targetState),
                new UTF8Encoding(false));

            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            await WaitForFileAsync(finishPath, timeout.Token).ConfigureAwait(false);
            await Task.Delay(TimeSpan.FromMilliseconds(250), timeout.Token)
                .ConfigureAwait(false);
            File.WriteAllText(
                resultPath,
                JsonSerializer.Serialize(new ElevatedInputTargetResult(
                    smokeWindow.InputSnapshot)),
                new UTF8Encoding(false));
            Console.WriteLine("PASS controlled elevated input target: no input accepted");
            return 0;
        }
        catch (Exception exception)
        {
            File.WriteAllText(
                failurePath,
                $"{exception.GetType().Name}: {exception.Message}",
                new UTF8Encoding(false));
            Console.Error.WriteLine(
                "FAIL controlled elevated input target: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeElevatedInputSmokeAsync(string stateDirectory)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native elevated input smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        string stateRoot = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(stateRoot);
        string readyPath = Path.Combine(stateRoot, "elevated-target-ready.json");
        string finishPath = Path.Combine(stateRoot, "elevated-target-finish.txt");
        string targetResultPath = Path.Combine(stateRoot, "elevated-target-result.json");
        string targetFailurePath = Path.Combine(stateRoot, "elevated-target-failed.txt");

        try
        {
            if (IsCurrentProcessElevated())
            {
                throw new InvalidOperationException(
                    "The Host-side elevated input smoke must run with a limited token.");
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            await WaitForFileOrAbortAsync(
                    readyPath,
                    targetFailurePath,
                    timeout.Token)
                .ConfigureAwait(false);
            ElevatedInputTargetState targetState = JsonSerializer.Deserialize<ElevatedInputTargetState>(
                File.ReadAllText(readyPath)) ??
                throw new InvalidDataException("The elevated target state was invalid.");
            if (!targetState.IsAdministrator)
            {
                throw new InvalidDataException(
                    "The controlled target did not report an elevated administrator token.");
            }

            var window = new WindowDescriptor(
                checked((nint)targetState.Handle),
                targetState.ProcessId,
                null,
                targetState.ClassName,
                targetState.Title,
                new WindowBounds(0, 0, 100, 100));
            var gate = new InputPermissionGate();
            gate.SetEnabled(true);
            using var session = new WindowsHostInputSession(
                gate,
                new WindowsWindowInputTargetResolver(),
                new WindowsInputInjector(gate));
            InputInjectionResult result = session.HandleKeyboardText(
                new KeyboardTextMessage("Z", WindowId: 1),
                window);
            if (result.Succeeded)
            {
                throw new InvalidDataException(
                    "The limited Host reported successful input into the elevated target.");
            }

            if (result.Error?.Contains("UIPI", StringComparison.OrdinalIgnoreCase) != true &&
                result.Error?.Contains("integrity-level", StringComparison.OrdinalIgnoreCase) != true)
            {
                throw new InvalidDataException(
                    $"The elevated-target rejection was not attributed to integrity isolation: {result.Error}");
            }

            File.WriteAllText(finishPath, "finish", new UTF8Encoding(false));
            await WaitForFileOrAbortAsync(
                    targetResultPath,
                    targetFailurePath,
                    timeout.Token)
                .ConfigureAwait(false);
            ElevatedInputTargetResult targetResult =
                JsonSerializer.Deserialize<ElevatedInputTargetResult>(
                    File.ReadAllText(targetResultPath)) ??
                throw new InvalidDataException("The elevated target result was invalid.");
            Equal(0, targetResult.Input.KeyDownCount);
            Equal(0, targetResult.Input.KeyUpCount);
            Equal(0, targetResult.Input.CharacterCount);

            Console.WriteLine(
                "PASS native elevated-target input: limited Host rejected input through UIPI; " +
                "controlled target received no key or character event");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native elevated-target input: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            if (File.Exists(readyPath) && !File.Exists(finishPath))
            {
                File.WriteAllText(finishPath, "finish", new UTF8Encoding(false));
            }
        }
    }

    private static bool IsCurrentProcessElevated()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static async Task<int> RunNativeKeyboardInputSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host keyboard input smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            using var smokeWindow = new NativeCaptureSmokeWindow();
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            var gate = new InputPermissionGate();
            gate.SetEnabled(true);
            using var session = new WindowsHostInputSession(
                gate,
                new WindowsWindowInputTargetResolver(),
                new WindowsInputInjector(gate));
            RequireInputSuccess(session.HandleKeyboardText(
                new KeyboardTextMessage("Z", WindowId: 1),
                window));
            RequireInputSuccess(session.HandleKeyboardCommand(
                new KeyboardCommandMessage(KeyboardCommand.F2, WindowId: 1),
                window));

            NativeInputSnapshot snapshot = await smokeWindow.WaitForInputAsync(
                    static value =>
                        value.KeyDownCount >= 2 &&
                        value.KeyUpCount >= 2 &&
                        value.CharacterCount >= 1,
                    TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            Equal('Z', snapshot.LastCharacter);
            Equal<ushort>(0x71, snapshot.LastVirtualKey);
            Console.WriteLine(
                "PASS native Host keyboard input: same-integrity text and F2 delivered");

            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                225, [], WindowId: 1, Action: KeyboardCommandAction.Down), window));
            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.Shift], WindowId: 1, Characters: "A",
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down), window));
            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.Shift], WindowId: 1, Characters: "A",
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Up), window));
            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                225, [], WindowId: 1, Action: KeyboardCommandAction.Up), window));
            NativeInputSnapshot shifted = await smokeWindow.WaitForInputAsync(
                value => value.KeyDownCount >= snapshot.KeyDownCount + 2 &&
                    value.KeyUpCount >= snapshot.KeyUpCount + 2 &&
                    value.CharacterCount >= snapshot.CharacterCount + 1,
                TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            Equal('A', shifted.LastCharacter);

            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                225, [], WindowId: 1, Action: KeyboardCommandAction.Down), window));
            RequireInputSuccess(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down), window));
            _ = await smokeWindow.WaitForInputAsync(
                value => value.KeyDownCount >= shifted.KeyDownCount + 2,
                TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            gate.SetEnabled(false);
            _ = await smokeWindow.WaitForInputAsync(
                value => value.KeyUpCount >= shifted.KeyUpCount + 2,
                TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            Console.WriteLine(
                "PASS native Mac hardware input: Shift+A snapshot and consent-revoke key release");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host keyboard input: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeInputSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host input smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            using var smokeWindow = new NativeCaptureSmokeWindow();
            WindowDescriptor window = await smokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            var gate = new InputPermissionGate();
            gate.SetEnabled(true);
            var session = new WindowsHostInputSession(
                gate,
                new WindowsWindowInputTargetResolver(),
                new WindowsInputInjector(gate));
            try
            {
                RequireInputSuccess(session.HandleMouse(
                    new PeelRequest(PeelMessageType.MouseClick, 1, 0.5, 0.5, "left"),
                    window));
                RequireInputSuccess(session.HandleMouse(
                    new PeelRequest(PeelMessageType.MouseScroll, 1, 0, 240),
                    window));
                RequireInputSuccess(session.HandleKeyboardText(
                    new KeyboardTextMessage("Z", WindowId: 1),
                    window));
                RequireInputSuccess(session.HandleKeyboardHardwareKey(
                    new KeyboardHardwareKeyMessage(
                        KeyCode: 47,
                        Modifiers: [],
                        WindowId: 1,
                        Characters: "[",
                        CharactersIgnoringModifiers: "["),
                    window));
                _ = await smokeWindow.WaitForInputAsync(
                        static value => value.LastVirtualKey == 0xDB,
                        TimeSpan.FromSeconds(5))
                    .ConfigureAwait(false);
                RequireInputSuccess(session.HandleKeyboardHardwareKey(
                    new KeyboardHardwareKeyMessage(
                        KeyCode: 80,
                        Modifiers: [],
                        WindowId: 1),
                    window));
                _ = await smokeWindow.WaitForInputAsync(
                        static value => value.LastVirtualKey == 0x25,
                        TimeSpan.FromSeconds(5))
                    .ConfigureAwait(false);
                for (var index = 0; index < 4; index++)
                {
                    RequireInputSuccess(session.HandleMouse(
                        new PeelRequest(PeelMessageType.MouseScroll, 1, 0, 0.6),
                        window));
                }
                RequireInputSuccess(session.HandleKeyboardCommand(
                    new KeyboardCommandMessage(KeyboardCommand.F2, WindowId: 1),
                    window));
                RequireInputSuccess(session.HandleMouse(
                    new PeelRequest(PeelMessageType.MouseDown, 1, 0.6, 0.6, "right"),
                    window));
            }
            finally
            {
                session.Dispose();
            }

            NativeInputSnapshot snapshot;
            try
            {
                snapshot = await smokeWindow.WaitForInputAsync(
                        static value =>
                            value.MouseMoveCount >= 1 &&
                            value.LeftDownCount >= 1 &&
                            value.LeftUpCount >= 1 &&
                            value.RightDownCount >= 1 &&
                            value.RightUpCount >= 1 &&
                            value.WheelCount >= 2 &&
                            value.KeyDownCount >= 1 &&
                            value.KeyUpCount >= 1 &&
                            value.CharacterCount >= 2,
                        TimeSpan.FromSeconds(5))
                    .ConfigureAwait(false);
            }
            catch (TimeoutException exception)
            {
                throw new TimeoutException(
                    $"{exception.Message} {smokeWindow.ReadPointerDiagnostic(window.Bounds)}",
                    exception);
            }
            Equal('[', snapshot.LastCharacter);
            Equal<ushort>(0x71, snapshot.LastVirtualKey);
            Console.WriteLine(
                "PASS native Host input: exact HWND focus, pointer/click/fractional scroll, " +
                "text/HID keys, held-button release");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host input: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static async Task<int> RunNativeFocusSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host focus smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        try
        {
            using var firstSmokeWindow = new NativeCaptureSmokeWindow("Peel Focus Smoke A");
            using var secondSmokeWindow = new NativeCaptureSmokeWindow("Peel Focus Smoke B");
            WindowDescriptor firstWindow = await firstSmokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            WindowDescriptor secondWindow = await secondSmokeWindow.Window
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            var gate = new InputPermissionGate();
            using var session = new WindowsHostInputSession(
                gate,
                new WindowsWindowInputTargetResolver(),
                new WindowsInputInjector(gate));

            gate.SetEnabled(true);
            RequireInputSuccess(session.HandleClientActiveWindow(secondWindow));
            Equal(secondWindow.Handle, NativeMethods.GetForegroundWindow());
            RequireInputSuccess(session.HandleClientActiveWindow(firstWindow));
            Equal(firstWindow.Handle, NativeMethods.GetForegroundWindow());

            gate.SetEnabled(false);
            InputInjectionResult blocked = session.HandleClientActiveWindow(secondWindow);
            True(!blocked.Succeeded);
            True(blocked.Error?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true);
            Equal(firstWindow.Handle, NativeMethods.GetForegroundWindow());

            Console.WriteLine(
                "PASS native Host focus: active-window requests switched exact HWNDs; " +
                "disabled gate blocked the next switch");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host focus: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
    }

    private static int RunNativeCredentialSmoke()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Native credential smoke requires Windows.");
            return 2;
        }

        string pairingId = $"peel-credential-smoke-{Guid.NewGuid():N}";
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-credential-smoke-{Guid.NewGuid():N}");
        string metadataPath = Path.Combine(temporaryDirectory, "paired-clients.json");
        string credentialTarget = WindowsPairedClientStore.CredentialTarget(
            WindowsPairedClientStore.DefaultCredentialTargetPrefix,
            pairingId);
        byte[] key = RandomNumberGenerator.GetBytes(
            WindowsPairedClientStore.PreSharedKeyBytes);
        var vault = new WindowsCredentialManager();

        try
        {
            var store = new WindowsPairedClientStore(metadataPath);
            _ = store.AddOrReplace(
                pairingId,
                "Peel Credential Smoke",
                $"credential-smoke-device-{Guid.NewGuid():N}",
                key);

            string metadata = File.ReadAllText(metadataPath);
            if (metadata.Contains("psk", StringComparison.OrdinalIgnoreCase) ||
                metadata.Contains("preSharedKey", StringComparison.OrdinalIgnoreCase) ||
                metadata.Contains(Convert.ToBase64String(key), StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The non-secret paired-client metadata contained credential material.");
            }

            if (!store.TryResolve(pairingId, out PeelPskCredential? resolved) ||
                resolved is null)
            {
                throw new InvalidDataException(
                    "The stored current-user credential could not be resolved.");
            }

            try
            {
                if (!resolved.PreSharedKey.AsSpan().SequenceEqual(key))
                {
                    throw new InvalidDataException(
                        "Windows Credential Manager returned different credential bytes.");
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(resolved.PreSharedKey);
            }

            True(store.UpdateLastSeen(pairingId));
            True(store.Remove(pairingId));
            if (vault.TryRead(credentialTarget, out byte[]? leftover))
            {
                if (leftover is not null)
                {
                    CryptographicOperations.ZeroMemory(leftover);
                }

                throw new InvalidDataException(
                    "The native credential remained after paired-client removal.");
            }

            Console.WriteLine(
                "PASS native Host credential store: current-user generic credential, " +
                "separate metadata, exact resolve, delete");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host credential store: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            try
            {
                _ = vault.Delete(credentialTarget);
            }
            catch (Win32Exception)
            {
            }

            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static async Task<int> RunNativePairingSmokeAsync()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Native pairing smoke requires Windows.");
            return 2;
        }

        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-pairing-smoke-{Guid.NewGuid():N}");
        string metadataPath = Path.Combine(temporaryDirectory, "paired-clients.json");
        string hostId = $"peel-windows-host-smoke-{Guid.NewGuid():N}";
        string clientDeviceId = $"peel-client-smoke-{Guid.NewGuid():N}";
        var store = new WindowsPairedClientStore(metadataPath);
        var vault = new WindowsCredentialManager();
        HostPairingPin pin = HostPairingPin.Generate();
        byte[] pinPreSharedKey = pin.DerivePreSharedKey(hostId);
        var credential = new PeelPskCredential(
            PeelPinPairing.TlsIdentity,
            pinPreSharedKey);
        PairResponseMessage? accepted = null;

        try
        {
            var transport = new BouncyCastlePskTransportFactory();
            await using var listener = new HostPinPairingListener(
                transport,
                store,
                hostId,
                Environment.MachineName,
                $"Peel on {Environment.MachineName}",
                pin,
                new HostPinPairingListenerOptions(
                    acceptWorkerCount: 1,
                    maximumActiveConnections: 2));
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await listener.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    cancellation.Token)
                .ConfigureAwait(false);
            var endpoint = listener.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException("The native pairing listener did not publish an endpoint.");

            accepted = await SendPairingRequestAsync(
                    transport,
                    endpoint,
                    credential,
                    new PairRequestMessage(
                        "Native Pairing Client",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(
                            pinPreSharedKey,
                            hostId,
                            clientDeviceId)),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(accepted.Accepted);
            Equal(WindowsPairedClientStore.PreSharedKeyBytes, accepted.Psk.Length);
            Equal(1, store.Snapshot().Count);
            Equal(clientDeviceId, store.Snapshot()[0].DeviceId);

            string metadata = File.ReadAllText(metadataPath);
            True(!metadata.Contains("psk", StringComparison.OrdinalIgnoreCase));
            True(!metadata.Contains("preSharedKey", StringComparison.OrdinalIgnoreCase));
            True(!metadata.Contains(Convert.ToBase64String(accepted.Psk), StringComparison.Ordinal));

            True(store.TryResolve(accepted.PairingId, out PeelPskCredential? resolved));
            PeelPskCredential resolvedCredential = resolved ??
                throw new InvalidDataException("The native paired credential did not resolve.");
            try
            {
                True(resolvedCredential.PreSharedKey.AsSpan().SequenceEqual(accepted.Psk));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(resolvedCredential.PreSharedKey);
            }

            True(store.Remove(accepted.PairingId));
            string credentialTarget = WindowsPairedClientStore.CredentialTarget(
                WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                accepted.PairingId);
            if (vault.TryRead(credentialTarget, out byte[]? leftover))
            {
                if (leftover is not null)
                {
                    CryptographicOperations.ZeroMemory(leftover);
                }

                throw new InvalidDataException(
                    "The native pairing credential remained after removal.");
            }

            Console.WriteLine(
                "PASS native Host PIN pairing: Apple-compatible TLS/proof, " +
                "current-user credential persist/resolve/delete");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host PIN pairing: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            foreach (HostPairedClient peer in store.Snapshot())
            {
                string target = WindowsPairedClientStore.CredentialTarget(
                    WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                    peer.PairingId);
                try
                {
                    _ = store.Remove(peer.PairingId);
                }
                catch (Exception)
                {
                }

                try
                {
                    _ = vault.Delete(target);
                }
                catch (Win32Exception)
                {
                }
            }

            CryptographicOperations.ZeroMemory(pinPreSharedKey);
            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            if (accepted is not null)
            {
                CryptographicOperations.ZeroMemory(accepted.Psk);
            }

            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static async Task<int> RunNativeRuntimeSmokeAsync()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Native Host runtime smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        string uniqueId = Guid.NewGuid().ToString("N");
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-runtime-smoke-{uniqueId}");
        string metadataPath = Path.Combine(temporaryDirectory, "paired-clients.json");
        string identityPath = Path.Combine(temporaryDirectory, "host-id.txt");
        string clientDeviceId = $"peel-runtime-client-{uniqueId}";
        var store = new WindowsPairedClientStore(metadataPath);
        var vault = new WindowsCredentialManager();
        PairResponseMessage? accepted = null;
        byte[]? pairingKey = null;
        WindowsHostRuntime? runtime = null;

        try
        {
            using var smokeWindow = new NativeCaptureSmokeWindow();
            _ = await smokeWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            var options = new WindowsHostRuntimeOptions(
                hostName: $"Runtime Smoke {uniqueId[..8]}",
                appVersion: "native-runtime-smoke");
            runtime = new WindowsHostRuntime(
                new BouncyCastlePskTransportFactory(),
                new WindowsDnsSdRegistrar(),
                store,
                new WindowsHostIdentityStore(identityPath),
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory(),
                options,
                requireWindows: true);
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await runtime.StartAsync(cancellation.Token).ConfigureAwait(false);
            True(runtime.IsRunning);
            True(!runtime.InputPermission.IsEnabled);
            string hostId = runtime.HostId ??
                throw new InvalidDataException("The native Host runtime did not publish a stable ID.");
            HostPairingPin pin = runtime.PairingPin ??
                throw new InvalidDataException("The native Host runtime did not publish a PIN.");
            IPEndPoint controlEndPoint = runtime.ControlEndPoint ??
                throw new InvalidDataException("The native Host runtime has no control endpoint.");
            IPEndPoint pairingEndPoint = runtime.PairingEndPoint ??
                throw new InvalidDataException("The native Host runtime has no pairing endpoint.");

            PeelDiscoveredService controlService = await FindRuntimeServiceAsync(
                    PeelServiceType.Control,
                    hostId,
                    cancellation.Token)
                .ConfigureAwait(false);
            PeelDiscoveredService pairingService = await FindRuntimeServiceAsync(
                    PeelServiceType.Pairing,
                    hostId,
                    cancellation.Token)
                .ConfigureAwait(false);
            Equal((ushort)controlEndPoint.Port, controlService.Port);
            Equal((ushort)pairingEndPoint.Port, pairingService.Port);
            Equal("pin", controlService.PairingMode);
            Equal("pin", pairingService.PairingMode);
            Equal(pin.SaltBase64, controlService.PairingSaltBase64);
            Equal(pin.SaltBase64, pairingService.PairingSaltBase64);
            Equal(pairingEndPoint.Port.ToString(), controlService.GetUtf8Txt("pairPort"));
            Equal(HostPairingPin.StandardTlsPskOrder, controlService.TlsPskOrder);
            Equal(HostPairingPin.StandardTlsPskOrder, pairingService.TlsPskOrder);
            Equal(6, controlService.TxtRecords.Count);
            Equal(6, pairingService.TxtRecords.Count);

            pairingKey = pin.DerivePreSharedKey(hostId);
            var transport = new BouncyCastlePskTransportFactory();
            var temporaryCredential = new PeelPskCredential(
                PeelPinPairing.TlsIdentity,
                pairingKey);
            accepted = await SendPairingRequestAsync(
                    transport,
                    new IPEndPoint(IPAddress.Loopback, pairingEndPoint.Port),
                    temporaryCredential,
                    new PairRequestMessage(
                        "Native Runtime Client",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(pairingKey, hostId, clientDeviceId)),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(accepted.Accepted);
            Equal(1, runtime.PairedClientCount);
            DateTimeOffset pairedAt = store.Snapshot().Single().LastSeenAt ??
                throw new InvalidDataException("The paired client has no activity timestamp.");
            await Task.Delay(TimeSpan.FromMilliseconds(50), cancellation.Token)
                .ConfigureAwait(false);

            var pairedCredential = new PeelPskCredential(accepted.PairingId, accepted.Psk);
            await using (Stream controlStream = await transport.ConnectAsync(
                new DnsEndPoint(IPAddress.Loopback.ToString(), controlEndPoint.Port),
                pairedCredential,
                cancellation.Token).ConfigureAwait(false))
            {
                byte[] request = CombineLines(
                    PeelHello.CreateClient(
                        accepted.PairingId,
                        "Native Runtime Client",
                        "Windows",
                        capabilities: VideoCapabilities()),
                    new PeelRequest(PeelMessageType.RequestWindowList));
                await controlStream.WriteAsync(request, cancellation.Token).ConfigureAwait(false);
                await controlStream.FlushAsync(cancellation.Token).ConfigureAwait(false);

                HostHelloMessage hello = PeelJson.Deserialize<HostHelloMessage>(
                    await ReadNetworkLineAsync(
                            controlStream,
                            HostControlSessionOptions.DefaultMaximumFirstLineBytes,
                            cancellation.Token)
                        .ConfigureAwait(false));
                WindowListMessage windows = PeelJson.Deserialize<WindowListMessage>(
                    await ReadNetworkLineAsync(
                            controlStream,
                            HostControlSessionOptions.DefaultMaximumControlLineBytes,
                            cancellation.Token)
                        .ConfigureAwait(false));
                Equal(options.HostName, hello.HostName);
                True(windows.Windows.Count > 0);
                True(!runtime.InputPermission.IsEnabled);
            }

            DateTimeOffset reconnectedAt = store.Snapshot().Single().LastSeenAt ??
                throw new InvalidDataException("The reconnected client has no activity timestamp.");
            True(reconnectedAt > pairedAt);

            string previousSalt = pin.SaltBase64;
            await runtime.RefreshPairingAsync(cancellation.Token).ConfigureAwait(false);
            True(runtime.IsRunning);
            True(!StringComparer.Ordinal.Equals(previousSalt, runtime.PairingPin?.SaltBase64));
            True(store.Remove(accepted.PairingId));
            Equal(0, runtime.PairedClientCount);

            await runtime.DisposeAsync().ConfigureAwait(false);
            runtime = null;
            using var absence = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await AssertRuntimeServiceAbsentAsync(hostId, absence.Token).ConfigureAwait(false);

            Console.WriteLine(
                "PASS native Host runtime: stable identity, exact DNS-SD, rotating PIN, " +
                "credential reconnect, window list, input default off, clean goodbye");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL native Host runtime: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            if (runtime is not null)
            {
                await runtime.DisposeAsync().ConfigureAwait(false);
            }

            foreach (HostPairedClient peer in store.Snapshot())
            {
                string target = WindowsPairedClientStore.CredentialTarget(
                    WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                    peer.PairingId);
                try
                {
                    _ = store.Remove(peer.PairingId);
                }
                catch (Exception)
                {
                }

                try
                {
                    _ = vault.Delete(target);
                }
                catch (Win32Exception)
                {
                }
            }

            if (pairingKey is not null)
            {
                CryptographicOperations.ZeroMemory(pairingKey);
            }

            if (accepted is not null)
            {
                CryptographicOperations.ZeroMemory(accepted.Psk);
            }

            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static async Task<int> RunNativeExternalMultiWindowSmokeAsync(
        string stateDirectory)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "External multi-window smoke requires Windows 10 version 2004 or later.");
            return 2;
        }

        string stateRoot = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(stateRoot);
        string clientVisiblePath = Path.Combine(stateRoot, "client-visible.txt");
        string backgroundClientPath = Path.Combine(stateRoot, "background-client.txt");
        string clientBackgroundPath = Path.Combine(stateRoot, "client-background.txt");
        string foregroundClientPath = Path.Combine(stateRoot, "foreground-client.txt");
        string clientForegroundPath = Path.Combine(stateRoot, "client-foreground.txt");
        string twoStreamsReadyPath = Path.Combine(stateRoot, "two-streams-ready.txt");
        string stopFirstPath = Path.Combine(stateRoot, "stop-first.txt");
        string oneStreamReadyPath = Path.Combine(stateRoot, "one-stream-ready.txt");
        string finishPath = Path.Combine(stateRoot, "finish.txt");
        string streamsCompletePath = Path.Combine(stateRoot, "streams-complete.txt");
        string hostExitedPath = Path.Combine(stateRoot, "host-exited.txt");
        string passedPath = Path.Combine(stateRoot, "passed.txt");
        string failedPath = Path.Combine(stateRoot, "failed.txt");
        string[] markerPaths =
        [
            clientVisiblePath,
            backgroundClientPath,
            clientBackgroundPath,
            foregroundClientPath,
            clientForegroundPath,
            twoStreamsReadyPath,
            stopFirstPath,
            oneStreamReadyPath,
            finishPath,
            streamsCompletePath,
            hostExitedPath,
            passedPath,
            failedPath,
        ];
        foreach (string markerPath in markerPaths)
        {
            File.Delete(markerPath);
        }

        PairResponseMessage? accepted = null;
        byte[]? pairingKey = null;
        var pairingRemoved = false;

        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            string? enteredPin = await Console.In.ReadLineAsync(timeout.Token)
                .ConfigureAwait(false);
            string pin = new((enteredPin ?? string.Empty)
                .Where(static character => character is >= '0' and <= '9')
                .ToArray());
            if (pin.Length != PeelPinPairing.PinDigits)
            {
                throw new InvalidDataException("A six-digit production Host PIN is required on stdin.");
            }

            const string firstWindowTitle = "Peel Multi-Window Smoke A";
            const string secondWindowTitle = "Peel Multi-Window Smoke B";
            using var firstWindow = new NativeCaptureSmokeWindow(firstWindowTitle);
            using var secondWindow = new NativeCaptureSmokeWindow(secondWindowTitle);
            _ = await firstWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            _ = await secondWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

            var runtimeOptions = new WindowsHostRuntimeOptions();
            PeelDiscoveredService controlService = await FindRuntimeServiceByDisplayNameAsync(
                    PeelServiceType.Control,
                    runtimeOptions.ServiceName,
                    timeout.Token)
                .ConfigureAwait(false);
            PeelDiscoveredService pairingService = await FindRuntimeServiceByDisplayNameAsync(
                    PeelServiceType.Pairing,
                    runtimeOptions.PairingServiceName,
                    timeout.Token)
                .ConfigureAwait(false);
            string hostId = controlService.HostId ??
                throw new InvalidDataException("The production Host control service has no Host ID.");
            Equal(hostId, pairingService.HostId);
            Equal("pin", controlService.PairingMode);
            Equal("pin", pairingService.PairingMode);
            ushort controlPort = controlService.Port ??
                throw new InvalidDataException("The production Host control service has no port.");
            ushort pairingPort = pairingService.Port ??
                throw new InvalidDataException("The production Host pairing service has no port.");
            string saltBase64 = pairingService.PairingSaltBase64 ??
                throw new InvalidDataException("The production Host pairing service has no PIN salt.");
            byte[] salt = Convert.FromBase64String(saltBase64);
            try
            {
                pairingKey = PeelPinPairing.DerivePreSharedKey(pin, salt, hostId);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(salt);
            }

            string uniqueId = Guid.NewGuid().ToString("N");
            string clientDeviceId = $"peel-multi-window-runtime-{uniqueId}";
            var transport = new BouncyCastlePskTransportFactory();
            var temporaryCredential = new PeelPskCredential(
                PeelPinPairing.TlsIdentity,
                pairingKey);
            accepted = await SendPairingRequestAsync(
                    transport,
                    new IPEndPoint(IPAddress.Loopback, pairingPort),
                    temporaryCredential,
                    new PairRequestMessage(
                        "Peel multi-window validation",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(pairingKey, hostId, clientDeviceId)),
                    timeout.Token)
                .ConfigureAwait(false);
            if (!accepted.Accepted)
            {
                throw new InvalidDataException(
                    accepted.Reason ?? "The production Host rejected the validation pairing.");
            }

            var pairedCredential = new PeelPskCredential(accepted.PairingId, accepted.Psk);
            await using (Stream controlStream = await transport.ConnectAsync(
                new DnsEndPoint(IPAddress.Loopback.ToString(), controlPort),
                pairedCredential,
                timeout.Token).ConfigureAwait(false))
            {
                byte[] controlRequest = CombineLines(
                    PeelHello.CreateClient(
                        accepted.PairingId,
                        "Peel multi-window validation",
                        "Windows",
                        capabilities:
                        [
                            .. VideoCapabilities(),
                            PeelCapability.ClientVisibility,
                        ]),
                    new PeelRequest(PeelMessageType.RequestWindowList));
                await controlStream.WriteAsync(controlRequest, timeout.Token).ConfigureAwait(false);
                await controlStream.FlushAsync(timeout.Token).ConfigureAwait(false);

                HostHelloMessage hello = PeelJson.Deserialize<HostHelloMessage>(
                    await ReadNetworkLineAsync(
                            controlStream,
                            HostControlSessionOptions.DefaultMaximumFirstLineBytes,
                            timeout.Token)
                        .ConfigureAwait(false));
                True((hello.Capabilities ?? []).Contains(
                    PeelCapability.PerWindowVideoConnections,
                    StringComparer.Ordinal));
                WindowListMessage windows = PeelJson.Deserialize<WindowListMessage>(
                    await ReadNetworkLineAsync(
                            controlStream,
                            HostControlSessionOptions.DefaultMaximumControlLineBytes,
                            timeout.Token)
                        .ConfigureAwait(false));
                PeelWindow firstPeeledWindow = windows.Windows.Single(
                    window => StringComparer.Ordinal.Equals(window.Title, firstWindowTitle));
                PeelWindow secondPeeledWindow = windows.Windows.Single(
                    window => StringComparer.Ordinal.Equals(window.Title, secondWindowTitle));
                True(firstPeeledWindow.WindowId != secondPeeledWindow.WindowId);

                WriteMarker(clientVisiblePath);
                await WaitForFileOrAbortAsync(
                        backgroundClientPath,
                        hostExitedPath,
                        timeout.Token)
                    .ConfigureAwait(false);
                await controlStream.WriteAsync(
                        PeelJson.SerializeLine(new ClientVisibilityMessage(false)),
                        timeout.Token)
                    .ConfigureAwait(false);
                await controlStream.FlushAsync(timeout.Token).ConfigureAwait(false);
                WriteMarker(clientBackgroundPath);

                await WaitForFileOrAbortAsync(
                        foregroundClientPath,
                        hostExitedPath,
                        timeout.Token)
                    .ConfigureAwait(false);
                await controlStream.WriteAsync(
                        PeelJson.SerializeLine(new ClientVisibilityMessage(true)),
                        timeout.Token)
                    .ConfigureAwait(false);
                await controlStream.FlushAsync(timeout.Token).ConfigureAwait(false);
                WriteMarker(clientForegroundPath);

                using var animationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                    timeout.Token);
                Task firstAnimation = AnimateNativeSmokeWindowAsync(
                    firstWindow,
                    animationCancellation.Token);
                Task secondAnimation = AnimateNativeSmokeWindowAsync(
                    secondWindow,
                    animationCancellation.Token);
                try
                {
                    await using Stream firstVideoStream = await ConnectVideoStreamAsync(
                            transport,
                            pairedCredential,
                            controlPort,
                            firstPeeledWindow.WindowId,
                            timeout.Token)
                        .ConfigureAwait(false);
                    await using Stream secondVideoStream = await ConnectVideoStreamAsync(
                            transport,
                            pairedCredential,
                            controlPort,
                            secondPeeledWindow.WindowId,
                            timeout.Token)
                        .ConfigureAwait(false);

                    Task<IReadOnlyList<IPeelBinaryPacket>> firstPacketsTask =
                        ReadVideoPacketsAsync(
                            firstVideoStream,
                            HostVideoSessionOptions.DefaultMaximumEncodedPacketBytes,
                            4,
                            timeout.Token);
                    Task<IReadOnlyList<IPeelBinaryPacket>> secondPacketsTask =
                        ReadVideoPacketsAsync(
                            secondVideoStream,
                            HostVideoSessionOptions.DefaultMaximumEncodedPacketBytes,
                            4,
                            timeout.Token);
                    await Task.WhenAll(firstPacketsTask, secondPacketsTask).ConfigureAwait(false);
                    long firstLastTimestamp = ValidateNativeVideoPackets(
                        firstPacketsTask.Result,
                        firstPeeledWindow.WindowId);
                    long secondLastTimestamp = ValidateNativeVideoPackets(
                        secondPacketsTask.Result,
                        secondPeeledWindow.WindowId);

                    WriteMarker(twoStreamsReadyPath);
                    await WaitForFileOrAbortAsync(
                            stopFirstPath,
                            hostExitedPath,
                            timeout.Token)
                        .ConfigureAwait(false);
                    await SendStreamRequestAsync(
                            controlStream,
                            PeelMessageType.StopStream,
                            firstPeeledWindow.WindowId,
                            timeout.Token)
                        .ConfigureAwait(false);
                    await WaitForStreamEndAsync(
                            firstVideoStream,
                            HostVideoSessionOptions.DefaultMaximumEncodedPacketBytes,
                            timeout.Token)
                        .ConfigureAwait(false);

                    IReadOnlyList<IPeelBinaryPacket> continuingPackets =
                        await ReadVideoPacketsAsync(
                                secondVideoStream,
                                HostVideoSessionOptions.DefaultMaximumEncodedPacketBytes,
                                2,
                                timeout.Token)
                            .ConfigureAwait(false);
                    long continuingTimestamp = ValidateNativeVideoPackets(
                        continuingPackets,
                        secondPeeledWindow.WindowId,
                        requireConfiguration: false);
                    True(continuingTimestamp > secondLastTimestamp);
                    True(firstLastTimestamp >= 0);

                    WriteMarker(oneStreamReadyPath);
                    await WaitForFileOrAbortAsync(
                            finishPath,
                            hostExitedPath,
                            timeout.Token)
                        .ConfigureAwait(false);
                    await SendStreamRequestAsync(
                            controlStream,
                            PeelMessageType.StopStream,
                            secondPeeledWindow.WindowId,
                            timeout.Token)
                        .ConfigureAwait(false);
                    await WaitForStreamEndAsync(
                            secondVideoStream,
                            HostVideoSessionOptions.DefaultMaximumEncodedPacketBytes,
                            timeout.Token)
                        .ConfigureAwait(false);
                }
                finally
                {
                    animationCancellation.Cancel();
                    await IgnoreExpectedCancellationAsync(firstAnimation, animationCancellation.Token)
                        .ConfigureAwait(false);
                    await IgnoreExpectedCancellationAsync(secondAnimation, animationCancellation.Token)
                        .ConfigureAwait(false);
                }
            }

            WriteMarker(streamsCompletePath);
            await WaitForFileAsync(hostExitedPath, timeout.Token).ConfigureAwait(false);
            pairingRemoved = RemoveValidationPairing(accepted.PairingId);
            True(pairingRemoved);
            WriteMarker(passedPath);
            Console.WriteLine(
                "PASS external production Host multi-window smoke: two native HWNDs, " +
                "visibility awake lifecycle, two authenticated H.264 streams, " +
                "independent stop, temporary pairing removed");
            return 0;
        }
        catch (Exception exception)
        {
            File.WriteAllText(
                failedPath,
                $"{exception.GetType().Name}: {exception.Message}",
                new UTF8Encoding(false));
            Console.Error.WriteLine(
                "FAIL external production Host multi-window smoke: " +
                $"{exception.GetType().Name}: {exception.Message}");
            if (accepted is { Accepted: true } && !pairingRemoved)
            {
                try
                {
                    using var cleanupTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                    await WaitForFileAsync(hostExitedPath, cleanupTimeout.Token).ConfigureAwait(false);
                    pairingRemoved = RemoveValidationPairing(accepted.PairingId);
                }
                catch (Exception cleanupException)
                {
                    Console.Error.WriteLine(
                        "FAIL external production Host multi-window cleanup: " +
                        $"{cleanupException.GetType().Name}: {cleanupException.Message}");
                }
            }

            return 1;
        }
        finally
        {
            if (pairingKey is not null)
            {
                CryptographicOperations.ZeroMemory(pairingKey);
            }

            if (accepted is not null)
            {
                CryptographicOperations.ZeroMemory(accepted.Psk);
            }
        }
    }

    private static async Task<int> RunAppleInteropHostAsync(string stateDirectory)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
        {
            Console.Error.WriteLine(
                "Apple interoperability Host requires Windows 10 version 2004 or later.");
            return 2;
        }

        string stateRoot = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(stateRoot);
        string metadataPath = Path.Combine(stateRoot, "paired-clients.json");
        string identityPath = Path.Combine(stateRoot, "host-id.txt");
        string pinPath = Path.Combine(stateRoot, "pairing-pin.txt");
        string readyPath = Path.Combine(stateRoot, "ready.txt");
        string stopPath = Path.Combine(stateRoot, "stop.txt");
        var store = new WindowsPairedClientStore(metadataPath);
        var vault = new WindowsCredentialManager();
        WindowsHostRuntime? runtime = null;

        try
        {
            File.Delete(pinPath);
            File.Delete(readyPath);
            File.Delete(stopPath);

            using var smokeWindow = new NativeCaptureSmokeWindow();
            _ = await smokeWindow.Window.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            string runId = Guid.NewGuid().ToString("N")[..8];
            var options = new WindowsHostRuntimeOptions(
                hostName: $"Windows Apple Interop {runId}",
                appVersion: "apple-interop-smoke");
            runtime = new WindowsHostRuntime(
                new BouncyCastlePskTransportFactory(),
                new WindowsDnsSdRegistrar(),
                store,
                new WindowsHostIdentityStore(identityPath),
                new WindowsGraphicsCaptureBackend(),
                new MediaFoundationH264EncoderFactory(),
                options,
                requireWindows: true);
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            await runtime.StartAsync(timeout.Token).ConfigureAwait(false);
            True(runtime.IsRunning);
            True(!runtime.InputPermission.IsEnabled);
            HostPairingPin pin = runtime.PairingPin ??
                throw new InvalidDataException("The Apple interoperability Host has no pairing PIN.");

            File.WriteAllText(pinPath, pin.Pin, new UTF8Encoding(false));
            File.WriteAllText(
                readyPath,
                JsonSerializer.Serialize(new
                {
                    controlServiceName = options.ServiceName,
                    pairingServiceName = options.PairingServiceName,
                    hostName = options.HostName,
                }),
                new UTF8Encoding(false));

            Task stop = WaitForFileAsync(stopPath, timeout.Token);
            Task completed = await Task.WhenAny(stop, runtime.Completion).ConfigureAwait(false);
            if (ReferenceEquals(completed, runtime.Completion))
            {
                await runtime.Completion.ConfigureAwait(false);
                throw new IOException("The Apple interoperability Host stopped before the peer finished.");
            }

            await stop.ConfigureAwait(false);
            Equal(1, store.Snapshot().Count);
            True(!runtime.InputPermission.IsEnabled);

            Console.WriteLine(
                "PASS Apple interoperability Host: production discovery, pairing, " +
                "credential reconnect, window list, input default off");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                "FAIL Apple interoperability Host: " +
                $"{exception.GetType().Name}: {exception.Message}");
            return 1;
        }
        finally
        {
            File.Delete(pinPath);
            File.Delete(readyPath);
            File.Delete(stopPath);

            if (runtime is not null)
            {
                await runtime.DisposeAsync().ConfigureAwait(false);
            }

            foreach (HostPairedClient peer in store.Snapshot())
            {
                string target = WindowsPairedClientStore.CredentialTarget(
                    WindowsPairedClientStore.DefaultCredentialTargetPrefix,
                    peer.PairingId);
                try
                {
                    _ = store.Remove(peer.PairingId);
                }
                catch (Exception)
                {
                }

                try
                {
                    _ = vault.Delete(target);
                }
                catch (Win32Exception)
                {
                }
            }
        }
    }

    private static async Task WaitForFileAsync(
        string path,
        CancellationToken cancellationToken)
    {
        while (!File.Exists(path))
        {
            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task WaitForFileOrAbortAsync(
        string path,
        string abortPath,
        CancellationToken cancellationToken)
    {
        while (!File.Exists(path))
        {
            if (File.Exists(abortPath))
            {
                throw new IOException(
                    "The production Host exited before the runtime checkpoint completed.");
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task<PeelDiscoveredService> FindRuntimeServiceAsync(
        string serviceType,
        string hostId,
        CancellationToken cancellationToken)
    {
        var browser = new WindowsDnsSdBrowser();
        await foreach (PeelDiscoveredService service in browser
            .BrowseAsync(serviceType, cancellationToken)
            .WithCancellation(cancellationToken))
        {
            if (service.ChangeKind == PeelServiceChangeKind.Added &&
                StringComparer.Ordinal.Equals(service.HostId, hostId))
            {
                return service;
            }
        }

        throw new InvalidDataException($"The native runtime did not advertise {serviceType}.");
    }

    private static async Task<PeelDiscoveredService> FindRuntimeServiceByDisplayNameAsync(
        string serviceType,
        string displayName,
        CancellationToken cancellationToken)
    {
        var browser = new WindowsDnsSdBrowser();
        await foreach (PeelDiscoveredService service in browser
            .BrowseAsync(serviceType, cancellationToken)
            .WithCancellation(cancellationToken))
        {
            if (service.ChangeKind == PeelServiceChangeKind.Added &&
                StringComparer.Ordinal.Equals(service.DisplayName, displayName))
            {
                return service;
            }
        }

        throw new InvalidDataException(
            $"The external production Host did not advertise {displayName}.");
    }

    private static async Task AssertRuntimeServiceAbsentAsync(
        string hostId,
        CancellationToken cancellationToken)
    {
        var browser = new WindowsDnsSdBrowser();
        try
        {
            await foreach (PeelDiscoveredService service in browser
                .BrowseAsync(PeelServiceType.Control, cancellationToken)
                .WithCancellation(cancellationToken))
            {
                if (service.ChangeKind == PeelServiceChangeKind.Added &&
                    StringComparer.Ordinal.Equals(service.HostId, hostId))
                {
                    throw new InvalidDataException(
                        "The disposed native Host runtime remained discoverable.");
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static void RequireInputSuccess(InputInjectionResult result)
    {
        if (!result.Succeeded)
        {
            throw new InvalidOperationException(result.Error ?? "Windows rejected input.");
        }
    }

    private static async Task<byte[]> ReadNetworkLineAsync(
        Stream stream,
        int maximumLineBytes,
        CancellationToken cancellationToken)
    {
        using var line = new MemoryStream();
        var oneByte = new byte[1];
        while (true)
        {
            int byteCount = await stream.ReadAsync(oneByte, cancellationToken)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new InvalidDataException("The authenticated Host closed before a full line.");
            }

            if (oneByte[0] == (byte)'\n')
            {
                byte[] bytes = line.ToArray();
                return bytes.Length > 0 && bytes[^1] == (byte)'\r'
                    ? bytes[..^1]
                    : bytes;
            }

            if (line.Length >= maximumLineBytes)
            {
                throw new InvalidDataException("The authenticated Host response line was oversized.");
            }

            line.WriteByte(oneByte[0]);
        }
    }

    private static async Task<IReadOnlyList<IPeelBinaryPacket>> ReadVideoPacketsAsync(
        Stream stream,
        int maximumPacketBytes,
        int targetPacketCount,
        CancellationToken cancellationToken)
    {
        var reader = new PeelBinaryPacketReader(maximumPacketBytes);
        var packets = new List<IPeelBinaryPacket>();
        var buffer = new byte[256 * 1024];
        while (packets.Count < targetPacketCount)
        {
            int byteCount = await stream.ReadAsync(buffer, cancellationToken)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new InvalidDataException(
                    "The authenticated Host video stream ended before enough packets arrived.");
            }

            packets.AddRange(reader.Append(buffer.AsSpan(0, byteCount)));
        }

        return packets;
    }

    private static async Task<SustainedVideoObservation> ObserveSustainedVideoStreamAsync(
        Stream stream,
        int maximumPacketBytes,
        uint windowId,
        TimeSpan duration,
        CancellationToken cancellationToken)
    {
        const int baselineFrameCount = 30;
        const int minimumFramesPerSecond = 5;
        const long maximumPrivateByteGrowth = 256L * 1024 * 1024;
        const long maximumManagedByteGrowth = 64L * 1024 * 1024;
        const int maximumHandleGrowth = 128;

        var reader = new PeelBinaryPacketReader(maximumPacketBytes);
        var buffer = new byte[256 * 1024];
        var stopwatch = Stopwatch.StartNew();
        var configurationCount = 0;
        var frameCount = 0;
        long payloadBytes = 0;
        long previousTimestamp = -1;
        var requiresKeyframe = false;
        ProcessResourceSnapshot? baselineResources = null;
        long peakPrivateBytes = 0;
        long peakWorkingSetBytes = 0;
        long peakManagedBytes = 0;
        var peakHandleCount = 0;
        TimeSpan nextResourceSample = TimeSpan.Zero;

        while (stopwatch.Elapsed < duration)
        {
            int byteCount = await stream.ReadAsync(buffer, cancellationToken)
                .ConfigureAwait(false);
            if (byteCount == 0)
            {
                throw new InvalidDataException(
                    "The authenticated Host video stream ended during sustained validation.");
            }

            foreach (IPeelBinaryPacket packet in reader.Append(buffer.AsSpan(0, byteCount)))
            {
                Equal(windowId, packet.WindowId);
                if (packet is VideoConfigPacket configuration)
                {
                    if (requiresKeyframe)
                    {
                        throw new InvalidDataException(
                            "The Host emitted a new video configuration before the prior generation's keyframe.");
                    }

                    Equal(PeelVideoCodec.H264, configuration.Codec);
                    True(configuration.Width > 0);
                    True(configuration.Height > 0);
                    Equal((byte)4, configuration.NalUnitHeaderLength);
                    Equal(7, configuration.Sps[0] & 0x1F);
                    Equal(8, configuration.Pps[0] & 0x1F);
                    configurationCount++;
                    requiresKeyframe = true;
                    continue;
                }

                var frame = packet as VideoFramePacket ??
                    throw new InvalidDataException(
                        "The Host emitted an unknown packet during sustained validation.");
                if (configurationCount == 0)
                {
                    throw new InvalidDataException(
                        "The Host emitted a frame before video configuration.");
                }

                if (requiresKeyframe && !frame.IsKeyframe)
                {
                    throw new InvalidDataException(
                        "A sustained Host encoder generation did not begin at a keyframe.");
                }

                requiresKeyframe = false;
                True(frame.PtsValue > previousTimestamp);
                True(frame.DurationValue > 0);
                True(frame.Payload.Length > 0);
                ValidateLengthPrefixedH264(frame.Payload);
                previousTimestamp = frame.PtsValue;
                payloadBytes = checked(payloadBytes + frame.Payload.Length);
                frameCount++;
            }

            if (frameCount >= baselineFrameCount && baselineResources is null)
            {
                baselineResources = ReadCurrentProcessResources();
                peakPrivateBytes = baselineResources.Value.PrivateBytes;
                peakWorkingSetBytes = baselineResources.Value.WorkingSetBytes;
                peakManagedBytes = baselineResources.Value.ManagedBytes;
                peakHandleCount = baselineResources.Value.HandleCount;
                nextResourceSample = stopwatch.Elapsed + TimeSpan.FromSeconds(1);
            }
            else if (baselineResources is not null && stopwatch.Elapsed >= nextResourceSample)
            {
                ProcessResourceSnapshot sample = ReadCurrentProcessResources();
                peakPrivateBytes = Math.Max(peakPrivateBytes, sample.PrivateBytes);
                peakWorkingSetBytes = Math.Max(peakWorkingSetBytes, sample.WorkingSetBytes);
                peakManagedBytes = Math.Max(peakManagedBytes, sample.ManagedBytes);
                peakHandleCount = Math.Max(peakHandleCount, sample.HandleCount);
                nextResourceSample = stopwatch.Elapsed + TimeSpan.FromSeconds(1);
            }
        }

        if (requiresKeyframe)
        {
            throw new InvalidDataException(
                "The sustained Host stream ended immediately after video configuration.");
        }

        int minimumFrameCount = checked((int)Math.Ceiling(
            duration.TotalSeconds * minimumFramesPerSecond));
        if (frameCount < minimumFrameCount)
        {
            throw new InvalidDataException(
                $"The sustained Host stream emitted only {frameCount} frames; " +
                $"at least {minimumFrameCount} were required.");
        }

        ProcessResourceSnapshot baseline = baselineResources ??
            throw new InvalidDataException(
                "The sustained Host stream ended before a resource baseline was available.");
        ProcessResourceSnapshot finalResources = ReadCurrentProcessResources();
        peakPrivateBytes = Math.Max(peakPrivateBytes, finalResources.PrivateBytes);
        peakWorkingSetBytes = Math.Max(peakWorkingSetBytes, finalResources.WorkingSetBytes);
        peakManagedBytes = Math.Max(peakManagedBytes, finalResources.ManagedBytes);
        peakHandleCount = Math.Max(peakHandleCount, finalResources.HandleCount);

        long privateByteGrowth = Math.Max(
            0,
            finalResources.PrivateBytes - baseline.PrivateBytes);
        long managedByteGrowth = Math.Max(
            0,
            finalResources.ManagedBytes - baseline.ManagedBytes);
        int handleGrowth = Math.Max(
            0,
            finalResources.HandleCount - baseline.HandleCount);
        if (privateByteGrowth > maximumPrivateByteGrowth ||
            managedByteGrowth > maximumManagedByteGrowth ||
            handleGrowth > maximumHandleGrowth)
        {
            throw new InvalidDataException(
                "The sustained Host stream exceeded its resource-growth boundary: " +
                $"privateBytes={privateByteGrowth}, managedBytes={managedByteGrowth}, " +
                $"handles={handleGrowth}.");
        }

        return new SustainedVideoObservation(
            stopwatch.Elapsed,
            configurationCount,
            frameCount,
            payloadBytes,
            baseline,
            finalResources,
            peakPrivateBytes,
            peakWorkingSetBytes,
            peakManagedBytes,
            peakHandleCount);
    }

    private static ProcessResourceSnapshot ReadCurrentProcessResources()
    {
        using Process process = Process.GetCurrentProcess();
        process.Refresh();
        return new ProcessResourceSnapshot(
            process.PrivateMemorySize64,
            process.WorkingSet64,
            GC.GetTotalMemory(forceFullCollection: false),
            process.HandleCount);
    }

    private static async Task<Stream> ConnectVideoStreamAsync(
        IPeelPskTransportFactory transport,
        PeelPskCredential credential,
        int port,
        uint windowId,
        CancellationToken cancellationToken)
    {
        Stream stream = await transport.ConnectAsync(
                new DnsEndPoint(IPAddress.Loopback.ToString(), port),
                credential,
                cancellationToken)
            .ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(
                    PeelJson.SerializeLine(
                        PeelHello.CreateVideoStream(
                            windowId,
                            credential.Identity,
                            VideoCapabilities())),
                    cancellationToken)
                .ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            return stream;
        }
        catch
        {
            await stream.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private static long ValidateNativeVideoPackets(
        IReadOnlyList<IPeelBinaryPacket> packets,
        uint windowId,
        bool requireConfiguration = true)
    {
        True(packets.Count > 0);
        True(packets.All(packet => packet.WindowId == windowId));
        if (requireConfiguration)
        {
            VideoConfigPacket configuration = packets.OfType<VideoConfigPacket>().FirstOrDefault() ??
                throw new InvalidDataException("The native stream did not emit H.264 configuration.");
            Equal(PeelVideoCodec.H264, configuration.Codec);
            True(configuration.Width > 0);
            True(configuration.Height > 0);
            True(configuration.Sps.Length > 0);
            True(configuration.Pps.Length > 0);
        }

        VideoFramePacket[] frames = packets.OfType<VideoFramePacket>().ToArray();
        True(frames.Length > 0);
        True(frames.All(static frame => frame.Payload.Length > 0));
        True(frames.All(static frame => frame.DurationValue > 0));
        for (var index = 1; index < frames.Length; index++)
        {
            True(frames[index].PtsValue > frames[index - 1].PtsValue);
        }

        return frames[^1].PtsValue;
    }

    private static async Task SendStreamRequestAsync(
        Stream stream,
        string messageType,
        uint windowId,
        CancellationToken cancellationToken)
    {
        await stream.WriteAsync(
                PeelJson.SerializeLine(new PeelRequest(messageType, WindowId: windowId)),
                cancellationToken)
            .ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task IgnoreExpectedCancellationAsync(
        Task task,
        CancellationToken cancellationToken)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static void WriteMarker(string path) =>
        File.WriteAllText(path, "ready", new UTF8Encoding(false));

    private static bool RemoveValidationPairing(string pairingId)
    {
        var store = new WindowsPairedClientStore();
        bool removed = store.Remove(pairingId);
        True(!store.Snapshot().Any(peer => StringComparer.Ordinal.Equals(
            peer.PairingId,
            pairingId)));
        return removed;
    }

    private static async Task WaitForStreamEndAsync(
        Stream stream,
        int maximumTrailingBytes,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[64 * 1024];
        var trailingBytes = 0;
        while (true)
        {
            int byteCount;
            try
            {
                byteCount = await stream.ReadAsync(buffer, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (IOException)
            {
                return;
            }

            if (byteCount == 0)
            {
                return;
            }

            trailingBytes = checked(trailingBytes + byteCount);
            if (trailingBytes > maximumTrailingBytes)
            {
                throw new InvalidDataException(
                    "The Host continued streaming after stopStream.");
            }
        }
    }

    private static async Task AnimateNativeSmokeWindowAsync(
        NativeCaptureSmokeWindow smokeWindow,
        CancellationToken cancellationToken)
    {
        var frameMarker = 0;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            smokeWindow.SetFrameMarker(++frameMarker);
            await Task.Delay(TimeSpan.FromMilliseconds(16), cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task WaitForMinimumAsync(
        Func<int> readValue,
        int minimum,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(readValue);
        while (readValue() < minimum)
        {
            await Task.Delay(20, cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<CapturedFrame> CaptureNativeFrameAsync()
    {
        using var smokeWindow = new NativeCaptureSmokeWindow();
        WindowDescriptor window = await smokeWindow.Window
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        return await CaptureNativeFrameFromSourceAsync(window).ConfigureAwait(false);
    }

    private static async Task<CapturedFrame> CaptureNativeFrameFromSourceAsync(
        WindowDescriptor source)
    {
        var backend = new WindowsGraphicsCaptureBackend();
        await using IWindowCaptureSession session =
            await backend.OpenAsync(source, CancellationToken.None);
        using var captureCancellation = new CancellationTokenSource();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var firstFrame = new TaskCompletionSource<CapturedFrame>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var receivedFrameCount = 0;

        Task runTask = session.RunAsync(
            (frame, _) =>
            {
                if (Interlocked.Increment(ref receivedFrameCount) == 1)
                {
                    firstFrame.TrySetResult(frame);
                }

                captureCancellation.Cancel();
                return ValueTask.CompletedTask;
            },
            captureCancellation.Token);

        CapturedFrame capturedFrame;
        try
        {
            capturedFrame = await firstFrame.Task
                .WaitAsync(timeout.Token)
                .ConfigureAwait(false);
        }
        finally
        {
            captureCancellation.Cancel();
            try
            {
                await runTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (captureCancellation.IsCancellationRequested)
            {
            }
        }

        Equal(1, receivedFrameCount);
        return capturedFrame;
    }

    private static void ValidateLengthPrefixedH264(ReadOnlySpan<byte> payload)
    {
        var offset = 0;
        var unitCount = 0;
        while (offset < payload.Length)
        {
            if (payload.Length - offset < sizeof(uint))
            {
                throw new InvalidDataException("Encoded H.264 contains a truncated NAL length.");
            }

            uint unitLength = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(
                payload.Slice(offset, sizeof(uint)));
            offset += sizeof(uint);
            if (unitLength == 0 || unitLength > payload.Length - offset)
            {
                throw new InvalidDataException("Encoded H.264 contains an invalid NAL length.");
            }

            offset = checked(offset + (int)unitLength);
            unitCount++;
        }

        True(unitCount > 0);
    }

    private static void NormalizedCenterMapping()
    {
        True(NormalizedCoordinateMapper.TryMapToScreen(
            new WindowBounds(10, 20, 101, 201),
            0.5,
            0.5,
            out ScreenPoint point));
        Equal(new ScreenPoint(60, 120), point);
    }

    private static void NormalizedEdgeClamping()
    {
        var bounds = new WindowBounds(-100, 20, 101, 51);
        True(NormalizedCoordinateMapper.TryMapToScreen(bounds, -100, 100, out ScreenPoint point));
        Equal(new ScreenPoint(-100, 70), point);
    }

    private static void HostileCoordinateRejection()
    {
        True(!NormalizedCoordinateMapper.TryMapToScreen(
            new WindowBounds(0, 0, 100, 100),
            double.NaN,
            0.5,
            out _));
        True(!NormalizedCoordinateMapper.TryMapToScreen(
            new WindowBounds(0, 0, 100, 100),
            0.5,
            double.PositiveInfinity,
            out _));
        True(!NormalizedCoordinateMapper.TryMapToScreen(
            new WindowBounds(0, 0, 1, 100),
            0.5,
            0.5,
            out _));
        True(!NormalizedCoordinateMapper.TryMapToScreen(
            new WindowBounds(int.MaxValue - 5, 0, 100, 100),
            1,
            0.5,
            out _));
    }

    private static void InputGateDefaultsClosed()
    {
        var gate = new InputPermissionGate();
        var injector = new WindowsInputInjector(gate);
        InputInjectionResult result = injector.MovePointer(
            new WindowBounds(0, 0, 100, 100),
            0.5,
            0.5);

        True(!gate.IsEnabled);
        True(!result.Succeeded);
        True(result.Error?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true);
    }

    private static void PairedCredentialMetadataExcludesSecrets()
    {
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-paired-metadata-{Guid.NewGuid():N}");
        string metadataPath = Path.Combine(temporaryDirectory, "paired-clients.json");
        byte[] key = Enumerable.Range(0, WindowsPairedClientStore.PreSharedKeyBytes)
            .Select(static value => checked((byte)(value + 1)))
            .ToArray();
        const string pairingId = "pairing-metadata-1";
        const string targetPrefix = "ZephyrStudios.Peel.Tests.Host.PSK";
        var vault = new RecordingCredentialVault();

        try
        {
            var store = new WindowsPairedClientStore(
                vault,
                new JsonHostPairedClientMetadataRepository(metadataPath),
                targetPrefix);
            HostPairedClient peer = store.AddOrReplace(
                pairingId,
                "Surface Client",
                "surface-device-1",
                key,
                new DateTimeOffset(2026, 8, 1, 12, 0, 0, TimeSpan.Zero));

            Equal(pairingId, peer.PairingId);
            Equal(1, store.Snapshot().Count);
            Equal(1, vault.Count);
            string metadata = File.ReadAllText(metadataPath);
            True(metadata.Contains("surface-device-1", StringComparison.Ordinal));
            True(!metadata.Contains("psk", StringComparison.OrdinalIgnoreCase));
            True(!metadata.Contains("preSharedKey", StringComparison.OrdinalIgnoreCase));
            True(!metadata.Contains(Convert.ToBase64String(key), StringComparison.Ordinal));

            True(store.TryResolve(pairingId, out PeelPskCredential? resolved));
            PeelPskCredential resolvedCredential = resolved ??
                throw new InvalidOperationException("Expected a resolved credential.");
            True(resolvedCredential.PreSharedKey.AsSpan().SequenceEqual(key));
            CryptographicOperations.ZeroMemory(resolvedCredential.PreSharedKey);
            True(!store.TryResolve("unknown-pairing", out _));

            True(store.Remove(pairingId));
            Equal(0, store.Snapshot().Count);
            Equal(0, vault.Count);
            True(!store.TryResolve(pairingId, out _));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            vault.Dispose();
            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static void RePairRevokesPreviousIdentity()
    {
        byte[] firstKey = Enumerable.Repeat((byte)0x11, WindowsPairedClientStore.PreSharedKeyBytes)
            .ToArray();
        byte[] secondKey = Enumerable.Repeat((byte)0x22, WindowsPairedClientStore.PreSharedKeyBytes)
            .ToArray();
        var vault = new RecordingCredentialVault();
        var metadata = new RecordingPairedClientMetadataRepository();
        var store = new WindowsPairedClientStore(
            vault,
            metadata,
            "ZephyrStudios.Peel.Tests.Host.PSK");

        try
        {
            _ = store.AddOrReplace("pairing-old", "Client", "device-stable", firstKey);
            _ = store.AddOrReplace("pairing-new", "Client", "device-stable", secondKey);

            Equal(1, store.Snapshot().Count);
            Equal("pairing-new", store.Snapshot()[0].PairingId);
            Equal(1, vault.Count);
            True(!store.TryResolve("pairing-old", out _));
            True(store.TryResolve("pairing-new", out PeelPskCredential? resolved));
            PeelPskCredential resolvedCredential = resolved ??
                throw new InvalidOperationException("Expected a resolved credential.");
            True(resolvedCredential.PreSharedKey.AsSpan().SequenceEqual(secondKey));
            CryptographicOperations.ZeroMemory(resolvedCredential.PreSharedKey);
            Throws<InvalidOperationException>(() => store.AddOrReplace(
                "pairing-new",
                "Duplicate",
                "different-device",
                secondKey));
            Equal(1, metadata.Current.Count);
            Equal(1, vault.Count);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(firstKey);
            CryptographicOperations.ZeroMemory(secondKey);
            vault.Dispose();
        }
    }

    private static void CorruptPairedMetadataFailsClosed()
    {
        var vault = new RecordingCredentialVault();
        var store = new WindowsPairedClientStore(
            vault,
            new ThrowingPairedClientMetadataRepository(),
            "ZephyrStudios.Peel.Tests.Host.PSK");

        True(store.LoadError?.Contains("rejected", StringComparison.OrdinalIgnoreCase) == true);
        Equal(0, store.Snapshot().Count);
        True(!store.TryResolve("orphaned-pairing", out _));
        Equal(0, vault.ReadCount);
        vault.Dispose();
    }

    private static void StableHostIdentityPersistsAndFailsClosed()
    {
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-identity-tests-{Guid.NewGuid():N}");
        string identityPath = Path.Combine(temporaryDirectory, "host-id.txt");

        try
        {
            var store = new WindowsHostIdentityStore(identityPath);
            string created = store.LoadOrCreate();
            True(Guid.TryParse(created, out _));
            Equal(created, new WindowsHostIdentityStore(identityPath).LoadOrCreate());

            File.WriteAllText(identityPath, "   \r\n");
            Throws<InvalidDataException>(() => new WindowsHostIdentityStore(identityPath).LoadOrCreate());
            Equal("   \r\n", File.ReadAllText(identityPath));
        }
        finally
        {
            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static void CredentialTargetsPreserveCaseSensitiveIdentity()
    {
        byte[] upperKey = Enumerable.Repeat((byte)0x31, WindowsPairedClientStore.PreSharedKeyBytes)
            .ToArray();
        byte[] lowerKey = Enumerable.Repeat((byte)0x42, WindowsPairedClientStore.PreSharedKeyBytes)
            .ToArray();
        var vault = new RecordingCredentialVault();
        var store = new WindowsPairedClientStore(
            vault,
            new RecordingPairedClientMetadataRepository(),
            "ZephyrStudios.Peel.Tests.Host.PSK");

        try
        {
            _ = store.AddOrReplace("Pairing-Case", "Upper", "device-upper", upperKey);
            _ = store.AddOrReplace("pairing-case", "Lower", "device-lower", lowerKey);

            Equal(2, vault.Count);
            True(store.TryResolve("Pairing-Case", out PeelPskCredential? upper));
            True(store.TryResolve("pairing-case", out PeelPskCredential? lower));
            PeelPskCredential resolvedUpper = upper ??
                throw new InvalidOperationException("Expected the uppercase credential.");
            PeelPskCredential resolvedLower = lower ??
                throw new InvalidOperationException("Expected the lowercase credential.");
            True(resolvedUpper.PreSharedKey.AsSpan().SequenceEqual(upperKey));
            True(resolvedLower.PreSharedKey.AsSpan().SequenceEqual(lowerKey));
            CryptographicOperations.ZeroMemory(resolvedUpper.PreSharedKey);
            CryptographicOperations.ZeroMemory(resolvedLower.PreSharedKey);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(upperKey);
            CryptographicOperations.ZeroMemory(lowerKey);
            vault.Dispose();
        }
    }

    private static void ProductionRuntimeDefaultsToDualStackListen()
    {
        var options = new WindowsHostRuntimeOptions();
        Equal(IPAddress.IPv6Any, options.ListenAddress);
    }

    private static void DiagnosticHostPointsLiveHostingToUnifiedApp()
    {
        HostCommandLine run = HostCommandLine.Parse(["--run"]);
        True(!run.DryRun);

        using var guidanceWriter = new StringWriter();
        HostCommandLine.PrintLiveHostGuidance(guidanceWriter);
        string guidance = guidanceWriter.ToString();
        True(guidance.Contains("Peel.Windows.exe", StringComparison.Ordinal));
        True(!guidance.Contains("not implemented", StringComparison.OrdinalIgnoreCase));

        using var helpWriter = new StringWriter();
        HostCommandLine.PrintHelp(helpWriter);
        True(helpWriter.ToString().Contains("Peel.Windows.exe", StringComparison.Ordinal));
    }

    private static void PairingTxtMatchesApplePinContract()
    {
        var expiresAt = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        HostPairingPin pin = CreateTestPairingPin(expiresAt);
        IReadOnlyDictionary<string, byte[]> records = pin.CreateTxtRecords(
            "host-123",
            43210);

        Equal(6, records.Count);
        Equal("host-123", System.Text.Encoding.UTF8.GetString(records["hostId"]));
        Equal("pin", System.Text.Encoding.UTF8.GetString(records["pairMode"]));
        Equal(pin.SaltBase64, System.Text.Encoding.UTF8.GetString(records["pinSalt"]));
        Equal("1800000000", System.Text.Encoding.UTF8.GetString(records["pinExp"]));
        Equal("43210", System.Text.Encoding.UTF8.GetString(records["pairPort"]));
        Equal(
            HostPairingPin.StandardTlsPskOrder,
            System.Text.Encoding.UTF8.GetString(records[HostPairingPin.TlsPskOrderTxtKey]));
    }

    private static async Task RuntimeAdvertisesAndRotatesExactHostServices()
    {
        string temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"peel-host-runtime-tests-{Guid.NewGuid():N}");
        string identityPath = Path.Combine(temporaryDirectory, "host-id.txt");
        var vault = new RecordingCredentialVault();
        var metadata = new RecordingPairedClientMetadataRepository();
        var pairedClients = new WindowsPairedClientStore(
            vault,
            metadata,
            "ZephyrStudios.Peel.Tests.Runtime.PSK");
        var registrar = new RecordingServiceRegistrar();
        var options = new WindowsHostRuntimeOptions(
            hostName: "Runtime Test PC",
            appVersion: "runtime-test",
            listenAddress: IPAddress.Loopback);
        await using var runtime = new WindowsHostRuntime(
            new BouncyCastlePskTransportFactory(),
            registrar,
            pairedClients,
            new WindowsHostIdentityStore(identityPath),
            new SequencedCaptureBackend(),
            new SequencedEncoderFactory(),
            options);

        try
        {
            await runtime.StartAsync().ConfigureAwait(false);
            True(runtime.IsRunning);
            True(!runtime.InputPermission.IsEnabled);
            True(runtime.ControlEndPoint?.Port > 0);
            True(runtime.PairingEndPoint?.Port > 0);
            Equal(2, registrar.Active.Count);
            AssertRuntimeAdvertisements(runtime, registrar.Active, options);

            runtime.SetInputEnabled(true);
            True(runtime.InputPermission.IsEnabled);
            runtime.SetInputEnabled(false);
            True(!runtime.InputPermission.IsEnabled);

            string previousSalt = runtime.PairingPin?.SaltBase64 ??
                throw new InvalidOperationException("The runtime did not publish a pairing PIN.");
            await runtime.RefreshPairingAsync().ConfigureAwait(false);
            True(runtime.IsRunning);
            True(!StringComparer.Ordinal.Equals(previousSalt, runtime.PairingPin?.SaltBase64));
            Equal(2, registrar.Active.Count);
            Equal(2, registrar.DisposeCount);
            AssertRuntimeAdvertisements(runtime, registrar.Active, options);

            await runtime.DisposeAsync().ConfigureAwait(false);
            True(!runtime.IsRunning);
            True(!runtime.InputPermission.IsEnabled);
            Equal(0, registrar.Active.Count);
            Equal(4, registrar.DisposeCount);
        }
        finally
        {
            vault.Dispose();
            if (Directory.Exists(temporaryDirectory))
            {
                Directory.Delete(temporaryDirectory, recursive: true);
            }
        }
    }

    private static void AssertRuntimeAdvertisements(
        WindowsHostRuntime runtime,
        IReadOnlyList<PeelServiceAdvertisement> advertisements,
        WindowsHostRuntimeOptions options)
    {
        PeelServiceAdvertisement control = advertisements.Single(
            static advertisement => advertisement.ServiceType == PeelServiceType.Control);
        PeelServiceAdvertisement pairing = advertisements.Single(
            static advertisement => advertisement.ServiceType == PeelServiceType.Pairing);
        Equal(options.ServiceName, control.DisplayName);
        Equal(options.PairingServiceName, pairing.DisplayName);
        Equal(runtime.ControlEndPoint?.Port, (int)control.Port);
        Equal(runtime.PairingEndPoint?.Port, (int)pairing.Port);
        Equal(6, control.TxtRecords.Count);
        Equal(6, pairing.TxtRecords.Count);

        foreach ((string key, byte[] value) in control.TxtRecords)
        {
            True(pairing.TxtRecords.TryGetValue(key, out byte[]? pairingValue));
            True(value.AsSpan().SequenceEqual(pairingValue));
        }

        Equal(runtime.HostId, System.Text.Encoding.UTF8.GetString(control.TxtRecords["hostId"]));
        Equal("pin", System.Text.Encoding.UTF8.GetString(control.TxtRecords["pairMode"]));
        Equal(runtime.PairingPin?.SaltBase64,
            System.Text.Encoding.UTF8.GetString(control.TxtRecords["pinSalt"]));
        Equal(runtime.PairingEndPoint?.Port.ToString(),
            System.Text.Encoding.UTF8.GetString(control.TxtRecords["pairPort"]));
        Equal(HostPairingPin.StandardTlsPskOrder,
            System.Text.Encoding.UTF8.GetString(
                control.TxtRecords[HostPairingPin.TlsPskOrderTxtKey]));
    }

    private static async Task SecurePinPairingRejectsBadProofAndStoresCredential()
    {
        const string hostId = "windows-host-123";
        const string clientDeviceId = "apple-client-device-123";
        var vault = new RecordingCredentialVault();
        var metadata = new RecordingPairedClientMetadataRepository();
        var store = new WindowsPairedClientStore(
            vault,
            metadata,
            "ZephyrStudios.Peel.Tests.Pairing.PSK");
        HostPairingPin pin = CreateTestPairingPin(DateTimeOffset.UtcNow.AddMinutes(1));
        var transport = new BouncyCastlePskTransportFactory();
        byte[] pinPreSharedKey = pin.DerivePreSharedKey(hostId);
        var credential = new PeelPskCredential(
            PeelPinPairing.TlsIdentity,
            pinPreSharedKey);

        try
        {
            await using var listener = new HostPinPairingListener(
                transport,
                store,
                hostId,
                "Windows Host",
                "Peel on Windows Host",
                pin,
                new HostPinPairingListenerOptions(
                    acceptWorkerCount: 1,
                    maximumActiveConnections: 2));
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await listener.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    cancellation.Token)
                .ConfigureAwait(false);
            var endpoint = listener.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException("The pairing listener did not publish an endpoint.");

            PairResponseMessage rejection = await SendPairingRequestAsync(
                    transport,
                    endpoint,
                    credential,
                    new PairRequestMessage(
                        "Apple Client",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(
                            pinPreSharedKey,
                            hostId,
                            "different-device")),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(!rejection.Accepted);
            Equal(string.Empty, rejection.PairingId);
            Equal(0, rejection.Psk.Length);
            Equal(0, store.Snapshot().Count);
            Equal(0, vault.Count);

            PairResponseMessage accepted = await SendPairingRequestAsync(
                    transport,
                    endpoint,
                    credential,
                    new PairRequestMessage(
                        " Apple Client ",
                        $" {clientDeviceId} ",
                        PeelPinPairing.CreateProof(
                            pinPreSharedKey,
                            hostId,
                            clientDeviceId)),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(accepted.Accepted);
            Equal("Windows Host", accepted.HostName);
            Equal("Peel on Windows Host", accepted.ServiceName);
            True(!string.IsNullOrWhiteSpace(accepted.PairingId));
            Equal(WindowsPairedClientStore.PreSharedKeyBytes, accepted.Psk.Length);
            Equal(1, store.Snapshot().Count);
            Equal("Apple Client", store.Snapshot()[0].DisplayName);
            Equal(clientDeviceId, store.Snapshot()[0].DeviceId);
            Equal(1, vault.Count);
            True(store.TryResolve(accepted.PairingId, out PeelPskCredential? resolved));
            PeelPskCredential resolvedCredential = resolved ??
                throw new InvalidDataException("The accepted pairing did not resolve.");
            True(resolvedCredential.PreSharedKey.AsSpan().SequenceEqual(accepted.Psk));
            CryptographicOperations.ZeroMemory(resolvedCredential.PreSharedKey);
            CryptographicOperations.ZeroMemory(accepted.Psk);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pinPreSharedKey);
            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            vault.Dispose();
        }
    }

    private static async Task PinPairingListenerSurvivesHostileJson()
    {
        const string hostId = "windows-host-hostile";
        var vault = new RecordingCredentialVault();
        var store = new WindowsPairedClientStore(
            vault,
            new RecordingPairedClientMetadataRepository(),
            "ZephyrStudios.Peel.Tests.PairingHostile.PSK");
        HostPairingPin pin = CreateTestPairingPin(DateTimeOffset.UtcNow.AddMinutes(1));
        var transport = new BouncyCastlePskTransportFactory();
        byte[] pinPreSharedKey = pin.DerivePreSharedKey(hostId);
        var credential = new PeelPskCredential(
            PeelPinPairing.TlsIdentity,
            pinPreSharedKey);

        try
        {
            await using var listener = new HostPinPairingListener(
                transport,
                store,
                hostId,
                "Windows Host",
                "Peel on Windows Host",
                pin,
                new HostPinPairingListenerOptions(
                    acceptWorkerCount: 1,
                    maximumActiveConnections: 2,
                    maximumRequestBytes: 1024,
                    requestTimeout: TimeSpan.FromSeconds(1)));
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await listener.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    cancellation.Token)
                .ConfigureAwait(false);
            var endpoint = listener.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException("The pairing listener did not publish an endpoint.");

            await SendHostilePairingDocumentAsync(
                    transport,
                    endpoint,
                    credential,
                    "{\"type\":\"futurePairRequest\"}"u8.ToArray(),
                    cancellation.Token)
                .ConfigureAwait(false);
            await SendHostilePairingDocumentAsync(
                    transport,
                    endpoint,
                    credential,
                    Enumerable.Repeat((byte)'{', 2048).ToArray(),
                    cancellation.Token)
                .ConfigureAwait(false);
            Equal(0, store.Snapshot().Count);
            True(!listener.Completion.IsCompleted);

            const string clientDeviceId = "client-after-hostile";
            PairResponseMessage accepted = await SendPairingRequestAsync(
                    transport,
                    endpoint,
                    credential,
                    new PairRequestMessage(
                        "Client",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(
                            pinPreSharedKey,
                            hostId,
                            clientDeviceId)),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(accepted.Accepted);
            Equal(1, store.Snapshot().Count);
            CryptographicOperations.ZeroMemory(accepted.Psk);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pinPreSharedKey);
            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            vault.Dispose();
        }
    }

    private static async Task ExpiredPinPairingIsRejected()
    {
        const string hostId = "windows-host-expired";
        const string clientDeviceId = "client-expired";
        var vault = new RecordingCredentialVault();
        var store = new WindowsPairedClientStore(
            vault,
            new RecordingPairedClientMetadataRepository(),
            "ZephyrStudios.Peel.Tests.PairingExpired.PSK");
        HostPairingPin pin = CreateTestPairingPin(DateTimeOffset.UtcNow.AddMinutes(-1));
        var transport = new BouncyCastlePskTransportFactory();
        byte[] pinPreSharedKey = pin.DerivePreSharedKey(hostId);
        var credential = new PeelPskCredential(
            PeelPinPairing.TlsIdentity,
            pinPreSharedKey);

        try
        {
            await using var listener = new HostPinPairingListener(
                transport,
                store,
                hostId,
                "Windows Host",
                "Peel on Windows Host",
                pin,
                new HostPinPairingListenerOptions(
                    acceptWorkerCount: 1,
                    maximumActiveConnections: 2));
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await listener.StartAsync(
                    new IPEndPoint(IPAddress.Loopback, 0),
                    cancellation.Token)
                .ConfigureAwait(false);
            var endpoint = listener.LocalEndPoint as IPEndPoint ??
                throw new InvalidDataException("The pairing listener did not publish an endpoint.");

            PairResponseMessage rejection = await SendPairingRequestAsync(
                    transport,
                    endpoint,
                    credential,
                    new PairRequestMessage(
                        "Client",
                        clientDeviceId,
                        PeelPinPairing.CreateProof(
                            pinPreSharedKey,
                            hostId,
                            clientDeviceId)),
                    cancellation.Token)
                .ConfigureAwait(false);
            True(!rejection.Accepted);
            True(rejection.Reason?.Contains("expired", StringComparison.OrdinalIgnoreCase) == true);
            Equal(0, store.Snapshot().Count);
            Equal(0, vault.Count);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pinPreSharedKey);
            CryptographicOperations.ZeroMemory(credential.PreSharedKey);
            vault.Dispose();
        }
    }

    private static async Task NetworkInputDefaultsClosedAndReportsRejection()
    {
        const string identity = "paired-input-client";
        WindowDescriptor window = CreateVideoWindow();
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Input Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new PeelRequest(PeelMessageType.MouseClick, 1, 0.5, 0.5, "left"),
            new KeyboardTextMessage("blocked", WindowId: 1),
            new KeyboardMacroMessage([KeyboardMacroStep.ForText("blocked")], WindowId: 1));

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            identity,
            new FakeWindowEnumerator([window])).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);

        Equal(5, lines.Count);
        for (var index = 2; index < lines.Count; index++)
        {
            InputRejectedMessage rejected = PeelJson.Deserialize<InputRejectedMessage>(lines[index]);
            Equal<uint>(1, rejected.WindowId);
            Equal(PeelMessageType.InputRejected, rejected.Type);
            True(!string.IsNullOrWhiteSpace(rejected.Reason));
        }

        InputRejectedMessage pointerRejected =
            PeelJson.Deserialize<InputRejectedMessage>(lines[2]);
        InputRejectedMessage textRejected =
            PeelJson.Deserialize<InputRejectedMessage>(lines[3]);
        True(pointerRejected.Reason.Contains("disabled", StringComparison.OrdinalIgnoreCase));
        True(textRejected.Reason.Contains("disabled", StringComparison.OrdinalIgnoreCase));
    }

    private static async Task AuthenticatedControlDispatchesBoundedInput()
    {
        const string identity = "enabled-input-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var targetResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        var factory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(gate, targetResolver, injector));
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Enabled Input Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new PeelRequest(PeelMessageType.MouseDown, 1, -10, 10, "left"),
            new PeelRequest(PeelMessageType.MouseDrag, 1, 0.75, 0.25, "left"),
            new PeelRequest(PeelMessageType.MouseUp, 1, 0.75, 0.25, "left"),
            new PeelRequest(PeelMessageType.MouseMove, 1, 0.4, 0.6),
            new PeelRequest(PeelMessageType.MouseScroll, 1, double.MaxValue, -double.MaxValue),
            new KeyboardTextMessage("hello", WindowId: 1),
            new KeyboardCommandMessage(
                KeyboardCommand.F1,
                WindowId: 1,
                Modifiers: [KeyboardCommand.Shift]),
            new KeyboardHardwareKeyMessage(
                KeyCode: 8,
                Modifiers: [KeyboardCommand.Command],
                WindowId: 1,
                Characters: "c",
                CharactersIgnoringModifiers: "c"),
            new KeyboardHardwareKeyMessage(
                KeyCode: 80,
                Modifiers: [KeyboardCommand.Option],
                WindowId: 1),
            new KeyboardHardwareKeyMessage(
                KeyCode: 47,
                Modifiers: [KeyboardCommand.Command],
                WindowId: 1,
                Characters: "[",
                CharactersIgnoringModifiers: "["),
            new KeyboardChordMessage(
                new KeyboardChord([KeyboardCommand.Control, KeyboardCommand.Escape]),
                WindowId: 1));

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            identity,
            new FakeWindowEnumerator([window]),
            inputSessionFactory: factory).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);

        Equal(2, lines.Count);
        Equal(12, injector.Calls.Count);
        Equal("pointer:Left:Down:-10:10", injector.Calls[0]);
        Equal("move:0.75:0.25", injector.Calls[1]);
        Equal("pointer:Left:Up:0.75:0.25", injector.Calls[2]);
        Equal("move:0.4:0.6", injector.Calls[3]);
        Equal("move:0.4:0.6", injector.Calls[4]);
        Equal("wheel:-1200:1200", injector.Calls[5]);
        Equal("text:5", injector.Calls[6]);
        Equal("chord:16,112", injector.Calls[7]);
        Equal("chord:17,67", injector.Calls[8]);
        Equal("chord:18,37", injector.Calls[9]);
        Equal("chord:17,219", injector.Calls[10]);
        True(injector.Calls.Contains("chord:17,27", StringComparer.Ordinal));
        Equal(8, targetResolver.AcquireForegroundCount);
        Equal(1, targetResolver.RequireForegroundCount);
        Equal(0, injector.ReleaseCount);
    }

    private static async Task MacHeldHardwareKeysAcceptModifierSnapshots()
    {
        const string identity = "mac-held-key-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var factory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(gate, resolver, injector));
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Mac", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(4, [KeyboardCommand.Shift], WindowId: 1,
                Characters: "A", CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(4, [KeyboardCommand.Shift], WindowId: 1,
                Characters: "A", CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Up),
            new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Up),
            new KeyboardHardwareKeyMessage(227, [], WindowId: 1, Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(6, [KeyboardCommand.Command, KeyboardCommand.Control], WindowId: 1,
                CharactersIgnoringModifiers: "c", Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(6, [KeyboardCommand.Control, KeyboardCommand.Command], WindowId: 1,
                CharactersIgnoringModifiers: "c", Action: KeyboardCommandAction.Up),
            new KeyboardHardwareKeyMessage(227, [], WindowId: 1, Action: KeyboardCommandAction.Up),
            // Aggregate state is informational: it must not invent Option down/up.
            new KeyboardHardwareKeyMessage(5, [KeyboardCommand.Option], WindowId: 1,
                CharactersIgnoringModifiers: "b", Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(5, [], WindowId: 1,
                CharactersIgnoringModifiers: "b", Action: KeyboardCommandAction.Up));
        ScriptedDuplexStream stream = await RunCompletedSessionAsync(input, identity,
            new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);

        Equal(2, ReadOutputLines(stream).Count);
        True(injector.Calls.SequenceEqual([
            "key:16:Down", "key:65:Down", "key:65:Up", "key:16:Up",
            "key:17:Down", "key:67:Down", "key:67:Up", "key:17:Up",
            "key:66:Down", "key:66:Up"], StringComparer.Ordinal));
        Equal(0, injector.ReleaseCount);
        Equal(5, resolver.AcquireForegroundCount);
    }

    private static void HardwareModifierSnapshotsRejectNonModifiers()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var resolver = new RecordingWindowInputTargetResolver(window.Bounds);
        using var session = new WindowsHostInputSession(gate, resolver, injector);
        IReadOnlyList<KeyboardCommand>[] invalid = [
            [KeyboardCommand.F1], [KeyboardCommand.ReturnKey],
            [(KeyboardCommand)int.MaxValue], Enumerable.Repeat(KeyboardCommand.Shift, 9).ToArray(),
            Enumerable.Repeat(KeyboardCommand.Function, 9).ToArray()];
        foreach (IReadOnlyList<KeyboardCommand> modifiers in invalid)
        {
            foreach (KeyboardCommandAction action in Enum.GetValues<KeyboardCommandAction>())
            {
                True(!session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                    4, modifiers, WindowId: 1, CharactersIgnoringModifiers: "a", Action: action), window).Succeeded);
            }
        }
        Equal(0, injector.Calls.Count);
        Equal(0, resolver.ResolveCount);
    }

    private static async Task HeldHardwareModifiersReleaseOnRevokeAndDisconnect()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var revokedInjector = new RecordingInputInjector();
        using (var session = new WindowsHostInputSession(gate,
            new RecordingWindowInputTargetResolver(window.Bounds), revokedInjector))
        {
            True(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                225, [], WindowId: 1, Action: KeyboardCommandAction.Down), window).Succeeded);
            True(session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down), window).Succeeded);
            True(!session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.F1], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Up), window).Succeeded);
            Equal(0, revokedInjector.ReleaseCount);
            gate.SetEnabled(false);
            Equal(1, revokedInjector.ReleaseCount);
            True(revokedInjector.ReleasedVirtualKeys.Order().SequenceEqual(new ushort[] { 16, 65 }));
            True(!session.HandleKeyboardHardwareKey(new KeyboardHardwareKeyMessage(
                4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Up), window).Succeeded);
        }
        Equal(1, revokedInjector.ReleaseCount);

        const string identity = "mac-disconnect-held-key-client";
        gate.SetEnabled(true);
        var disconnectedInjector = new RecordingInputInjector();
        var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
            new RecordingWindowInputTargetResolver(window.Bounds), disconnectedInjector));
        ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(
            PeelHello.CreateClient(identity, "Mac", "macOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down)), identity,
            new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
        Equal(2, ReadOutputLines(stream).Count);
        Equal(1, disconnectedInjector.ReleaseCount);
        True(disconnectedInjector.ReleasedVirtualKeys.Order().SequenceEqual(new ushort[] { 16, 65 }));
    }

    private static async Task KeyboardDeleteCommandsPreserveDirection()
    {
        const string identity = "delete-direction-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var targetResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        var factory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(gate, targetResolver, injector));
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Delete Direction Client", "iOS"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new KeyboardCommandMessage(KeyboardCommand.Backspace, WindowId: 1),
            new KeyboardCommandMessage(KeyboardCommand.Delete, WindowId: 1),
            new KeyboardCommandMessage(KeyboardCommand.ForwardDelete, WindowId: 1));

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            identity,
            new FakeWindowEnumerator([window]),
            inputSessionFactory: factory).ConfigureAwait(false);

        Equal(2, ReadOutputLines(stream).Count);
        Equal(3, injector.Calls.Count);
        Equal("key:8:Press", injector.Calls[0]);
        Equal("key:8:Press", injector.Calls[1]);
        Equal("key:46:Press", injector.Calls[2]);
        Equal(3, targetResolver.AcquireForegroundCount);
        Equal(0, injector.ReleaseCount);
    }

    private static async Task ActiveWindowFocusHonorsInputGateAndWindowIdentity()
    {
        const string identity = "active-window-client";
        WindowDescriptor window = CreateVideoWindow();

        var disabledGate = new InputPermissionGate();
        var disabledResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var disabledFactory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(
                disabledGate,
                disabledResolver,
                new RecordingInputInjector()));
        ScriptedDuplexStream disabledStream = await RunCompletedSessionAsync(
            CombineLines(
                PeelHello.CreateClient(identity, "Disabled Focus Client", "Windows"),
                new PeelRequest(PeelMessageType.RequestWindowList),
                new ClientActiveWindowMessage(1)),
            identity,
            new FakeWindowEnumerator([window]),
            inputSessionFactory: disabledFactory).ConfigureAwait(false);
        IReadOnlyList<byte[]> disabledLines = ReadOutputLines(disabledStream);

        Equal(3, disabledLines.Count);
        WindowFocusStateMessage disabledFocus =
            PeelJson.Deserialize<WindowFocusStateMessage>(disabledLines[2]);
        Equal(PeelMessageType.WindowFocusState, disabledFocus.Type);
        Equal<uint?>(1, disabledFocus.RequestedWindowId);
        True(disabledFocus.ActiveWindowId is null);
        True(!disabledFocus.DidActivateRequestedWindow);
        Equal(0, disabledResolver.ResolveCount);

        var enabledGate = new InputPermissionGate();
        enabledGate.SetEnabled(true);
        var enabledResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var enabledFactory = new DelegateHostInputSessionFactory(() =>
            new WindowsHostInputSession(
                enabledGate,
                enabledResolver,
                new RecordingInputInjector()));
        ScriptedDuplexStream enabledStream = await RunCompletedSessionAsync(
            CombineLines(
                PeelHello.CreateClient(identity, "Enabled Focus Client", "Windows"),
                new PeelRequest(PeelMessageType.RequestWindowList),
                new ClientActiveWindowMessage(1),
                new ClientActiveWindowMessage(0),
                new ClientActiveWindowMessage(99),
                new ClientActiveWindowMessage(1)),
            identity,
            new FakeWindowEnumerator([window]),
            inputSessionFactory: enabledFactory).ConfigureAwait(false);
        IReadOnlyList<byte[]> enabledLines = ReadOutputLines(enabledStream);

        Equal(6, enabledLines.Count);
        WindowFocusStateMessage firstFocus =
            PeelJson.Deserialize<WindowFocusStateMessage>(enabledLines[2]);
        Equal<uint?>(1, firstFocus.ActiveWindowId);
        Equal<uint?>(1, firstFocus.RequestedWindowId);
        True(firstFocus.DidActivateRequestedWindow);

        foreach (var index in new[] { 3, 4 })
        {
            WindowFocusStateMessage rejectedFocus =
                PeelJson.Deserialize<WindowFocusStateMessage>(enabledLines[index]);
            True(rejectedFocus.ActiveWindowId is null);
            True(!rejectedFocus.DidActivateRequestedWindow);
        }

        WindowFocusStateMessage recoveredFocus =
            PeelJson.Deserialize<WindowFocusStateMessage>(enabledLines[5]);
        Equal<uint?>(1, recoveredFocus.ActiveWindowId);
        True(recoveredFocus.DidActivateRequestedWindow);
        Equal(2, enabledResolver.ResolveCount);
        Equal(2, enabledResolver.AcquireForegroundCount);

        byte[] malformedPrefix = CombineLines(
            PeelHello.CreateClient(identity, "Malformed Focus Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList));
        byte[] malformedFocus = System.Text.Encoding.UTF8.GetBytes(
            "{\"type\":\"clientActiveWindow\",\"windowId\":\"not-an-id\"}\n");
        ScriptedDuplexStream malformedStream = await RunCompletedSessionAsync(
            [.. malformedPrefix, .. malformedFocus],
            identity,
            new FakeWindowEnumerator([window]),
            inputSessionFactory: enabledFactory).ConfigureAwait(false);
        Equal(2, ReadOutputLines(malformedStream).Count);
        Equal(2, enabledResolver.ResolveCount);
    }

    private static void ScrollPreservesFractionalMotion()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        using var session = new WindowsHostInputSession(
            gate,
            new RecordingWindowInputTargetResolver(window.Bounds),
            injector);

        for (var index = 0; index < 4; index++)
        {
            True(session.HandleMouse(
                new PeelRequest(PeelMessageType.MouseScroll, 1, 0, 0.6),
                window).Succeeded);
        }

        Equal(4, injector.Calls.Count(call => call.StartsWith("move:", StringComparison.Ordinal)));
        True(injector.Calls.Where(call => call.StartsWith("wheel:", StringComparison.Ordinal))
            .SequenceEqual(["wheel:1:0"]));
    }

    private static void InputSessionRejectsHostileDataAndReleasesHeldState()
    {
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var targetResolver = new RecordingWindowInputTargetResolver(window.Bounds);
        var injector = new RecordingInputInjector();
        using var session = new WindowsHostInputSession(gate, targetResolver, injector);

        InputInjectionResult dragWithoutDown = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseDrag, 1, 0.5, 0.5, "left"),
            window);
        InputInjectionResult nonFinite = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseClick, 1, double.NaN, 0.5, "left"),
            window);
        InputInjectionResult nonFiniteMove = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseMove, 1, double.PositiveInfinity, 0.5),
            window);
        InputInjectionResult missingScrollDelta = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseScroll, 1, 5, null),
            window);
        InputInjectionResult unknownButton = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseClick, 1, 0.5, 0.5, "sideways"),
            window);
        InputInjectionResult oversizedText = session.HandleKeyboardText(
            new KeyboardTextMessage(new string('x', 4097), WindowId: 1),
            window);
        InputInjectionResult unmappableHardware = session.HandleKeyboardHardwareKey(
            new KeyboardHardwareKeyMessage(
                KeyCode: int.MaxValue,
                Modifiers: [],
                WindowId: 1,
                CharactersIgnoringModifiers: "!"),
            window);
        InputInjectionResult macro = session.HandleKeyboardMacro(
            new KeyboardMacroMessage([KeyboardMacroStep.ForDelay(int.MaxValue)], WindowId: 1),
            window);

        True(!dragWithoutDown.Succeeded);
        True(!nonFinite.Succeeded);
        True(!nonFiniteMove.Succeeded);
        True(!missingScrollDelta.Succeeded);
        True(!unknownButton.Succeeded);
        True(!oversizedText.Succeeded);
        True(!unmappableHardware.Succeeded);
        True(!macro.Succeeded);
        Equal(0, injector.Calls.Count);
        Equal(0, targetResolver.ResolveCount);

        True(session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseDown, 1, 0.25, 0.75, "right"),
            window).Succeeded);
        WindowDescriptor otherWindow = window with { Handle = (nint)0xBEEF };
        InputInjectionResult crossWindowDrag = session.HandleMouse(
            new PeelRequest(PeelMessageType.MouseDrag, 2, 0.5, 0.5, "right"),
            otherWindow);
        True(!crossWindowDrag.Succeeded);
        True(session.HandleKeyboardCommand(
            new KeyboardCommandMessage(
                KeyboardCommand.F2,
                WindowId: 1,
                Action: KeyboardCommandAction.Down),
            window).Succeeded);
        gate.SetEnabled(false);

        Equal(1, injector.ReleaseCount);
        True(injector.ReleasedMouseButtons.SequenceEqual([MouseButton.Right]));
        True(injector.ReleasedVirtualKeys.SequenceEqual([(ushort)0x71]));
        InputInjectionResult blockedAfterDisable = session.HandleKeyboardText(
            new KeyboardTextMessage("blocked", WindowId: 1),
            window);
        True(!blockedAfterDisable.Succeeded);
        True(blockedAfterDisable.Error?.Contains("disabled", StringComparison.OrdinalIgnoreCase) == true);
    }

    private static async Task SecureHelloAndWindowList()
    {
        const string identity = "paired-client-1";
        var enumerator = new FakeWindowEnumerator(
        [
            new WindowDescriptor(
                (nint)0x1234,
                42,
                "Notepad",
                "Notepad",
                "notes.txt",
                new WindowBounds(10, 20, 800, 600),
                "aWNvbg==",
                1_785_740_000.5),
        ]);
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Test Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new ClientPingMessage());

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            identity,
            enumerator).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);

        Equal(2, lines.Count);
        HostHelloMessage hostHello = PeelJson.Deserialize<HostHelloMessage>(lines[0]);
        Equal(PeelMessageType.HostHello, hostHello.Type);
        Equal("Windows", hostHello.Platform);
        Equal<int?>(PeelProtocol.CurrentProtocolVersion, hostHello.ProtocolVersion);
        True((hostHello.Capabilities ?? []).SequenceEqual(
            HostCapabilities().Order(StringComparer.Ordinal),
            StringComparer.Ordinal));

        WindowListMessage windowList = PeelJson.Deserialize<WindowListMessage>(lines[1]);
        Equal(1, windowList.Windows.Count);
        Equal<uint>(1, windowList.Windows[0].WindowId);
        Equal("Notepad", windowList.Windows[0].AppName);
        Equal("notes.txt", windowList.Windows[0].Title);
        Equal(800, windowList.Windows[0].Width);
        Equal(600, windowList.Windows[0].Height);
        Equal("aWNvbg==", windowList.Windows[0].AppIconPngBase64);
        Equal<double?>(1_785_740_000.5, windowList.Windows[0].AppLaunchTimeIntervalSince1970);
        Equal(1, enumerator.CallCount);
    }

    private static async Task SamePeerHelloRefreshPreservesSessionAndHiddenState()
    {
        const string identity = "mac-refresh-client";
        WindowDescriptor window = CreateVideoWindow();
        var gate = new InputPermissionGate();
        gate.SetEnabled(true);
        var injector = new RecordingInputInjector();
        var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
            new RecordingWindowInputTargetResolver(window.Bounds), injector));
        var awake = new RecordingHostAwakeController();
        int authenticated = 0;
        await using var manager = new HostControlSessionManager(new FakeWindowEnumerator([window]), factory,
            new HostControlSessionOptions("Test Host"), _ => Interlocked.Increment(ref authenticated), awake);
        var stream = new InteractiveDuplexStream();
        Task session = manager.RunAuthenticatedSessionAsync(new PeelPskConnection(stream, identity));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        stream.EnqueueLines(PeelHello.CreateClient(identity, "Mac", "macOS", capabilities: ["initial"]),
            new PeelRequest(PeelMessageType.RequestWindowList),
            new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down));
        await WaitForMinimumAsync(() => injector.Calls.Count, 1, timeout.Token).ConfigureAwait(false);
        long? generation = manager.ActiveGeneration;
        var bindings = (IHostVideoBindingResolver)manager;
        True(bindings.TryResolveVideoBinding(identity, 1, out HostVideoBinding? original));
        True(original is not null);

        stream.EnqueueLines(new ClientVisibilityMessage(false),
            PeelHello.CreateClient(identity, "Mac", "macOS", capabilities: ["updated", "agent-presentation-v1"]),
            PeelHello.CreateClient(identity, "Mac", "macOS", capabilities: ["updated"]),
            new KeyboardHardwareKeyMessage(4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Down),
            new KeyboardHardwareKeyMessage(4, [KeyboardCommand.Shift], WindowId: 1,
                CharactersIgnoringModifiers: "a", Action: KeyboardCommandAction.Up));
        await WaitForMinimumAsync(() => injector.Calls.Count, 3, timeout.Token).ConfigureAwait(false);
        True(!session.IsCompleted);
        Equal(generation, manager.ActiveGeneration);
        True(!manager.IsActiveClientVisible && !manager.IsPreventingSleep);
        await WaitForMinimumAsync(() => Volatile.Read(ref authenticated), 1, timeout.Token);
        Equal(1, Volatile.Read(ref authenticated));
        Equal(2, ReadOutputLines(stream.WrittenBytes).Count);
        Equal(0, injector.ReleaseCount);
        True(bindings.IsCurrentVideoBinding(original!));
        True(!original!.ControlLifetime.IsCancellationRequested);
        True(original.ClientCapabilities.SetEquals(["initial"]));
        True(bindings.TryResolveVideoBinding(identity, 1, out HostVideoBinding? refreshed));
        True(refreshed is not null && refreshed.ClientCapabilities.SetEquals(["updated"]));
        stream.EnqueueLines(new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Up));
        await WaitForMinimumAsync(() => injector.Calls.Count, 4, timeout.Token).ConfigureAwait(false);
        stream.EnqueueLines(PeelHello.CreateClient(identity, "Mac", "macOS") with { Capabilities = null },
            new ClientActiveWindowMessage(1));
        await WaitForMinimumAsync(() => ReadOutputLines(stream.WrittenBytes).Count, 3, timeout.Token).ConfigureAwait(false);
        True(!manager.IsActiveClientVisible && !manager.IsPreventingSleep);
        True(bindings.TryResolveVideoBinding(identity, 1, out HostVideoBinding? emptyCapabilities));
        True(emptyCapabilities is not null && emptyCapabilities.ClientCapabilities.Count == 0);
        stream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, 1),
            PeelHello.CreateClient(identity, "Mac", "macOS", capabilities: ["after-stop"]),
            new ClientActiveWindowMessage(1));
        await WaitForMinimumAsync(() => ReadOutputLines(stream.WrittenBytes).Count, 4, timeout.Token).ConfigureAwait(false);
        True(!bindings.TryResolveVideoBinding(identity, 1, out _));
        True(!manager.IsActiveClientVisible && !manager.IsPreventingSleep);
        Equal(1, ReadOutputLines(stream.WrittenBytes).Count(line =>
            PeelJson.ReadEnvelope(line).Type == PeelMessageType.HostHello));
        stream.CompleteInput();
        await session.WaitAsync(timeout.Token).ConfigureAwait(false);
        Equal(0, injector.ReleaseCount);
        True(original.ControlLifetime.IsCancellationRequested);
        True(awake.Updates.SequenceEqual([true, false]));
    }

    private static async Task HelloRefreshRejectsIdentityAndProtocolChanges()
    {
        const string identity = "refresh-validation-client";
        ClientHelloMessage hello = PeelHello.CreateClient(identity, "Mac", "macOS");
        object[] invalid = [
            hello with { PairingId = "different-peer" },
            hello with { DeviceName = " " },
            hello with { Platform = " " },
            hello with { ProtocolVersion = 1, MinimumSupportedProtocolVersion = 1 },
            new { type = PeelMessageType.ClientHello, deviceName = "Mac", platform = "macOS", protocolVersion = "bad" }];
        foreach (object refresh in invalid)
        {
            var gate = new InputPermissionGate();
            gate.SetEnabled(true);
            var injector = new RecordingInputInjector();
            WindowDescriptor window = CreateVideoWindow();
            var factory = new DelegateHostInputSessionFactory(() => new WindowsHostInputSession(gate,
                new RecordingWindowInputTargetResolver(window.Bounds), injector));
            ScriptedDuplexStream stream = await RunCompletedSessionAsync(CombineLines(hello,
                new PeelRequest(PeelMessageType.RequestWindowList),
                new KeyboardHardwareKeyMessage(225, [], WindowId: 1, Action: KeyboardCommandAction.Down),
                refresh, new KeyboardTextMessage("must not run", WindowId: 1)), identity,
                new FakeWindowEnumerator([window]), inputSessionFactory: factory).ConfigureAwait(false);
            True(injector.Calls.SequenceEqual(["key:16:Down"], StringComparer.Ordinal));
            Equal(1, injector.ReleaseCount);
            True(injector.ReleasedVirtualKeys.SequenceEqual(new ushort[] { 16 }));
            IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
            bool incompatible = refresh is ClientHelloMessage { ProtocolVersion: 1 };
            Equal(incompatible ? 3 : 2, lines.Count);
            if (incompatible)
            {
                Equal(PeelMessageType.ProtocolRejected, PeelJson.ReadEnvelope(lines[^1]).Type);
            }
        }
    }

    private static async Task ClientHelloMustBeFirst()
    {
        byte[] input = CombineLines(new PeelRequest(PeelMessageType.RequestWindowList));
        var enumerator = new FakeWindowEnumerator([]);

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            "paired-client",
            enumerator).ConfigureAwait(false);

        Equal(0, ReadOutputLines(stream).Count);
        Equal(0, enumerator.CallCount);
    }

    private static async Task TlsIdentityMismatchRejected()
    {
        byte[] input = CombineLines(PeelHello.CreateClient(
            "claimed-client",
            "Test Client",
            "Windows"));

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            input,
            "authenticated-client",
            new FakeWindowEnumerator([])).ConfigureAwait(false);

        Equal(0, ReadOutputLines(stream).Count);
    }

    private static async Task IncompatibleProtocolRejected()
    {
        var hello = new ClientHelloMessage(
            "paired-client",
            "Old Client",
            "Windows",
            ProtocolVersion: 1,
            MinimumSupportedProtocolVersion: 1);

        ScriptedDuplexStream stream = await RunCompletedSessionAsync(
            CombineLines(hello),
            "paired-client",
            new FakeWindowEnumerator([])).ConfigureAwait(false);
        IReadOnlyList<byte[]> lines = ReadOutputLines(stream);

        Equal(1, lines.Count);
        ProtocolRejectedMessage rejection = PeelJson.Deserialize<ProtocolRejectedMessage>(lines[0]);
        Equal(PeelMessageType.ProtocolRejected, rejection.Type);
        Equal(PeelProtocol.CurrentProtocolVersion, rejection.LocalProtocolVersion);
    }

    private static async Task AuthenticatedHelloRecordsPairedClientActivity()
    {
        const string identity = "paired-client-activity";
        var authenticatedPeers = new ConcurrentQueue<string>();
        await using var manager = new HostControlSessionManager(
            new FakeWindowEnumerator([]),
            new HostControlSessionOptions("Test Host"),
            authenticatedPeers.Enqueue);

        var acceptedStream = new ScriptedDuplexStream(CombineLines(
            PeelHello.CreateClient(identity, "Activity Client", "Windows")));
        await manager.RunAuthenticatedSessionAsync(
                new PeelPskConnection(acceptedStream, identity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        using var activityTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await WaitForMinimumAsync(() => authenticatedPeers.Count, 1, activityTimeout.Token);
        Equal(1, authenticatedPeers.Count);
        Equal(identity, authenticatedPeers.First());

        var rejectedStream = new ScriptedDuplexStream(CombineLines(
            PeelHello.CreateClient("different-pairing", "Rejected Client", "Windows")));
        await manager.RunAuthenticatedSessionAsync(
                new PeelPskConnection(rejectedStream, identity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        Equal(1, authenticatedPeers.Count);
    }

    private static async Task ClientVisibilityOwnsHostAwakeState()
    {
        const string identity = "visible-client";
        var awake = new RecordingHostAwakeController();
        int stateChangeCount = 0;
        var manager = new HostControlSessionManager(
            new FakeWindowEnumerator([]),
            new WindowsHostInputSessionFactory(new InputPermissionGate()),
            new HostControlSessionOptions("Test Host"),
            awakeController: awake,
            clientStateChanged: () => Interlocked.Increment(ref stateChangeCount));
        try
        {
            var stream = new InteractiveDuplexStream();
            Task session = manager.RunAuthenticatedSessionAsync(
                new PeelPskConnection(stream, identity));

            stream.EnqueueLines(PeelHello.CreateClient(
                identity,
                "Visible Client",
                "Windows",
                capabilities: [PeelCapability.ClientVisibility]));
            True(await awake.ReadUpdateAsync().ConfigureAwait(false));
            True(manager.IsActiveClientVisible);
            True(manager.IsPreventingSleep);
            Equal<string?>(null, manager.AwakeError);

            IReadOnlyList<byte[]> helloLines = ReadOutputLines(stream.WrittenBytes);
            Equal(1, helloLines.Count);
            HostHelloMessage hostHello = PeelJson.Deserialize<HostHelloMessage>(helloLines[0]);
            True((hostHello.Capabilities ?? []).Contains(
                PeelCapability.ClientVisibility,
                StringComparer.Ordinal));

            stream.EnqueueLines(new ClientVisibilityMessage(false));
            True(!await awake.ReadUpdateAsync().ConfigureAwait(false));
            True(!manager.IsActiveClientVisible);
            True(!manager.IsPreventingSleep);

            stream.EnqueueLines(new PeelRequest(PeelMessageType.RequestWindowList));
            True(await awake.ReadUpdateAsync().ConfigureAwait(false));
            True(manager.IsActiveClientVisible);
            True(manager.IsPreventingSleep);

            stream.CompleteInput();
            True(!await awake.ReadUpdateAsync().ConfigureAwait(false));
            await session.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            True(!manager.IsActiveClientVisible);
            True(!manager.IsPreventingSleep);
            using var observerTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await WaitForMinimumAsync(() => Volatile.Read(ref stateChangeCount), 1, observerTimeout.Token);
            True(Volatile.Read(ref stateChangeCount) <= 4); // Latest-state UI notifications may coalesce.
            True(awake.Updates.SequenceEqual([true, false, true, false]));
        }
        finally
        {
            await manager.DisposeAsync().ConfigureAwait(false);
        }

        True(awake.IsDisposed);
    }

    private static async Task MalformedClientVisibilityFailsSoft()
    {
        const string identity = "hostile-visibility-client";
        var awake = new RecordingHostAwakeController();
        var manager = new HostControlSessionManager(
            new FakeWindowEnumerator([]),
            new WindowsHostInputSessionFactory(new InputPermissionGate()),
            new HostControlSessionOptions("Test Host"),
            awakeController: awake);
        try
        {
            byte[] hello = PeelJson.SerializeLine(PeelHello.CreateClient(
                identity,
                "Hostile Visibility Client",
                "Windows",
                capabilities: [PeelCapability.ClientVisibility]));
            byte[] malformed = System.Text.Encoding.UTF8.GetBytes(
                "{\"type\":\"clientVisibility\",\"isVisible\":\"yes\"}\n");
            var malformedStream = new ScriptedDuplexStream([.. hello, .. malformed]);
            await manager.RunAuthenticatedSessionAsync(
                    new PeelPskConnection(malformedStream, identity))
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);

            True(awake.Updates.SequenceEqual([true, false]));
            True(!manager.IsActiveClientVisible);
            True(!manager.IsPreventingSleep);
            Equal(1, ReadOutputLines(malformedStream).Count);

            var validStream = new ScriptedDuplexStream(hello);
            await manager.RunAuthenticatedSessionAsync(
                    new PeelPskConnection(validStream, identity))
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            True(awake.Updates.SequenceEqual([true, false, true, false]));
            Equal(1, ReadOutputLines(validStream).Count);
        }
        finally
        {
            await manager.DisposeAsync().ConfigureAwait(false);
        }
    }

    private static async Task MalformedAndOversizedLinesFailSoft()
    {
        HostControlSessionOptions smallLimits = new(
            "Test Host",
            maximumFirstLineBytes: 256,
            maximumControlLineBytes: 300);

        ScriptedDuplexStream malformed = await RunCompletedSessionAsync(
            System.Text.Encoding.UTF8.GetBytes("{not-json}\n"),
            "paired-client",
            new FakeWindowEnumerator([]),
            smallLimits).ConfigureAwait(false);
        Equal(0, ReadOutputLines(malformed).Count);

        ScriptedDuplexStream oversizedFirst = await RunCompletedSessionAsync(
            System.Text.Encoding.UTF8.GetBytes(new string('x', 257) + "\n"),
            "paired-client",
            new FakeWindowEnumerator([]),
            smallLimits).ConfigureAwait(false);
        Equal(0, ReadOutputLines(oversizedFirst).Count);

        byte[] validHello = PeelJson.SerializeLine(
            PeelHello.CreateClient("paired-client", "Test Client", "Windows"));
        byte[] oversizedControl = System.Text.Encoding.UTF8.GetBytes(new string('y', 301) + "\n");
        ScriptedDuplexStream oversizedAfterHello = await RunCompletedSessionAsync(
            [.. validHello, .. oversizedControl],
            "paired-client",
            new FakeWindowEnumerator([]),
            smallLimits).ConfigureAwait(false);
        Equal(1, ReadOutputLines(oversizedAfterHello).Count);
    }

    private static async Task ReplacementSessionSuppressesStaleResponse()
    {
        const string identity = "paired-client";
        var enumerator = new BlockingWindowEnumerator();
        var options = new HostControlSessionOptions("Test Host");
        var awake = new RecordingHostAwakeController();
        await using var manager = new HostControlSessionManager(
            enumerator,
            new WindowsHostInputSessionFactory(new InputPermissionGate()),
            options,
            awakeController: awake);

        var oldStream = new ScriptedDuplexStream(CombineLines(
            PeelHello.CreateClient(identity, "Old Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList)));
        Task oldSession = manager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(oldStream, identity));

        await enumerator.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(await awake.ReadUpdateAsync().ConfigureAwait(false));

        var replacementStream = new InteractiveDuplexStream();
        Task replacementSession = manager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(replacementStream, identity));
        True(!await awake.ReadUpdateAsync().ConfigureAwait(false));
        replacementStream.EnqueueLines(PeelHello.CreateClient(
            identity,
            "New Client",
            "Windows"));
        True(await awake.ReadUpdateAsync().ConfigureAwait(false));

        enumerator.Release.Set();
        await oldSession.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(manager.IsActiveClientVisible);
        True(manager.IsPreventingSleep);

        replacementStream.CompleteInput();
        True(!await awake.ReadUpdateAsync().ConfigureAwait(false));
        await replacementSession.WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        IReadOnlyList<byte[]> oldLines = ReadOutputLines(oldStream);
        IReadOnlyList<byte[]> replacementLines = ReadOutputLines(replacementStream.WrittenBytes);
        Equal(1, oldLines.Count);
        Equal(PeelMessageType.HostHello, PeelJson.ReadEnvelope(oldLines[0]).Type);
        Equal(1, replacementLines.Count);
        Equal(PeelMessageType.HostHello, PeelJson.ReadEnvelope(replacementLines[0]).Type);
    }

    private static async Task ReplacementSessionAbortsBlockedTransport()
    {
        const string identity = "blocked-replacement-client";
        var authenticated = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        await using var manager = new HostControlSessionManager(
            new FakeWindowEnumerator([]),
            new HostControlSessionOptions("Test Host"),
            _ => authenticated.TrySetResult());
        var blockedStream = new CancellationIgnoringDuplexStream(CombineLines(
            PeelHello.CreateClient(identity, "Blocked Client", "Windows")));

        Task blockedSession = manager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(blockedStream, identity));
        await authenticated.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        await blockedStream.BlockedReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        var replacementStream = new ScriptedDuplexStream(CombineLines(
            PeelHello.CreateClient(identity, "Replacement Client", "Windows")));
        Task replacementSession = manager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(replacementStream, identity));

        await Task.WhenAll(blockedSession, replacementSession)
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        True(blockedStream.IsDisposed);
    }

    private static async Task ListenerDisposalAbortsBlockedAuthenticatedTransport()
    {
        const string identity = "blocked-listener-client";
        var authenticated = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var blockedStream = new CancellationIgnoringDuplexStream(CombineLines(
            PeelHello.CreateClient(identity, "Blocked Listener Client", "Windows")));
        var accepted = new PeelPskConnection(blockedStream, identity);
        var transport = new SingleConnectionTransportFactory(accepted);
        var controlSessions = new HostControlSessionManager(
            new FakeWindowEnumerator([]),
            new HostControlSessionOptions("Test Host"),
            _ => authenticated.TrySetResult());
        var videoSessions = new HostVideoSessionManager(
            controlSessions,
            new SequencedCaptureBackend(),
            new SequencedEncoderFactory(),
            CreateVideoOptions());
        var listener = new HostAuthenticatedListener(
            transport,
            new StaticPskCredentialResolver(new PeelPskCredential(identity, new byte[32])),
            controlSessions,
            videoSessions,
            new HostAuthenticatedListenerOptions(
                acceptWorkerCount: 1,
                maximumActiveConnections: 1));
        await listener.StartAsync(new IPEndPoint(IPAddress.Loopback, 0)).ConfigureAwait(false);

        await authenticated.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        await blockedStream.BlockedReadEntered.Task.WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        await listener.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        True(blockedStream.IsDisposed);
    }

    private static async Task AuthenticatedRouterPreservesControlPrefix()
    {
        const string identity = "router-control-client";
        byte[] input = CombineLines(
            PeelHello.CreateClient(identity, "Router Client", "Windows"),
            new PeelRequest(PeelMessageType.RequestWindowList));
        byte[]? routedBytes = null;
        var router = new HostAuthenticatedConnectionRouter(
            async (connection, cancellationToken) =>
            {
                await using var ownedConnection = connection;
                routedBytes = await ReadAllBytesAsync(connection.Stream, cancellationToken)
                    .ConfigureAwait(false);
            },
            static (_, _) => throw new InvalidOperationException(
                "A clientHello connection was routed as video."),
            new HostAuthenticatedListenerOptions());
        var stream = new ScriptedDuplexStream(input, maximumReadBytes: input.Length);

        await router.RouteAsync(
                new PeelPskConnection(stream, identity),
                CancellationToken.None)
            .ConfigureAwait(false);

        True(routedBytes is not null && routedBytes.AsSpan().SequenceEqual(input));
    }

    private static async Task AuthenticatedRouterClassifiesVideoPrefix()
    {
        const string identity = "router-video-client";
        byte[] input =
        [
            .. PeelJson.SerializeLine(CreateVideoHello(identity)),
            0x01,
            0x02,
            0x03,
            0x04,
        ];
        byte[]? routedBytes = null;
        var router = new HostAuthenticatedConnectionRouter(
            static (_, _) => throw new InvalidOperationException(
                "A videoStreamHello connection was routed as control."),
            async (connection, cancellationToken) =>
            {
                await using var ownedConnection = connection;
                routedBytes = await ReadAllBytesAsync(connection.Stream, cancellationToken)
                    .ConfigureAwait(false);
            },
            new HostAuthenticatedListenerOptions());
        var stream = new ScriptedDuplexStream(input, maximumReadBytes: input.Length);

        await router.RouteAsync(
                new PeelPskConnection(stream, identity),
                CancellationToken.None)
            .ConfigureAwait(false);

        True(routedBytes is not null && routedBytes.AsSpan().SequenceEqual(input));
    }

    private static async Task AuthenticatedRouterRejectsHostileFirstLines()
    {
        var handlerCallCount = 0;
        Task UnexpectedHandler(PeelPskConnection connection, CancellationToken _)
        {
            Interlocked.Increment(ref handlerCallCount);
            return connection.DisposeAsync().AsTask();
        }

        var router = new HostAuthenticatedConnectionRouter(
            UnexpectedHandler,
            UnexpectedHandler,
            new HostAuthenticatedListenerOptions(maximumClassificationLineBytes: 32));

        await AssertRouterRejectsAsync(
            router,
            System.Text.Encoding.UTF8.GetBytes("{not-json}\n")).ConfigureAwait(false);
        await AssertRouterRejectsAsync(
            router,
            System.Text.Encoding.UTF8.GetBytes(new string('x', 33) + "\n"))
            .ConfigureAwait(false);
        await AssertRouterRejectsAsync(router, [(byte)'\n']).ConfigureAwait(false);
        Equal(0, handlerCallCount);
    }

    private static async Task AssertRouterRejectsAsync(
        HostAuthenticatedConnectionRouter router,
        byte[] input)
    {
        try
        {
            await router.RouteAsync(
                    new PeelPskConnection(
                        new ScriptedDuplexStream(input, maximumReadBytes: input.Length),
                        "hostile-router-client"),
                    CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is InvalidDataException or JsonException)
        {
            return;
        }

        throw new InvalidOperationException("Expected the authenticated router to reject input.");
    }

    private static void CaptureFrameLayoutValidation()
    {
        CaptureFrameLayout layout = CaptureFrameLayout.Create(
            contentWidth: 1920,
            contentHeight: 1080,
            surfaceWidth: 1920,
            surfaceHeight: 1080,
            mappedRowPitch: 8192);
        Equal(1920, layout.Width);
        Equal(1080, layout.Height);
        Equal(7680, layout.BytesPerRow);
        Equal(8_294_400, layout.PixelByteCount);

        Throws<InvalidDataException>(() => CaptureFrameLayout.Create(0, 1, 1, 1, 4));
        Throws<InvalidDataException>(() => CaptureFrameLayout.Create(2, 2, 1, 2, 8));
        Throws<InvalidDataException>(() => CaptureFrameLayout.Create(2, 2, 2, 2, 7));
        Throws<InvalidDataException>(() => CaptureFrameLayout.Create(
            CaptureFrameLayout.MaximumD3D11TextureDimension + 1,
            1,
            CaptureFrameLayout.MaximumD3D11TextureDimension,
            1,
            uint.MaxValue));
    }

    private static void CaptureTimestampsRemainMonotonic()
    {
        var clock = new CaptureTimestampClock();
        Equal(100L, clock.Next(TimeSpan.FromTicks(100)));
        Equal(101L, clock.Next(TimeSpan.FromTicks(100)));
        Equal(102L, clock.Next(TimeSpan.FromTicks(50)));
        Equal(103L, clock.Next(TimeSpan.FromTicks(-1)));
        Equal(500L, clock.Next(TimeSpan.FromTicks(500)));
    }

    private static void BgraCaptureConvertsToNv12()
    {
        byte[] redBgra =
        [
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
            0, 0, 255, 255,
        ];
        byte[] converted = BgraToNv12Converter.Convert(new CapturedFrame(
            2,
            2,
            8,
            1,
            CapturePixelFormat.Bgra8,
            redBgra));

        Equal(6, converted.Length);
        True(converted.AsSpan(0, 4).SequenceEqual(new byte[] { 82, 82, 82, 82 }));
        Equal((byte)90, converted[4]);
        Equal((byte)240, converted[5]);

        Throws<InvalidDataException>(() => BgraToNv12Converter.Convert(new CapturedFrame(
            3,
            2,
            12,
            2,
            CapturePixelFormat.Bgra8,
            new byte[24])));
        Throws<InvalidDataException>(() => BgraToNv12Converter.Convert(new CapturedFrame(
            2,
            2,
            8,
            3,
            CapturePixelFormat.Bgra8,
            new byte[15])));
    }

    private static void AnnexBBecomesLengthPrefixed()
    {
        byte[] annexB =
        [
            0, 0, 0, 1, 0x67, 0x42, 0x00,
            0, 0, 1, 0x68, 0xCE,
            0, 0, 0, 1, 0x65, 0xAA, 0xBB,
        ];

        H264AnnexB.AccessUnit converted = H264AnnexB.ConvertAccessUnit(annexB);
        True(converted.ContainsIdr);
        True(converted.SequenceParameterSet!.AsSpan().SequenceEqual(new byte[] { 0x67, 0x42 }));
        True(converted.PictureParameterSet!.AsSpan().SequenceEqual(new byte[] { 0x68, 0xCE }));
        True(converted.LengthPrefixedPayload.AsSpan().SequenceEqual(
            new byte[] { 0, 0, 0, 3, 0x65, 0xAA, 0xBB }));

        (byte[] sps, byte[] pps) = H264AnnexB.ReadParameterSets(annexB);
        True(sps.AsSpan().SequenceEqual(converted.SequenceParameterSet));
        True(pps.AsSpan().SequenceEqual(converted.PictureParameterSet));
        Throws<InvalidDataException>(() => H264AnnexB.ConvertAccessUnit(new byte[] { 0x65, 1 }));
    }

    private static async Task CapturePumpIsSerialAndLatestFrameWins()
    {
        using var pump = new LatestFramePump<DisposableCaptureToken>();
        var firstEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirst = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var newestEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var handled = new List<int>();
        var concurrentHandlers = 0;
        var maximumConcurrentHandlers = 0;

        Task runTask = pump.RunAsync(
            async (frame, cancellationToken) =>
            {
                int concurrent = Interlocked.Increment(ref concurrentHandlers);
                maximumConcurrentHandlers = Math.Max(maximumConcurrentHandlers, concurrent);
                try
                {
                    lock (handled)
                    {
                        handled.Add(frame.Id);
                    }

                    if (frame.Id == 1)
                    {
                        firstEntered.TrySetResult();
                        await releaseFirst.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                    }
                    else if (frame.Id == 3)
                    {
                        newestEntered.TrySetResult();
                    }
                }
                finally
                {
                    Interlocked.Decrement(ref concurrentHandlers);
                }
            },
            CancellationToken.None);

        var first = new DisposableCaptureToken(1);
        var replaced = new DisposableCaptureToken(2);
        var newest = new DisposableCaptureToken(3);
        pump.Publish(first);
        await firstEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        pump.Publish(replaced);
        pump.Publish(newest);
        True(replaced.IsDisposed);

        releaseFirst.TrySetResult();
        await newestEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        pump.Complete();
        await runTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        Equal(1, maximumConcurrentHandlers);
        Equal(2, handled.Count);
        Equal(1, handled[0]);
        Equal(3, handled[1]);
        True(first.IsDisposed);
        True(newest.IsDisposed);
    }

    private static void CapturePumpCompletionIsIdempotent()
    {
        using var pump = new LatestFramePump<DisposableCaptureToken>();
        var pending = new DisposableCaptureToken(1);
        var tooLate = new DisposableCaptureToken(2);

        pump.Publish(pending);
        pump.Complete();
        pump.Complete(new InvalidOperationException("ignored after completion"));
        pump.Publish(tooLate);

        True(pending.IsDisposed);
        True(tooLate.IsDisposed);
    }

    private static async Task VideoSessionEmitsConfigThenLatestRawFrames()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        using var controlLifetime = new CancellationTokenSource();
        var resolver = new FakeVideoBindingResolver(
            CreateVideoBinding(identity, window, controlLifetime.Token));
        var encoderEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseEncoder = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var encodedRawTimestamps = new List<long>();
        var encoder = new ScriptedVideoEncoder(async (frame, _) =>
        {
            lock (encodedRawTimestamps)
            {
                encodedRawTimestamps.Add(frame.Timestamp100Nanoseconds);
            }

            if (frame.Timestamp100Nanoseconds == 100)
            {
                encoderEntered.TrySetResult();
                await releaseEncoder.Task.ConfigureAwait(false);
                return CreateEncodedFrame(100, isKeyFrame: true, includeConfiguration: true);
            }

            return CreateEncodedFrame(frame.Timestamp100Nanoseconds, isKeyFrame: false);
        });
        var capture = new ScriptedCaptureSession(window, async (handler, cancellationToken) =>
        {
            await handler(CreateRawFrame(100), cancellationToken).ConfigureAwait(false);
            await encoderEntered.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            await handler(CreateRawFrame(200), cancellationToken).ConfigureAwait(false);
            await handler(CreateRawFrame(300), cancellationToken).ConfigureAwait(false);
        });
        var captureBackend = new SequencedCaptureBackend(capture);
        var encoderFactory = new SequencedEncoderFactory(encoder);
        var options = CreateVideoOptions();
        await using var manager = new HostVideoSessionManager(
            resolver,
            captureBackend,
            encoderFactory,
            options);
        var stream = new ScriptedDuplexStream(
            CombineLines(CreateVideoHello(identity)),
            maximumReadBytes: 7);

        Task sessionTask = manager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(stream, identity));
        await encoderEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        releaseEncoder.TrySetResult();
        await sessionTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        IReadOnlyList<IPeelBinaryPacket> packets =
            new PeelBinaryPacketReader(options.MaximumEncodedPacketBytes)
                .Append(stream.WrittenBytes);
        Equal(3, packets.Count);
        True(packets[0] is VideoConfigPacket);
        var firstFrame = (VideoFramePacket)packets[1];
        var latestFrame = (VideoFramePacket)packets[2];
        True(firstFrame.IsKeyframe);
        Equal(100L, firstFrame.PtsValue);
        Equal(0L, firstFrame.DurationValue);
        True(!latestFrame.IsKeyframe);
        Equal(300L, latestFrame.PtsValue);
        Equal(2, encodedRawTimestamps.Count);
        Equal(100L, encodedRawTimestamps[0]);
        Equal(300L, encodedRawTimestamps[1]);
        Equal(1, captureBackend.OpenCount);
        True(capture.IsDisposed);
        True(encoder.IsDisposed);
    }

    private static async Task VideoSessionUsesCapturePixelDimensions()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow(width: 800, height: 600);
        var resolver = new FakeVideoBindingResolver(CreateVideoBinding(identity, window));
        var capture = new ScriptedCaptureSession(
            window,
            (handler, cancellationToken) =>
                handler(CreateRawFrame(100), cancellationToken).AsTask(),
            initialWidth: 640,
            initialHeight: 480);
        var encoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(100, isKeyFrame: true, includeConfiguration: true)));
        var options = new HostVideoSessionOptions(
            new VideoEncodingSettings(VideoCodec.H264, 800, 600, 60, 4_000_000));
        await using var manager = new HostVideoSessionManager(
            resolver,
            new SequencedCaptureBackend(capture),
            new SequencedEncoderFactory(encoder),
            options);
        var stream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));

        await manager.RunAuthenticatedVideoSessionAsync(new PeelPskConnection(stream, identity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        IReadOnlyList<IPeelBinaryPacket> packets =
            new PeelBinaryPacketReader().Append(stream.WrittenBytes);
        Equal(2, packets.Count);
        var configuration = (VideoConfigPacket)packets[0];
        Equal(640U, configuration.Width);
        Equal(480U, configuration.Height);
        True(packets[1] is VideoFramePacket);
    }

    private static async Task VideoSessionReconfiguresAfterResize()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        var resolver = new FakeVideoBindingResolver(CreateVideoBinding(identity, window));
        var firstEncoded = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var resizedEncoded = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstEncoder = new ScriptedVideoEncoder((frame, _) =>
        {
            Equal(640, frame.Width);
            Equal(480, frame.Height);
            firstEncoded.TrySetResult();
            return ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(
                    frame.Timestamp100Nanoseconds,
                    isKeyFrame: true,
                    includeConfiguration: true));
        });
        var resizedEncoder = new ScriptedVideoEncoder((frame, _) =>
        {
            Equal(800, frame.Width);
            Equal(600, frame.Height);
            bool firstResizedFrame = frame.Timestamp100Nanoseconds == 200;
            if (firstResizedFrame)
            {
                resizedEncoded.TrySetResult();
            }

            return ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(
                    frame.Timestamp100Nanoseconds,
                    isKeyFrame: firstResizedFrame,
                    includeConfiguration: firstResizedFrame,
                    configurationWidth: 800,
                    configurationHeight: 600));
        });
        var capture = new ScriptedCaptureSession(window, async (handler, cancellationToken) =>
        {
            await handler(CreateRawFrame(100), cancellationToken).ConfigureAwait(false);
            await firstEncoded.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            await handler(
                    CreateRawFrame(200, width: 801, height: 601),
                    cancellationToken)
                .ConfigureAwait(false);
            await resizedEncoded.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            await handler(
                    CreateRawFrame(300, width: 801, height: 601),
                    cancellationToken)
                .ConfigureAwait(false);
        });
        var encoderFactory = new SequencedEncoderFactory(
            true,
            firstEncoder,
            resizedEncoder);
        var options = CreateVideoOptions();
        await using var manager = new HostVideoSessionManager(
            resolver,
            new SequencedCaptureBackend(capture),
            encoderFactory,
            options);
        var stream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));

        await manager.RunAuthenticatedVideoSessionAsync(new PeelPskConnection(stream, identity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);

        IReadOnlyList<IPeelBinaryPacket> packets =
            new PeelBinaryPacketReader(options.MaximumEncodedPacketBytes)
                .Append(stream.WrittenBytes);
        Equal(5, packets.Count);
        var firstConfiguration = (VideoConfigPacket)packets[0];
        Equal(640U, firstConfiguration.Width);
        Equal(480U, firstConfiguration.Height);
        True(((VideoFramePacket)packets[1]).IsKeyframe);
        var resizedConfiguration = (VideoConfigPacket)packets[2];
        Equal(800U, resizedConfiguration.Width);
        Equal(600U, resizedConfiguration.Height);
        True(((VideoFramePacket)packets[3]).IsKeyframe);
        Equal(300L, ((VideoFramePacket)packets[4]).PtsValue);
        Equal(2, encoderFactory.CreatedSettings.Count);
        Equal(640, encoderFactory.CreatedSettings[0].Width);
        Equal(480, encoderFactory.CreatedSettings[0].Height);
        Equal(800, encoderFactory.CreatedSettings[1].Width);
        Equal(600, encoderFactory.CreatedSettings[1].Height);
        True(firstEncoder.IsDisposed);
        True(resizedEncoder.IsDisposed);
    }

    private static async Task VideoHelloRejectsHostileIdentityAndFraming()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        var resolver = new FakeVideoBindingResolver(CreateVideoBinding(identity, window));
        var captureBackend = new SequencedCaptureBackend();
        var encoderFactory = new SequencedEncoderFactory();
        var options = new HostVideoSessionOptions(
            CreateVideoSettings(),
            maximumHelloLineBytes: 512,
            maximumEncodedPacketBytes: 1024,
            maximumParameterSetBytes: 128);
        await using var manager = new HostVideoSessionManager(
            resolver,
            captureBackend,
            encoderFactory,
            options);

        var incompatible = new VideoStreamHelloMessage(
            1,
            ProtocolVersion: 1,
            MinimumSupportedProtocolVersion: 1,
            PairingId: identity,
            Capabilities: VideoCapabilities());
        var missingCapability = PeelHello.CreateVideoStream(
            1,
            identity,
            [PeelCapability.H264Video]);
        var unknownWindow = PeelHello.CreateVideoStream(
            999,
            identity,
            VideoCapabilities());
        byte[] validWithTrailingByte =
            [.. CombineLines(CreateVideoHello(identity)), (byte)'x'];
        byte[][] hostileInputs =
        [
            CombineLines(PeelHello.CreateClient(identity, "Client", "Windows")),
            CombineLines(CreateVideoHello("different-identity")),
            CombineLines(incompatible),
            CombineLines(missingCapability),
            CombineLines(unknownWindow),
            validWithTrailingByte,
            System.Text.Encoding.UTF8.GetBytes(new string('x', 513) + "\n"),
            System.Text.Encoding.UTF8.GetBytes("{malformed}\n"),
        ];

        foreach (byte[] input in hostileInputs)
        {
            var stream = new ScriptedDuplexStream(input, maximumReadBytes: input.Length);
            await manager.RunAuthenticatedVideoSessionAsync(
                    new PeelPskConnection(stream, identity))
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            Equal(0, stream.WrittenBytes.Length);
        }

        Equal(0, captureBackend.OpenCount);
        Equal(0, encoderFactory.CreateCount);
    }

    private static async Task VideoWriterRejectsInvalidConfigAndFrames()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        var resolver = new FakeVideoBindingResolver(CreateVideoBinding(identity, window));
        var captures = new SequencedCaptureBackend(
            CreateSingleFrameCapture(window, 100),
            CreateSingleFrameCapture(window, 100),
            CreateSingleFrameCapture(window, 100),
            CreateSingleFrameCapture(window, 100));
        var encoders = new SequencedEncoderFactory(
            new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(100, isKeyFrame: true))),
            new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(100, isKeyFrame: false, includeConfiguration: true))),
            new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(
                    100,
                    isKeyFrame: true,
                    includeConfiguration: true,
                    payloadByteCount: 103))),
            new ScriptedVideoEncoder((_, _) => ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(
                    100,
                    isKeyFrame: true,
                    includeConfiguration: true,
                    configurationWidth:
                        CaptureFrameLayout.MaximumD3D11TextureDimension + 1))));
        var options = new HostVideoSessionOptions(
            CreateVideoSettings(),
            maximumHelloLineBytes: 1024,
            maximumEncodedPacketBytes: 128,
            maximumParameterSetBytes: 32);
        await using var manager = new HostVideoSessionManager(
            resolver,
            captures,
            encoders,
            options);

        for (var index = 0; index < 4; index++)
        {
            var stream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));
            await manager.RunAuthenticatedVideoSessionAsync(
                    new PeelPskConnection(stream, identity))
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            Equal(0, stream.WrittenBytes.Length);
        }

        Equal(4, captures.OpenCount);
        Equal(4, encoders.CreateCount);
    }

    private static async Task ReplacementVideoSessionSuppressesStaleOutput()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        var resolver = new FakeVideoBindingResolver(CreateVideoBinding(identity, window));
        var oldEncoderEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOldEncoder = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var oldEncoder = new ScriptedVideoEncoder(async (_, _) =>
        {
            oldEncoderEntered.TrySetResult();
            await releaseOldEncoder.Task.ConfigureAwait(false);
            return CreateEncodedFrame(100, isKeyFrame: true, includeConfiguration: true);
        });
        var newEncoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(200, isKeyFrame: true, includeConfiguration: true)));
        var captures = new SequencedCaptureBackend(
            CreateSingleFrameCapture(window, 100),
            CreateSingleFrameCapture(window, 200));
        var encoders = new SequencedEncoderFactory(oldEncoder, newEncoder);
        await using var manager = new HostVideoSessionManager(
            resolver,
            captures,
            encoders,
            CreateVideoOptions());
        var oldStream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));
        var newStream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));

        Task oldSession = manager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(oldStream, identity));
        await oldEncoderEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Task newSession = manager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(newStream, identity));
        await newSession.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        releaseOldEncoder.TrySetResult();
        await oldSession.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        Equal(0, oldStream.WrittenBytes.Length);
        IReadOnlyList<IPeelBinaryPacket> newPackets =
            new PeelBinaryPacketReader().Append(newStream.WrittenBytes);
        Equal(2, newPackets.Count);
        True(newPackets[0] is VideoConfigPacket);
        Equal(200L, ((VideoFramePacket)newPackets[1]).PtsValue);
        True(oldEncoder.IsDisposed);
        True(newEncoder.IsDisposed);
    }

    private static async Task VideoSessionFollowsControlLifetime()
    {
        const string identity = "paired-video-client";
        WindowDescriptor window = CreateVideoWindow();
        using var controlLifetime = new CancellationTokenSource();
        var resolver = new FakeVideoBindingResolver(
            CreateVideoBinding(identity, window, controlLifetime.Token));
        var captureEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var capture = new ScriptedCaptureSession(window, async (_, cancellationToken) =>
        {
            captureEntered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        });
        var encoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(null));
        await using var manager = new HostVideoSessionManager(
            resolver,
            new SequencedCaptureBackend(capture),
            new SequencedEncoderFactory(encoder),
            CreateVideoOptions());
        var stream = new ScriptedDuplexStream(CombineLines(CreateVideoHello(identity)));

        Task session = manager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(stream, identity));
        await captureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        controlLifetime.Cancel();
        await session.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        await manager.DisposeAsync();
        await manager.DisposeAsync();

        True(capture.IsDisposed);
        True(encoder.IsDisposed);
        Equal(0, stream.WrittenBytes.Length);
    }

    private static async Task SimultaneousVideoSessionsRemainIndependent()
    {
        const string identity = "paired-multi-window-client";
        WindowDescriptor firstWindow = CreateVideoWindow(
            handle: (nint)0x6101,
            processId: 61);
        WindowDescriptor secondWindow = CreateVideoWindow(
            handle: (nint)0x6201,
            processId: 62);
        var windowListSent = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var controlStream = new InteractiveDuplexStream(written =>
        {
            ReadOnlySpan<byte> line = written.Span;
            if (!line.IsEmpty && line[^1] == (byte)'\n' &&
                StringComparer.Ordinal.Equals(
                    PeelJson.ReadEnvelope(line[..^1]).Type,
                    PeelMessageType.WindowList))
            {
                windowListSent.TrySetResult();
            }
        });
        await using var controlManager = new HostControlSessionManager(
            new FakeWindowEnumerator([firstWindow, secondWindow]),
            new HostControlSessionOptions("Test Host", "Test OS", "1.0"));
        var firstCaptureEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var secondCaptureEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstCapture = new ScriptedCaptureSession(
            firstWindow,
            async (_, cancellationToken) =>
            {
                firstCaptureEntered.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            });
        var secondCapture = new ScriptedCaptureSession(
            secondWindow,
            async (_, cancellationToken) =>
            {
                secondCaptureEntered.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
            });
        var firstEncoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(null));
        var secondEncoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(null));
        await using var videoManager = new HostVideoSessionManager(
            controlManager,
            new SequencedCaptureBackend(firstCapture, secondCapture),
            new SequencedEncoderFactory(firstEncoder, secondEncoder),
            CreateVideoOptions());

        controlStream.EnqueueLines(
            PeelHello.CreateClient(
                identity,
                "Multi-window Client",
                "Windows",
                capabilities: VideoCapabilities()),
            new PeelRequest(PeelMessageType.RequestWindowList));
        Task controlTask = controlManager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(controlStream, identity));
        await windowListSent.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        var firstStream = new ScriptedDuplexStream(
            CombineLines(CreateVideoHello(identity, windowId: 1)));
        Task firstSession = videoManager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(firstStream, identity));
        await firstCaptureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Equal(1, videoManager.ActiveStreamCount);

        var secondStream = new ScriptedDuplexStream(
            CombineLines(CreateVideoHello(identity, windowId: 2)));
        Task secondSession = videoManager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(secondStream, identity));
        await secondCaptureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Equal(2, videoManager.ActiveStreamCount);

        controlStream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, WindowId: 1));
        await firstSession.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Equal(1, videoManager.ActiveStreamCount);
        True(!secondSession.IsCompleted);

        controlStream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, WindowId: 2));
        await secondSession.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        Equal(0, videoManager.ActiveStreamCount);
        True(firstCapture.IsDisposed);
        True(secondCapture.IsDisposed);
        True(firstEncoder.IsDisposed);
        True(secondEncoder.IsDisposed);

        controlStream.CompleteInput();
        await controlTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    private static async Task ControlStopCancelsVideoAndStartPermitsReconnect()
    {
        const string identity = "paired-control-video-client";
        WindowDescriptor window = CreateVideoWindow();
        var firstWindowList = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var secondWindowList = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var windowListCount = 0;
        var controlStream = new InteractiveDuplexStream(written =>
        {
            ReadOnlySpan<byte> line = written.Span;
            if (!line.IsEmpty && line[^1] == (byte)'\n' &&
                StringComparer.Ordinal.Equals(
                    PeelJson.ReadEnvelope(line[..^1]).Type,
                    PeelMessageType.WindowList))
            {
                int count = Interlocked.Increment(ref windowListCount);
                (count == 1 ? firstWindowList : secondWindowList).TrySetResult();
            }
        });
        var controlOptions = new HostControlSessionOptions("Test Host", "Test OS", "1.0");
        await using var controlManager = new HostControlSessionManager(
            new FakeWindowEnumerator([window]),
            controlOptions);
        var captureEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var stoppedCapture = new ScriptedCaptureSession(window, async (_, cancellationToken) =>
        {
            captureEntered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        });
        var resumedCapture = CreateSingleFrameCapture(window, 200);
        var stoppedEncoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(null));
        var resumedEncoder = new ScriptedVideoEncoder((_, _) =>
            ValueTask.FromResult<EncodedVideoFrame?>(
                CreateEncodedFrame(200, isKeyFrame: true, includeConfiguration: true)));
        await using var videoManager = new HostVideoSessionManager(
            controlManager,
            new SequencedCaptureBackend(stoppedCapture, resumedCapture),
            new SequencedEncoderFactory(stoppedEncoder, resumedEncoder),
            CreateVideoOptions());

        controlStream.EnqueueLines(
            PeelHello.CreateClient(
                identity,
                "Control Video Client",
                "Windows",
                capabilities: VideoCapabilities()),
            new PeelRequest(PeelMessageType.RequestWindowList));
        Task controlTask = controlManager.RunAuthenticatedSessionAsync(
            new PeelPskConnection(controlStream, identity));
        await firstWindowList.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        var firstVideoStream = new ScriptedDuplexStream(
            CombineLines(CreateVideoHello(identity)));
        Task firstVideoTask = videoManager.RunAuthenticatedVideoSessionAsync(
            new PeelPskConnection(firstVideoStream, identity));
        await captureEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);

        controlStream.EnqueueLines(new PeelRequest(PeelMessageType.StopStream, WindowId: 1));
        await firstVideoTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(!((IHostVideoBindingResolver)controlManager).TryResolveVideoBinding(
            identity,
            1,
            out _));
        Equal(0, firstVideoStream.WrittenBytes.Length);
        True(stoppedCapture.IsDisposed);
        True(stoppedEncoder.IsDisposed);

        controlStream.EnqueueLines(
            new PeelRequest(PeelMessageType.StartStream, WindowId: 1),
            new PeelRequest(PeelMessageType.RequestWindowList));
        await secondWindowList.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        True(((IHostVideoBindingResolver)controlManager).TryResolveVideoBinding(
            identity,
            1,
            out _));

        var resumedVideoStream = new ScriptedDuplexStream(
            CombineLines(CreateVideoHello(identity)));
        await videoManager.RunAuthenticatedVideoSessionAsync(
                new PeelPskConnection(resumedVideoStream, identity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        IReadOnlyList<IPeelBinaryPacket> resumedPackets =
            new PeelBinaryPacketReader().Append(resumedVideoStream.WrittenBytes);
        Equal(2, resumedPackets.Count);
        True(resumedPackets[0] is VideoConfigPacket);
        Equal(200L, ((VideoFramePacket)resumedPackets[1]).PtsValue);

        controlStream.CompleteInput();
        await controlTask.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    }

    private static void WindowIdsBindHandleAndProcessIdentity()
    {
        var map = new HostWindowIdMap();
        WindowDescriptor firstIdentity = CreateVideoWindow(handle: (nint)0x1234, processId: 10);
        WindowDescriptor recycledHandle = CreateVideoWindow(handle: (nint)0x1234, processId: 11);

        IReadOnlyList<PeelWindow> firstSnapshot = map.CreateSnapshot([firstIdentity]);
        IReadOnlyList<PeelWindow> secondSnapshot = map.CreateSnapshot([recycledHandle]);

        Equal<uint>(1, firstSnapshot[0].WindowId);
        Equal<uint>(2, secondSnapshot[0].WindowId);
        True(!map.TryResolve(1, out _));
        True(map.TryResolve(2, out WindowDescriptor? resolved));
        Equal(recycledHandle, resolved);
        True(!map.IsCurrent(2, firstIdentity));
        True(map.IsCurrent(2, recycledHandle));
    }

    private static void DisplayDescriptorsMatchMacContract()
    {
        IReadOnlyList<WindowDescriptor> displays = WindowsDisplayCaptureSource.CreateDescriptors(
        [
            new WindowsDisplayCaptureSource.MonitorSnapshot(
                (nint)0x2000,
                new WindowBounds(-1920, 0, 1920, 1080),
                IsPrimary: false),
            new WindowsDisplayCaptureSource.MonitorSnapshot(
                (nint)0x1000,
                new WindowBounds(0, 0, 2560, 1440),
                IsPrimary: true),
        ]);

        Equal(2, displays.Count);
        True(displays[0].IsDisplay);
        Equal((nint)0x1000, displays[0].Handle);
        Equal<uint>(0, displays[0].ProcessId);
        Equal("Peel Display", displays[0].ProcessName);
        Equal("Peel Display Main", displays[0].Title);
        Equal<uint?>(WindowsDisplayCaptureSource.SyntheticBase, displays[0].FixedWindowId);
        Equal(new WindowBounds(0, 0, 2560, 1440), displays[0].Bounds);
        True(displays[0].StatusSummary?.Contains(
            "full display stream",
            StringComparison.Ordinal) == true);

        Equal((nint)0x2000, displays[1].Handle);
        Equal("Peel Display 2", displays[1].Title);
        Equal<uint?>(WindowsDisplayCaptureSource.SyntheticBase + 1, displays[1].FixedWindowId);

        IReadOnlyList<WindowDescriptor> single = WindowsDisplayCaptureSource.CreateDescriptors(
        [
            new WindowsDisplayCaptureSource.MonitorSnapshot(
                (nint)0x3000,
                new WindowBounds(0, 0, 1920, 1080),
                IsPrimary: true),
        ]);
        Equal("Peel Display", single.Single().Title);
    }

    private static void DisplayIdsRemainReservedBesideSessionWindowIds()
    {
        var map = new HostWindowIdMap();
        WindowDescriptor window = CreateVideoWindow();
        WindowDescriptor display = WindowsDisplayCaptureSource.CreateDescriptors(
        [
            new WindowsDisplayCaptureSource.MonitorSnapshot(
                (nint)0x3000,
                new WindowBounds(0, 0, 1920, 1080),
                IsPrimary: true),
        ]).Single();

        IReadOnlyList<PeelWindow> snapshot = map.CreateSnapshot([window, display]);

        Equal(2, snapshot.Count);
        Equal<uint>(1, snapshot[0].WindowId);
        Equal<uint>(WindowsDisplayCaptureSource.SyntheticBase, snapshot[1].WindowId);
        Equal("Peel Display", snapshot[1].AppName);
        Equal("Peel Display", snapshot[1].Title);
        True(map.TryResolve(
            WindowsDisplayCaptureSource.SyntheticBase,
            out WindowDescriptor? resolvedDisplay));
        Equal(display, resolvedDisplay);
        True(map.IsCurrent(WindowsDisplayCaptureSource.SyntheticBase, display));

        WindowDescriptor invalidDisplay = display with
        {
            Handle = (nint)0x4000,
            FixedWindowId = 42,
        };
        IReadOnlyList<PeelWindow> withoutInvalid = map.CreateSnapshot([window, invalidDisplay]);
        Equal(1, withoutInvalid.Count);
        True(!map.TryResolve(WindowsDisplayCaptureSource.SyntheticBase, out _));
    }

    private static async Task WindowIdsRemainStableAcrossControlReconnect()
    {
        const string identity = "stable-window-id-client";
        var enumerator = new FakeWindowEnumerator([CreateVideoWindow()]);
        await using var manager = new HostControlSessionManager(
            enumerator,
            new HostControlSessionOptions("Test Host"));

        async Task<uint> ReadWindowIdAsync()
        {
            var stream = new ScriptedDuplexStream(CombineLines(
                PeelHello.CreateClient(identity, "Test Client", "iPadOS"),
                new PeelRequest(PeelMessageType.RequestWindowList)));
            await manager.RunAuthenticatedSessionAsync(new PeelPskConnection(stream, identity))
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            IReadOnlyList<byte[]> lines = ReadOutputLines(stream);
            Equal(2, lines.Count);
            return PeelJson.Deserialize<WindowListMessage>(lines[1]).Windows.Single().WindowId;
        }

        uint firstWindowId = await ReadWindowIdAsync().ConfigureAwait(false);
        uint secondWindowId = await ReadWindowIdAsync().ConfigureAwait(false);

        Equal(firstWindowId, secondWindowId);
    }

    private static HostVideoSessionOptions CreateVideoOptions() =>
        new(CreateVideoSettings(), maximumEncodedPacketBytes: 1024 * 1024);

    private static VideoEncodingSettings CreateVideoSettings() =>
        new(VideoCodec.H264, 640, 480, 60, 4_000_000);

    private static IReadOnlyList<string> VideoCapabilities() =>
    [
        PeelCapability.H264Video,
        PeelCapability.PerWindowVideoConnections,
        PeelCapability.BinaryVideoTransportV2,
    ];

    private static IReadOnlyList<string> HostCapabilities() =>
    [
        .. VideoCapabilities(),
        PeelCapability.ClientVisibility,
        PeelCapability.ExpandedKeyboard,
        PeelCapability.InputFocus,
    ];

    private static VideoStreamHelloMessage CreateVideoHello(
        string pairingIdentity,
        uint windowId = 1) =>
        PeelHello.CreateVideoStream(windowId, pairingIdentity, VideoCapabilities());

    private static HostVideoBinding CreateVideoBinding(
        string identity,
        WindowDescriptor window,
        CancellationToken controlLifetime = default) =>
        new(
            7,
            identity,
            1,
            window,
            new HashSet<string>([PeelCapability.ClientVisibility], StringComparer.Ordinal),
            controlLifetime);

    private static WindowDescriptor CreateVideoWindow(
        nint? handle = null,
        uint processId = 42,
        int width = 640,
        int height = 480) =>
        new(
            handle ?? (nint)0x5678,
            processId,
            "Test",
            "TestWindow",
            "Video Test",
            new WindowBounds(10, 20, width, height));

    private static CapturedFrame CreateRawFrame(
        long timestamp,
        int width = 640,
        int height = 480) =>
        new(
            width,
            height,
            checked(width * CaptureFrameLayout.BytesPerPixel),
            timestamp,
            CapturePixelFormat.Bgra8,
            new byte[16]);

    private static EncodedVideoFrame CreateEncodedFrame(
        long timestamp,
        bool isKeyFrame,
        bool includeConfiguration = false,
        int payloadByteCount = 3,
        int configurationWidth = 640,
        int configurationHeight = 480) =>
        new(
            VideoCodec.H264,
            timestamp,
            isKeyFrame,
            new byte[payloadByteCount],
            Duration100Nanoseconds: includeConfiguration ? 0 : 166_667,
            Configuration: includeConfiguration
                ? new VideoEncoderConfiguration(
                    VideoCodec.H264,
                    configurationWidth,
                    configurationHeight,
                    10_000_000,
                    4,
                    new byte[] { 0x67, 0x42 },
                    new byte[] { 0x68 })
                : null);

    private static ScriptedCaptureSession CreateSingleFrameCapture(
        WindowDescriptor window,
        long timestamp) =>
        new(window, (handler, cancellationToken) =>
            handler(CreateRawFrame(timestamp), cancellationToken).AsTask());

    private static async Task<ScriptedDuplexStream> RunCompletedSessionAsync(
        byte[] input,
        string peerIdentity,
        IWindowEnumerator windowEnumerator,
        HostControlSessionOptions? options = null,
        IHostInputSessionFactory? inputSessionFactory = null)
    {
        var stream = new ScriptedDuplexStream(input, maximumReadBytes: 7);
        HostControlSessionOptions resolvedOptions =
            options ?? new HostControlSessionOptions("Test Host", "Test OS", "1.0");
        await using HostControlSessionManager manager = inputSessionFactory is null
            ? new HostControlSessionManager(windowEnumerator, resolvedOptions)
            : new HostControlSessionManager(
                windowEnumerator,
                inputSessionFactory,
                resolvedOptions);

        await manager.RunAuthenticatedSessionAsync(new PeelPskConnection(stream, peerIdentity))
            .WaitAsync(TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        return stream;
    }

    private static byte[] CombineLines(params object[] messages)
    {
        using var output = new MemoryStream();
        foreach (object message in messages)
        {
            output.Write(PeelJson.SerializeLine(message));
        }

        return output.ToArray();
    }

    private static HostPairingPin CreateTestPairingPin(DateTimeOffset expiresAt) =>
        new(
            "123456",
            Enumerable.Range(0, PeelPinPairing.GeneratedSaltBytes)
                .Select(static value => checked((byte)value))
                .ToArray(),
            expiresAt);

    private static async Task<PairResponseMessage> SendPairingRequestAsync(
        IPeelPskTransportFactory transport,
        IPEndPoint endpoint,
        PeelPskCredential credential,
        PairRequestMessage request,
        CancellationToken cancellationToken)
    {
        await using Stream stream = await transport.ConnectAsync(
                new DnsEndPoint(endpoint.Address.ToString(), endpoint.Port),
                credential,
                cancellationToken)
            .ConfigureAwait(false);
        byte[] requestBytes = PeelJson.Serialize(request);
        int split = Math.Min(7, requestBytes.Length);
        await stream.WriteAsync(requestBytes.AsMemory(0, split), cancellationToken)
            .ConfigureAwait(false);
        await stream.WriteAsync(requestBytes.AsMemory(split), cancellationToken)
            .ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        byte[] response = await ReadAllBytesAsync(stream, cancellationToken)
            .ConfigureAwait(false);
        return PeelJson.Deserialize<PairResponseMessage>(response);
    }

    private static async Task SendHostilePairingDocumentAsync(
        IPeelPskTransportFactory transport,
        IPEndPoint endpoint,
        PeelPskCredential credential,
        byte[] document,
        CancellationToken cancellationToken)
    {
        await using Stream stream = await transport.ConnectAsync(
                new DnsEndPoint(endpoint.Address.ToString(), endpoint.Port),
                credential,
                cancellationToken)
            .ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(document, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            byte[] response = await ReadAllBytesAsync(stream, cancellationToken)
                .ConfigureAwait(false);
            Equal(0, response.Length);
        }
        catch (IOException)
        {
            // A bounded hostile document may race the server's immediate TLS close.
        }
    }

    private static async Task<byte[]> ReadAllBytesAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        await stream.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
        return output.ToArray();
    }

    private static IReadOnlyList<byte[]> ReadOutputLines(ScriptedDuplexStream stream)
        => ReadOutputLines(stream.WrittenBytes);

    private static IReadOnlyList<byte[]> ReadOutputLines(byte[] output)
    {
        var lines = new List<byte[]>();
        int start = 0;

        for (var index = 0; index < output.Length; index++)
        {
            if (output[index] != (byte)'\n')
            {
                continue;
            }

            if (index > start)
            {
                lines.Add(output[start..index]);
            }

            start = index + 1;
        }

        Equal(output.Length, start);
        return lines;
    }

    private static Func<Task> Sync(Action action) => () =>
    {
        action();
        return Task.CompletedTask;
    };

    private static void True(bool condition)
    {
        if (!condition)
        {
            throw new InvalidOperationException("Expected condition to be true.");
        }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
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

    private sealed class DisposableCaptureToken(int id) : IDisposable
    {
        private int disposed;

        internal int Id { get; } = id;
        internal bool IsDisposed => Volatile.Read(ref disposed) != 0;

        public void Dispose() => Interlocked.Exchange(ref disposed, 1);
    }

    private readonly record struct NativeInputSnapshot(
        int MouseMoveCount,
        int LeftDownCount,
        int LeftUpCount,
        int RightDownCount,
        int RightUpCount,
        int WheelCount,
        int KeyDownCount,
        int KeyUpCount,
        int CharacterCount,
        ushort LastVirtualKey,
        char LastCharacter);

    private sealed record ElevatedInputTargetState(
        long Handle,
        uint ProcessId,
        string ClassName,
        string Title,
        bool IsAdministrator);

    private sealed record ElevatedInputTargetResult(NativeInputSnapshot Input);

    private readonly record struct ProcessResourceSnapshot(
        long PrivateBytes,
        long WorkingSetBytes,
        long ManagedBytes,
        int HandleCount);

    private readonly record struct SustainedVideoObservation(
        TimeSpan Duration,
        int ConfigurationCount,
        int FrameCount,
        long PayloadBytes,
        ProcessResourceSnapshot BaselineResources,
        ProcessResourceSnapshot FinalResources,
        long PeakPrivateBytes,
        long PeakWorkingSetBytes,
        long PeakManagedBytes,
        int PeakHandleCount);

    private sealed class NativeCaptureSmokeWindow : IDisposable
    {
        private const uint WindowStyle = 0x10CF0000;
        private const uint WindowMessageClose = 0x0010;
        private const uint WindowMessageDestroy = 0x0002;
        private const uint WindowMessageKeyDown = 0x0100;
        private const uint WindowMessageKeyUp = 0x0101;
        private const uint WindowMessageCharacter = 0x0102;
        private const uint WindowMessageMouseMove = 0x0200;
        private const uint WindowMessageLeftButtonDown = 0x0201;
        private const uint WindowMessageLeftButtonUp = 0x0202;
        private const uint WindowMessageRightButtonDown = 0x0204;
        private const uint WindowMessageRightButtonUp = 0x0205;
        private const uint WindowMessageMouseWheel = 0x020A;
        private const int ShowWindowNormal = 5;
        private const int ShowWindowMinimized = 6;
        private const int ShowWindowRestore = 9;
        private const uint SetWindowPositionNoZOrder = 0x0004;
        private const uint SetWindowPositionNoActivate = 0x0010;

        private readonly object stateLock = new();
        private readonly string title;
        private readonly string className = $"PeelCaptureSmoke.{Guid.NewGuid():N}";
        private readonly NativeMethods.WindowProcedure windowProcedure;
        private readonly Thread messageThread;
        private readonly TaskCompletionSource<WindowDescriptor> window = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private nint windowHandle;
        private int mouseMoveCount;
        private int leftDownCount;
        private int leftUpCount;
        private int rightDownCount;
        private int rightUpCount;
        private int wheelCount;
        private int keyDownCount;
        private int keyUpCount;
        private int characterCount;
        private ushort lastVirtualKey;
        private char lastCharacter;
        private bool disposed;

        internal NativeCaptureSmokeWindow(string title = "Peel Capture Smoke")
        {
            if (string.IsNullOrWhiteSpace(title) || title.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("A visible native smoke-window title is required.", nameof(title));
            }

            this.title = title;
            windowProcedure = HandleWindowMessage;
            messageThread = new Thread(RunMessageLoop)
            {
                IsBackground = true,
                Name = "Peel native capture smoke window",
            };
            messageThread.SetApartmentState(ApartmentState.STA);
            messageThread.Start();
        }

        internal Task<WindowDescriptor> Window => window.Task;

        internal NativeInputSnapshot InputSnapshot => ReadInputSnapshot();

        internal async Task<NativeInputSnapshot> WaitForInputAsync(
            Func<NativeInputSnapshot, bool> predicate,
            TimeSpan timeout)
        {
            ArgumentNullException.ThrowIfNull(predicate);
            using var timeoutCancellation = new CancellationTokenSource(timeout);
            while (true)
            {
                NativeInputSnapshot snapshot = ReadInputSnapshot();
                if (predicate(snapshot))
                {
                    return snapshot;
                }

                try
                {
                    await Task.Delay(20, timeoutCancellation.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (timeoutCancellation.IsCancellationRequested)
                {
                    throw new TimeoutException(
                        "The controlled native window did not receive the expected input. " +
                        $"Last snapshot: {snapshot}.");
                }
            }
        }

        internal void SetFrameMarker(int frameMarker)
        {
            nint handle;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                handle = windowHandle;
            }

            if (handle == 0 ||
                !NativeMethods.SetWindowTextW(handle, $"{title} {frameMarker:D4}"))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            }
        }

        internal void Resize(int width, int height)
        {
            if (width is < 100 or > 2_000 || height is < 100 or > 2_000)
            {
                throw new ArgumentOutOfRangeException(nameof(width));
            }

            nint handle;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                handle = windowHandle;
            }

            if (handle == 0 || !NativeMethods.SetWindowPos(
                    handle,
                    0,
                    100,
                    100,
                    width,
                    height,
                    SetWindowPositionNoZOrder | SetWindowPositionNoActivate))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            }
        }

        internal void SetMinimized(bool minimized)
        {
            nint handle;
            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                handle = windowHandle;
            }

            if (handle == 0)
            {
                throw new InvalidOperationException("The controlled native window is unavailable.");
            }

            _ = NativeMethods.ShowWindowAsync(
                handle,
                minimized ? ShowWindowMinimized : ShowWindowRestore);
        }

        internal string ReadPointerDiagnostic(WindowBounds physicalWindowBounds)
        {
            if (!NativeMethods.GetCursorPos(out NativeMethods.NativePoint point))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError());
            }

            nint hitWindow = NativeMethods.WindowFromPoint(point);
            return FormattableString.Invariant(
                $"Cursor=({point.X},{point.Y}), hit=0x{hitWindow:X}, target=0x{windowHandle:X}, DWM bounds={physicalWindowBounds}, virtualDesktop=({NativeMethods.GetSystemMetrics(76)},{NativeMethods.GetSystemMetrics(77)},{NativeMethods.GetSystemMetrics(78)},{NativeMethods.GetSystemMetrics(79)}).");
        }

        public void Dispose()
        {
            nint handle;
            lock (stateLock)
            {
                if (disposed)
                {
                    return;
                }

                disposed = true;
                handle = windowHandle;
            }

            if (handle != 0)
            {
                _ = NativeMethods.PostMessageW(handle, WindowMessageClose, 0, 0);
            }

            if (!messageThread.Join(TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException("The native capture smoke window did not close.");
            }
        }

        private void RunMessageLoop()
        {
            nint instance = NativeMethods.GetModuleHandleW(null);
            nint backgroundBrush = NativeMethods.CreateSolidBrush(0x00E8_7A_22);
            ushort registeredClass = 0;

            try
            {
                var windowClass = new NativeMethods.WindowClassEx
                {
                    Size = (uint)Marshal.SizeOf<NativeMethods.WindowClassEx>(),
                    WindowProcedure = windowProcedure,
                    Instance = instance,
                    Background = backgroundBrush,
                    ClassName = className,
                };
                registeredClass = NativeMethods.RegisterClassExW(ref windowClass);
                if (registeredClass == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError());
                }

                nint handle = NativeMethods.CreateWindowExW(
                    0,
                    className,
                    title,
                    WindowStyle,
                    100,
                    100,
                    360,
                    280,
                    0,
                    0,
                    instance,
                    0);
                if (handle == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError());
                }

                lock (stateLock)
                {
                    windowHandle = handle;
                }

                _ = NativeMethods.ShowWindow(handle, ShowWindowNormal);
                if (!NativeMethods.UpdateWindow(handle) ||
                    !NativeMethods.GetWindowRect(handle, out NativeMethods.Rectangle bounds))
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError());
                }

                window.TrySetResult(new WindowDescriptor(
                    handle,
                    (uint)Environment.ProcessId,
                    "Peel.Windows.Host.Tests",
                    className,
                    title,
                    new WindowBounds(
                        bounds.Left,
                        bounds.Top,
                        bounds.Right - bounds.Left,
                        bounds.Bottom - bounds.Top)));

                int messageResult;
                while ((messageResult = NativeMethods.GetMessageW(
                    out NativeMethods.NativeMessage message,
                    0,
                    0,
                    0)) > 0)
                {
                    _ = NativeMethods.TranslateMessage(ref message);
                    _ = NativeMethods.DispatchMessageW(ref message);
                }

                if (messageResult < 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError());
                }
            }
            catch (Exception exception)
            {
                window.TrySetException(exception);
            }
            finally
            {
                lock (stateLock)
                {
                    windowHandle = 0;
                }

                if (registeredClass != 0)
                {
                    _ = NativeMethods.UnregisterClassW(className, instance);
                }

                if (backgroundBrush != 0)
                {
                    _ = NativeMethods.DeleteObject(backgroundBrush);
                }
            }
        }

        private nint HandleWindowMessage(
            nint handle,
            uint message,
            nuint wordParameter,
            nint longParameter)
        {
            if (message == WindowMessageDestroy)
            {
                NativeMethods.PostQuitMessage(0);
                return 0;
            }

            lock (stateLock)
            {
                switch (message)
                {
                    case WindowMessageMouseMove:
                        mouseMoveCount++;
                        break;
                    case WindowMessageLeftButtonDown:
                        leftDownCount++;
                        break;
                    case WindowMessageLeftButtonUp:
                        leftUpCount++;
                        break;
                    case WindowMessageRightButtonDown:
                        rightDownCount++;
                        break;
                    case WindowMessageRightButtonUp:
                        rightUpCount++;
                        break;
                    case WindowMessageMouseWheel:
                        wheelCount++;
                        break;
                    case WindowMessageKeyDown:
                        keyDownCount++;
                        lastVirtualKey = unchecked((ushort)wordParameter);
                        break;
                    case WindowMessageKeyUp:
                        keyUpCount++;
                        lastVirtualKey = unchecked((ushort)wordParameter);
                        break;
                    case WindowMessageCharacter:
                        characterCount++;
                        lastCharacter = unchecked((char)wordParameter);
                        break;
                }
            }

            return NativeMethods.DefWindowProcW(
                handle,
                message,
                wordParameter,
                longParameter);
        }

        private NativeInputSnapshot ReadInputSnapshot()
        {
            lock (stateLock)
            {
                return new NativeInputSnapshot(
                    mouseMoveCount,
                    leftDownCount,
                    leftUpCount,
                    rightDownCount,
                    rightUpCount,
                    wheelCount,
                    keyDownCount,
                    keyUpCount,
                    characterCount,
                    lastVirtualKey,
                    lastCharacter);
            }
        }

        private static class NativeMethods
        {
            internal delegate nint WindowProcedure(
                nint window,
                uint message,
                nuint wordParameter,
                nint longParameter);

            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
            internal struct WindowClassEx
            {
                internal uint Size;
                internal uint Style;
                [MarshalAs(UnmanagedType.FunctionPtr)]
                internal WindowProcedure? WindowProcedure;
                internal int ClassExtraBytes;
                internal int WindowExtraBytes;
                internal nint Instance;
                internal nint Icon;
                internal nint Cursor;
                internal nint Background;
                [MarshalAs(UnmanagedType.LPWStr)]
                internal string? MenuName;
                [MarshalAs(UnmanagedType.LPWStr)]
                internal string? ClassName;
                internal nint SmallIcon;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct Rectangle
            {
                internal int Left;
                internal int Top;
                internal int Right;
                internal int Bottom;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct NativePoint
            {
                internal int X;
                internal int Y;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct NativeMessage
            {
                internal nint Window;
                internal uint Message;
                internal nuint WordParameter;
                internal nint LongParameter;
                internal uint Time;
                internal int PointX;
                internal int PointY;
                internal uint Private;
            }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
            internal static extern nint GetModuleHandleW(string? moduleName);

            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            internal static extern ushort RegisterClassExW(ref WindowClassEx windowClass);

            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            internal static extern nint CreateWindowExW(
                uint extendedStyle,
                string className,
                string windowName,
                uint style,
                int x,
                int y,
                int width,
                int height,
                nint parent,
                nint menu,
                nint instance,
                nint parameter);

            [DllImport("user32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool ShowWindow(nint window, int command);

            [DllImport("user32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool ShowWindowAsync(nint window, int command);

            [DllImport("user32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool SetWindowPos(
                nint window,
                nint insertAfter,
                int x,
                int y,
                int width,
                int height,
                uint flags);

            [DllImport("user32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool UpdateWindow(nint window);

            [DllImport("user32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool GetWindowRect(nint window, out Rectangle rectangle);

            [DllImport("user32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool GetCursorPos(out NativePoint point);

            [DllImport("user32.dll")]
            internal static extern nint WindowFromPoint(NativePoint point);

            [DllImport("user32.dll")]
            internal static extern int GetSystemMetrics(int index);

            [DllImport("user32.dll", SetLastError = true)]
            internal static extern int GetMessageW(
                out NativeMessage message,
                nint window,
                uint minimumMessage,
                uint maximumMessage);

            [DllImport("user32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool TranslateMessage(ref NativeMessage message);

            [DllImport("user32.dll")]
            internal static extern nint DispatchMessageW(ref NativeMessage message);

            [DllImport("user32.dll")]
            internal static extern nint DefWindowProcW(
                nint window,
                uint message,
                nuint wordParameter,
                nint longParameter);

            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool SetWindowTextW(nint window, string text);

            [DllImport("user32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool PostMessageW(
                nint window,
                uint message,
                nuint wordParameter,
                nint longParameter);

            [DllImport("user32.dll")]
            internal static extern void PostQuitMessage(int exitCode);

            [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool UnregisterClassW(string className, nint instance);

            [DllImport("gdi32.dll")]
            internal static extern nint CreateSolidBrush(uint color);

            [DllImport("gdi32.dll")]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool DeleteObject(nint graphicsObject);
        }
    }

    private sealed class StaticPskCredentialResolver(PeelPskCredential credential) :
        IPeelPskCredentialResolver
    {
        public bool TryResolve(string identity, out PeelPskCredential? resolved)
        {
            if (!StringComparer.Ordinal.Equals(identity, credential.Identity))
            {
                resolved = null;
                return false;
            }

            resolved = credential;
            return true;
        }
    }

    private sealed class RecordingCredentialVault : ICurrentUserCredentialVault, IDisposable
    {
        private readonly Dictionary<string, byte[]> secrets =
            new(StringComparer.OrdinalIgnoreCase);

        internal int Count => secrets.Count;
        internal int ReadCount { get; private set; }

        public void Write(string targetName, ReadOnlySpan<byte> secret)
        {
            if (secrets.Remove(targetName, out byte[]? existing))
            {
                CryptographicOperations.ZeroMemory(existing);
            }

            secrets[targetName] = secret.ToArray();
        }

        public bool TryRead(string targetName, out byte[]? secret)
        {
            ReadCount++;
            if (secrets.TryGetValue(targetName, out byte[]? stored))
            {
                secret = stored.ToArray();
                return true;
            }

            secret = null;
            return false;
        }

        public bool Delete(string targetName)
        {
            if (!secrets.Remove(targetName, out byte[]? secret))
            {
                return false;
            }

            CryptographicOperations.ZeroMemory(secret);
            return true;
        }

        public void Dispose()
        {
            foreach (byte[] secret in secrets.Values)
            {
                CryptographicOperations.ZeroMemory(secret);
            }

            secrets.Clear();
        }
    }

    private sealed class RecordingServiceRegistrar : IPeelServiceRegistrar
    {
        private readonly object stateLock = new();
        private readonly List<PeelServiceAdvertisement> active = [];

        internal IReadOnlyList<PeelServiceAdvertisement> Active
        {
            get
            {
                lock (stateLock)
                {
                    return active.ToArray();
                }
            }
        }

        internal int DisposeCount { get; private set; }

        public ValueTask<IAsyncDisposable> RegisterAsync(
            PeelServiceAdvertisement advertisement,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (stateLock)
            {
                active.Add(advertisement);
            }

            return ValueTask.FromResult<IAsyncDisposable>(
                new Registration(this, advertisement));
        }

        private void Remove(PeelServiceAdvertisement advertisement)
        {
            lock (stateLock)
            {
                if (active.Remove(advertisement))
                {
                    DisposeCount++;
                }
            }
        }

        private sealed class Registration(
            RecordingServiceRegistrar owner,
            PeelServiceAdvertisement advertisement) : IAsyncDisposable
        {
            private int disposed;

            public ValueTask DisposeAsync()
            {
                if (Interlocked.Exchange(ref disposed, 1) == 0)
                {
                    owner.Remove(advertisement);
                }

                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class RecordingPairedClientMetadataRepository :
        IHostPairedClientMetadataRepository
    {
        internal IReadOnlyList<HostPairedClient> Current { get; private set; } = [];

        public IReadOnlyList<HostPairedClient> Load() => Current.ToArray();

        public void Save(IReadOnlyList<HostPairedClient> pairedClients) =>
            Current = pairedClients.ToArray();
    }

    private sealed class ThrowingPairedClientMetadataRepository :
        IHostPairedClientMetadataRepository
    {
        public IReadOnlyList<HostPairedClient> Load() =>
            throw new JsonException("malformed paired-client metadata");

        public void Save(IReadOnlyList<HostPairedClient> pairedClients) =>
            throw new InvalidOperationException("The throwing repository cannot save.");
    }

    private sealed class FakeVideoBindingResolver(HostVideoBinding binding)
        : IHostVideoBindingResolver
    {
        internal bool IsCurrent { get; set; } = true;

        public bool TryResolveVideoBinding(
            string peerIdentity,
            uint windowId,
            out HostVideoBinding? resolvedBinding)
        {
            if (IsCurrent &&
                StringComparer.Ordinal.Equals(peerIdentity, binding.PeerIdentity) &&
                windowId == binding.WindowId)
            {
                resolvedBinding = binding;
                return true;
            }

            resolvedBinding = null;
            return false;
        }

        public bool IsCurrentVideoBinding(HostVideoBinding candidate) =>
            IsCurrent &&
            candidate.ControlGeneration == binding.ControlGeneration &&
            candidate.WindowId == binding.WindowId &&
            candidate.Window.Handle == binding.Window.Handle &&
            candidate.Window.ProcessId == binding.Window.ProcessId;
    }

    private sealed class SequencedCaptureBackend(params ScriptedCaptureSession[] sessions)
        : IWindowCaptureBackend
    {
        private readonly object stateLock = new();
        private readonly Queue<ScriptedCaptureSession> remaining = new(sessions);

        internal int OpenCount { get; private set; }

        public ValueTask<IWindowCaptureSession> OpenAsync(
            WindowDescriptor window,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (stateLock)
            {
                OpenCount++;
                if (remaining.Count == 0)
                {
                    throw new InvalidOperationException("No scripted capture session remains.");
                }

                ScriptedCaptureSession session = remaining.Dequeue();
                Equal(session.Window, window);
                return ValueTask.FromResult<IWindowCaptureSession>(session);
            }
        }
    }

    private sealed class ScriptedCaptureSession(
        WindowDescriptor window,
        Func<CapturedFrameHandler, CancellationToken, Task> run,
        int? initialWidth = null,
        int? initialHeight = null)
        : IWindowCaptureSession
    {
        private int disposed;

        public WindowDescriptor Window { get; } = window;
        public int InitialWidth { get; } = initialWidth ?? window.Bounds.Width;
        public int InitialHeight { get; } = initialHeight ?? window.Bounds.Height;
        internal bool IsDisposed => Volatile.Read(ref disposed) != 0;

        public Task RunAsync(
            CapturedFrameHandler frameHandler,
            CancellationToken cancellationToken) =>
            run(frameHandler, cancellationToken);

        public ValueTask DisposeAsync()
        {
            Interlocked.Exchange(ref disposed, 1);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class SequencedEncoderFactory : IVideoEncoderFactory
    {
        private readonly object stateLock = new();
        private readonly Queue<ScriptedVideoEncoder> remaining;
        private readonly bool allowVariableSettings;

        internal SequencedEncoderFactory(params ScriptedVideoEncoder[] encoders)
            : this(allowVariableSettings: false, encoders)
        {
        }

        internal SequencedEncoderFactory(
            bool allowVariableSettings,
            params ScriptedVideoEncoder[] encoders)
        {
            this.allowVariableSettings = allowVariableSettings;
            remaining = new Queue<ScriptedVideoEncoder>(encoders);
        }

        internal int CreateCount { get; private set; }

        internal List<VideoEncodingSettings> CreatedSettings { get; } = [];

        public ValueTask<IVideoEncoder> CreateAsync(
            VideoEncodingSettings settings,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!allowVariableSettings)
            {
                Equal(CreateVideoSettings(), settings);
            }

            lock (stateLock)
            {
                CreateCount++;
                CreatedSettings.Add(settings);
                if (remaining.Count == 0)
                {
                    throw new InvalidOperationException("No scripted video encoder remains.");
                }

                return ValueTask.FromResult<IVideoEncoder>(remaining.Dequeue());
            }
        }
    }

    private sealed class ScriptedVideoEncoder(
        Func<CapturedFrame, CancellationToken, ValueTask<EncodedVideoFrame?>> encode)
        : IVideoEncoder
    {
        private int disposed;

        internal bool IsDisposed => Volatile.Read(ref disposed) != 0;

        public ValueTask<EncodedVideoFrame?> EncodeAsync(
            CapturedFrame frame,
            CancellationToken cancellationToken) =>
            encode(frame, cancellationToken);

        public ValueTask DisposeAsync()
        {
            Interlocked.Exchange(ref disposed, 1);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class DelegateHostInputSessionFactory(
        Func<IHostInputSession> create) : IHostInputSessionFactory
    {
        public IHostInputSession Create() => create();
    }

    private sealed class RecordingWindowInputTargetResolver(WindowBounds bounds) :
        IWindowInputTargetResolver
    {
        internal int ResolveCount { get; private set; }
        internal int AcquireForegroundCount { get; private set; }
        internal int RequireForegroundCount { get; private set; }

        public WindowInputTargetResult Resolve(
            WindowDescriptor expectedWindow,
            WindowInputFocusMode focusMode)
        {
            _ = expectedWindow;
            ResolveCount++;
            if (focusMode == WindowInputFocusMode.AcquireForeground)
            {
                AcquireForegroundCount++;
            }
            else if (focusMode == WindowInputFocusMode.RequireForeground)
            {
                RequireForegroundCount++;
            }

            return WindowInputTargetResult.Success(bounds);
        }
    }

    private sealed class RecordingInputInjector : IHostInputInjector
    {
        internal List<string> Calls { get; } = [];
        internal int ReleaseCount { get; private set; }
        internal IReadOnlyList<MouseButton> ReleasedMouseButtons { get; private set; } = [];
        internal IReadOnlyList<ushort> ReleasedVirtualKeys { get; private set; } = [];

        public InputInjectionResult MovePointer(
            WindowBounds targetWindow,
            double normalizedX,
            double normalizedY)
        {
            _ = targetWindow;
            Calls.Add(FormattableString.Invariant($"move:{normalizedX}:{normalizedY}"));
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendPointerButton(
            WindowBounds targetWindow,
            double normalizedX,
            double normalizedY,
            MouseButton button,
            MouseButtonAction action)
        {
            _ = targetWindow;
            Calls.Add(FormattableString.Invariant(
                $"pointer:{button}:{action}:{normalizedX}:{normalizedY}"));
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendMouseButton(
            MouseButton button,
            MouseButtonAction action)
        {
            Calls.Add($"button:{button}:{action}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendMouseWheel(int verticalDelta, int horizontalDelta)
        {
            Calls.Add($"wheel:{verticalDelta}:{horizontalDelta}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendVirtualKey(
            ushort virtualKey,
            VirtualKeyAction action)
        {
            Calls.Add($"key:{virtualKey}:{action}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendVirtualKeyChord(IReadOnlyList<ushort> virtualKeys)
        {
            Calls.Add($"chord:{string.Join(',', virtualKeys)}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendText(string? text)
        {
            Calls.Add($"text:{text?.Length ?? -1}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult SendMediaKey(ushort virtualKey)
        {
            Calls.Add($"media:{virtualKey}");
            return InputInjectionResult.Success;
        }

        public InputInjectionResult ReleaseHeldInputs(
            IReadOnlyCollection<MouseButton> mouseButtons,
            IReadOnlyCollection<ushort> virtualKeys)
        {
            ReleaseCount++;
            ReleasedMouseButtons = mouseButtons.ToArray();
            ReleasedVirtualKeys = virtualKeys.ToArray();
            return InputInjectionResult.Success;
        }
    }

    private sealed class FakeWindowEnumerator(IReadOnlyList<WindowDescriptor> windows)
        : IWindowEnumerator
    {
        internal int CallCount { get; private set; }

        public IReadOnlyList<WindowDescriptor> Enumerate()
        {
            CallCount++;
            return windows;
        }
    }

    private sealed class RecordingHostAwakeController : IHostAwakeController
    {
        private readonly Channel<bool> updates = Channel.CreateUnbounded<bool>();

        internal List<bool> Updates { get; } = [];

        public bool IsHolding { get; private set; }

        public string? LastError => null;

        internal bool IsDisposed { get; private set; }

        public void SetClientVisible(bool visible)
        {
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            if (visible == IsHolding)
            {
                return;
            }

            IsHolding = visible;
            Updates.Add(visible);
            updates.Writer.TryWrite(visible);
        }

        internal async Task<bool> ReadUpdateAsync() =>
            await updates.Reader.ReadAsync().AsTask()
                .WaitAsync(TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);

        public void Dispose()
        {
            IsHolding = false;
            IsDisposed = true;
            updates.Writer.TryComplete();
        }
    }

    private sealed class BlockingWindowEnumerator : IWindowEnumerator
    {
        internal TaskCompletionSource Entered { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        internal ManualResetEventSlim Release { get; } = new(false);

        public IReadOnlyList<WindowDescriptor> Enumerate()
        {
            Entered.TrySetResult();
            Release.Wait(TimeSpan.FromSeconds(5));
            return
            [
                new WindowDescriptor(
                    (nint)0x1111,
                    1,
                    "Test",
                    "Test",
                    "Stale",
                    new WindowBounds(0, 0, 100, 100)),
            ];
        }
    }

    private sealed class SingleConnectionTransportFactory(PeelPskConnection connection) :
        IPeelPskTransportFactory
    {
        public ValueTask<Stream> ConnectAsync(
            DnsEndPoint endpoint,
            PeelPskCredential credential,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromException<Stream>(new NotSupportedException());

        public ValueTask<IPeelPskListener> ListenAsync(
            IPEndPoint endpoint,
            IPeelPskCredentialResolver credentialResolver,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<IPeelPskListener>(
                new SingleConnectionListener(connection, endpoint));
        }
    }

    private sealed class SingleConnectionListener(
        PeelPskConnection connection,
        IPEndPoint endpoint) : IPeelPskListener
    {
        private int accepted;

        public EndPoint LocalEndPoint { get; } = endpoint;

        public async ValueTask<PeelPskConnection> AcceptAsync(
            CancellationToken cancellationToken = default)
        {
            if (Interlocked.CompareExchange(ref accepted, 1, 0) == 0)
            {
                return connection;
            }

            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken)
                .ConfigureAwait(false);
            throw new OperationCanceledException(cancellationToken);
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class CancellationIgnoringDuplexStream(byte[] input) : Stream
    {
        private readonly TaskCompletionSource disposeSignal = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly MemoryStream output = new();
        private int inputOffset;
        private int disposed;

        internal TaskCompletionSource BlockedReadEntered { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        internal bool IsDisposed => Volatile.Read(ref disposed) != 0;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override Task FlushAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            if (inputOffset < input.Length)
            {
                int byteCount = Math.Min(buffer.Length, input.Length - inputOffset);
                input.AsMemory(inputOffset, byteCount).CopyTo(buffer);
                inputOffset += byteCount;
                return byteCount;
            }

            BlockedReadEntered.TrySetResult();
            await disposeSignal.Task.ConfigureAwait(false);
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            return 0;
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(IsDisposed, this);
            output.Write(buffer.Span);
            return ValueTask.CompletedTask;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && Interlocked.Exchange(ref disposed, 1) == 0)
            {
                disposeSignal.TrySetResult();
                output.Dispose();
            }

            base.Dispose(disposing);
        }

        public override ValueTask DisposeAsync()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class InteractiveDuplexStream(
        Action<ReadOnlyMemory<byte>>? writeObserver = null,
        bool ignoreFlushCancellation = false) : Stream
    {
        private readonly Channel<byte[]> input = Channel.CreateUnbounded<byte[]>(
            new UnboundedChannelOptions
            {
                SingleReader = true,
                SingleWriter = false,
            });
        private readonly object outputLock = new();
        private readonly MemoryStream output = new();
        private byte[]? currentInput;
        private int currentInputOffset;
        private int disposed;

        internal byte[] WrittenBytes
        {
            get
            {
                lock (outputLock)
                {
                    return output.ToArray();
                }
            }
        }

        internal void EnqueueLines(params object[] messages)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            if (!input.Writer.TryWrite(CombineLines(messages)))
            {
                throw new InvalidOperationException("The interactive stream input is closed.");
            }
        }

        internal void CompleteInput() => input.Writer.TryComplete();

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override Task FlushAsync(CancellationToken cancellationToken)
        {
            if (!ignoreFlushCancellation) cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            while (currentInput is null || currentInputOffset == currentInput.Length)
            {
                try
                {
                    currentInput = await input.Reader.ReadAsync(cancellationToken)
                        .ConfigureAwait(false);
                    currentInputOffset = 0;
                }
                catch (ChannelClosedException)
                {
                    return 0;
                }
            }

            int byteCount = Math.Min(buffer.Length, currentInput.Length - currentInputOffset);
            currentInput.AsMemory(currentInputOffset, byteCount).CopyTo(buffer);
            currentInputOffset += byteCount;
            return byteCount;
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (outputLock)
            {
                ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
                output.Write(buffer.Span);
            }

            writeObserver?.Invoke(buffer);
            return ValueTask.CompletedTask;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && Interlocked.Exchange(ref disposed, 1) == 0)
            {
                input.Writer.TryComplete();
                lock (outputLock)
                {
                    output.Dispose();
                }
            }

            base.Dispose(disposing);
        }

        public override ValueTask DisposeAsync()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
            return ValueTask.CompletedTask;
        }
    }

    private sealed class ScriptedDuplexStream : Stream
    {
        private readonly object stateLock = new();
        private readonly byte[] input;
        private readonly MemoryStream output = new();
        private readonly int maximumReadBytes;
        private readonly Action<ReadOnlyMemory<byte>>? writeObserver;
        private int inputOffset;
        private bool disposed;

        internal ScriptedDuplexStream(
            byte[] input,
            int maximumReadBytes = int.MaxValue,
            Action<ReadOnlyMemory<byte>>? writeObserver = null)
        {
            this.input = input;
            this.maximumReadBytes = maximumReadBytes;
            this.writeObserver = writeObserver;
        }

        internal byte[] WrittenBytes
        {
            get
            {
                lock (stateLock)
                {
                    return output.ToArray();
                }
            }
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override Task FlushAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            await Task.Yield();
            cancellationToken.ThrowIfCancellationRequested();

            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                if (inputOffset == input.Length)
                {
                    return 0;
                }

                int byteCount = Math.Min(
                    Math.Min(buffer.Length, maximumReadBytes),
                    input.Length - inputOffset);
                input.AsMemory(inputOffset, byteCount).CopyTo(buffer);
                inputOffset += byteCount;
                return byteCount;
            }
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override async ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            await Task.Yield();
            cancellationToken.ThrowIfCancellationRequested();

            lock (stateLock)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                output.Write(buffer.Span);
            }

            writeObserver?.Invoke(buffer);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                lock (stateLock)
                {
                    disposed = true;
                }
            }

            base.Dispose(disposing);
        }

        public override ValueTask DisposeAsync()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
            return ValueTask.CompletedTask;
        }
    }
}
