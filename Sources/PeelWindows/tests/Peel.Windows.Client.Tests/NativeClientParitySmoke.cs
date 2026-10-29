using System.Net;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Peel.Windows.Client;
using Peel.Windows.Client.Models;
using Peel.Windows.Client.Services;
using Peel.Windows.Client.ViewModels;
using Peel.Windows.Discovery;
using Peel.Windows.Host.Capture;
using Peel.Windows.Host.Encoding;
using Peel.Windows.Protocol;
using Peel.Windows.Transport;

namespace Peel.Windows.Client.Tests;

internal static partial class Program
{
    private static async Task<int> NativeClientReceiveSmokeAsync(bool fiveK = false, bool gpuPresentation = false)
    {
        int width = fiveK ? 5120 : 64, height = fiveK ? 2880 : 64;
        var codec = fiveK ? PeelVideoCodec.Hevc : PeelVideoCodec.H264;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var (store, vault) = ParityStore();
        using (vault)
        {
            byte[] key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
            string pairingId = Guid.NewGuid().ToString();
            store.Save(ParityHostId, "Native TLS fixture", pairingId, key);
            var factory = new BouncyCastlePskTransportFactory();
            await using var listener = await factory.ListenAsync(new IPEndPoint(IPAddress.Loopback, 0), new ParityTlsResolver(pairingId, key), timeout.Token);
            var port = checked((ushort)((IPEndPoint)listener.LocalEndPoint).Port);
            var browser = new ParityBrowser();
            var addresses = new SavedHostAddressStore(Path.Combine(Path.GetTempPath(), "peel-native-unused-" + Guid.NewGuid().ToString("N") + ".json"));
            await using var client = new ProductionClientServices(store, addresses, browser, factory, useGpuPresentation: gpuPresentation);
            var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var hello = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var encodedCompletion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var frameCompletion = new TaskCompletionSource<DecodedVideoFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
            int frameCount = 0;
            client.FrameAvailable += (_, e) => { if (Interlocked.Increment(ref frameCount) == 10) frameCompletion.TrySetResult(e.Frame.Retain()); };

            var controlServer = Task.Run(async () =>
            {
                await using var connection = await listener.AcceptAsync(timeout.Token);
                Equal(pairingId, connection.PeerIdentity);
                var reader = new NdjsonReader(64 * 1024); var buffer = new byte[4096];
                while (true)
                {
                    int count = await connection.Stream.ReadAsync(buffer, timeout.Token);
                    if (count == 0) return;
                    foreach (var line in reader.Append(buffer.AsSpan(0, count)))
                    {
                        var bytes = Encoding.UTF8.GetBytes(line);
                        switch (PeelJson.ReadEnvelope(bytes).Type)
                        {
                            case PeelMessageType.ClientHello:
                                Equal(pairingId, PeelJson.Deserialize<ClientHelloMessage>(bytes).PairingId);
                                await connection.Stream.WriteAsync(PeelJson.SerializeLine(PeelHello.CreateHost("Native fixture", capabilities:
                                    [PeelCapability.H264Video, .. fiveK ? new[] { PeelCapability.HevcVideo } : [], PeelCapability.BinaryVideoTransportV2, PeelCapability.PerWindowVideoConnections])), timeout.Token);
                                await connection.Stream.FlushAsync(timeout.Token); hello.TrySetResult(); break;
                            case PeelMessageType.RequestWindowList:
                                await connection.Stream.WriteAsync(PeelJson.SerializeLine(new WindowListMessage([new PeelWindow(101, "Fixture", "Native test video", width, height)])), timeout.Token);
                                await connection.Stream.FlushAsync(timeout.Token); break;
                            case PeelMessageType.StartStream: start.TrySetResult(); break;
                            case PeelMessageType.StopStream: stopped.TrySetResult(); return;
                        }
                    }
                }
            }, timeout.Token);

            var videoServer = Task.Run(async () =>
            {
                await hello.Task.WaitAsync(timeout.Token);
                await using var connection = await listener.AcceptAsync(timeout.Token);
                Equal(pairingId, connection.PeerIdentity);
                var reader = new NdjsonReader(16 * 1024); var buffer = new byte[4096];
                VideoStreamHelloMessage? request = null;
                while (request is null)
                {
                    int count = await connection.Stream.ReadAsync(buffer, timeout.Token);
                    if (count == 0) throw new IOException("Video fixture closed before hello.");
                    foreach (var line in reader.Append(buffer.AsSpan(0, count))) request = PeelJson.Deserialize<VideoStreamHelloMessage>(Encoding.UTF8.GetBytes(line));
                }
                Equal(101u, request.WindowId); Equal(pairingId, request.PairingId);
                await start.Task.WaitAsync(timeout.Token);
                await using var encoder = await new MediaFoundationH264EncoderFactory().CreateAsync(new(fiveK ? VideoCodec.Hevc : VideoCodec.H264, width, height, 30, fiveK ? 20_000_000 : 1_000_000, fiveK), timeout.Token);
                bool sentConfig = false;
                for (int i = 0; i < (fiveK ? 12 : 40); i++)
                {
                    var frame = new CapturedFrame(width, height, width * 4, (i + 1) * 333333L, CapturePixelFormat.Bgra8, CreateNativeDecodeInput(width, height, i));
                    var encoded = await encoder.EncodeAsync(frame, timeout.Token);
                    if (encoded is null) continue;
                    if (!sentConfig)
                    {
                        var c = encoded.Configuration ?? throw new InvalidDataException("Missing native H.264 configuration.");
                        await connection.Stream.WriteAsync(new VideoConfigPacket(101, codec, (uint)width, (uint)height,
                            c.Timescale, c.NalUnitHeaderLength, c.SequenceParameterSet.ToArray(), c.PictureParameterSet.ToArray(), c.VideoParameterSet.ToArray()).Encode(), timeout.Token);
                        sentConfig = true;
                    }
                    await connection.Stream.WriteAsync(new VideoFramePacket(101, encoded.IsKeyFrame, encoded.Timestamp100Nanoseconds,
                        encoded.Duration100Nanoseconds, encoded.Bytes.ToArray()).Encode(), timeout.Token);
                    await connection.Stream.FlushAsync(timeout.Token);
                }
                encodedCompletion.TrySetResult();
                await stopped.Task.WaitAsync(timeout.Token);
            }, timeout.Token);

            await client.StartAsync(timeout.Token);
            browser.Push(ParityService(PeelServiceType.Control, port));
            await WaitUntilAsync(() => client.DiscoveredHosts.Count == 1);
            await client.ConnectAsync(client.DiscoveredHosts.Single(), timeout.Token);
            await ((IWindowListService)client).StartAsync(timeout.Token);
            await WaitUntilAsync(() => client.Windows.Count == 1);
            await ((IStreamControlService)client).StartAsync(client.Windows.Single(), timeout.Token);
            using var decoded = await frameCompletion.Task.WaitAsync(timeout.Token);
            Equal(width, decoded.PixelWidth); Equal(height, decoded.PixelHeight);
            if (gpuPresentation) { True(decoded.UsesGpuPresentation, "Native decoder must deliver a shared GPU presentation surface."); True(decoded.Bgra32Pixels.IsEmpty, "GPU presentation must not allocate CPU pixels."); }
            else True(decoded.Bgra32Pixels.Span.IndexOfAnyExcept((byte)0) >= 0, "Native decoder must provide actual pixels.");
            await OnStaAsync(() =>
            {
                using var presenter = new WpfVideoPresenter();
                True(presenter.Present(decoded), "Composed frame must reach WPF.");
                var bitmap = presenter.Source;
                if (!gpuPresentation)
                {
                    byte[] copied = new byte[decoded.Stride * decoded.PixelHeight];
                    ((BitmapSource)bitmap!).CopyPixels(copied, decoded.Stride, 0);
                    SequenceEqual(decoded.Bgra32Pixels.ToArray(), copied);
                }
                if (fiveK)
                {
                    var view = new System.Windows.Controls.Image { Source = bitmap, Stretch = Stretch.Uniform };
                    view.Measure(new Size(1280, 720)); view.Arrange(new Rect(0, 0, 1280, 720));
                    var rendered = new RenderTargetBitmap(1280, 720, 96, 96, PixelFormats.Pbgra32); rendered.Render(view);
                    var pixels = new byte[1280 * 720 * 4]; rendered.CopyPixels(pixels, 1280 * 4, 0);
                    bool hasColor = false;
                    for (int offset = 0; offset < pixels.Length; offset += 4)
                        if (pixels[offset] != 0 || pixels[offset + 1] != 0 || pixels[offset + 2] != 0) { hasColor = true; break; }
                    True(hasColor, "5K source must render visible color through the WPF Image surface.");
                }
            });
            True(!client.Input.IsEnabled, "Composed receiving must not implicitly enable control.");
            await encodedCompletion.Task.WaitAsync(timeout.Token);
            await ((IStreamControlService)client).StopAsync(timeout.Token);
            await controlServer.WaitAsync(timeout.Token); await videoServer.WaitAsync(timeout.Token);
            await client.DisconnectAsync(timeout.Token);
            Equal(PeelConnectionState.Disconnected, client.State);
            store.Forget(ParityHostId); Equal(0, vault.Count);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
            Console.WriteLine($"PASS composed native receiver: exact TLS-PSK control/video, {width}x{height}, {frameCount} actual {codec} decoded frames, GPU presentation={gpuPresentation}, WPF pixel round-trip/render, input off, clean stop. Not a sustained frame-rate measurement.");
            return 0;
        }
    }

    private static Task OnStaAsync(Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() => { try { action(); completion.TrySetResult(); } catch (Exception e) { completion.TrySetException(e); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return completion.Task;
    }

    private static async Task<int> RenderClientLayoutAsync(string path, int section = -1, int width = 1320, int height = 820)
    {
        await OnStaAsync(() =>
        {
            var application = new System.Windows.Application();
            application.Resources.Add("BooleanToVisibilityConverter", new System.Windows.Controls.BooleanToVisibilityConverter());
            var unavailable = new UnavailableClientServices("Layout fixture · no network connections");
            var model = new MainWindowViewModel(unavailable, unavailable, unavailable, unavailable, unavailable);
            model.DiscoveredHosts.Add(new(ParityHostId, "fixture", "Layout fixture MacBook Pro", "fixture.local", 9000, false));
            model.SavedHosts.Add(new(ParityHostId, "fixture", "Layout fixture Mac mini", "100.64.2.3", 9001, true, true));
            model.RemoteWindows.Add(new(0xFFF00001, "Studio Display", "Peel Display", 1920, 1080));
            model.RemoteWindows.Add(new(2, "Notes — Layout fixture", "Notes", 900, 700));
            var window = new MainWindow { DataContext = model };
            using var lighting = new LightingFixture();
            var studioModel = new Peel.Windows.Client.Utilities.CommandCenterViewModel(System.Windows.Threading.Dispatcher.CurrentDispatcher, lighting.Settings);
            if (section >= 0)
            {
                studioModel.AgentDisplayMode = "perAgent";
                studioModel.LocalActivity.Add(new("fixture-a", "Layout fixture · thinking", "working", "", DateTimeOffset.UtcNow));
                studioModel.LocalActivity.Add(new("fixture-b", "Layout fixture · needs input", "waiting", "", DateTimeOffset.UtcNow));
                studioModel.LocalActivity.Add(new("fixture-c", "Layout fixture · tool running", "toolRunning", "", DateTimeOffset.UtcNow));
                studioModel.RefreshSignalPresentation();
                var center = (Peel.Windows.Client.Utilities.CommandCenterView)window.FindName("CommandCenter");
                center.DataContext = studioModel;
                window.ShowUtilities(section);
                var navigation = (System.Windows.Controls.ListBox)window.FindName("StudioNavigation");
                True(navigation.SelectedItem is System.Windows.Controls.ListBoxItem { Tag: string tag } && tag == section.ToString(), "Sidebar must reflect the selected utility.");
                ((System.Windows.Controls.TabControl)center.FindName("Sections")).SelectedIndex = 4;
                Equal("Peel Settings", ((System.Windows.Controls.TextBlock)center.FindName("PageTitle")).Text);
                True(navigation.SelectedItem is System.Windows.Controls.ListBoxItem { Tag: "4" }, "Keyboard-driven page changes must update the sidebar.");
                window.ShowUtilities(section);
                double beforeWidth = window.Width, beforeHeight = window.Height;
                navigation.SelectedItem = navigation.Items.OfType<System.Windows.Controls.ListBoxItem>().Single(item => Equals(item.Tag, "host"));
                Equal(beforeWidth, window.Width); Equal(beforeHeight, window.Height);
                True(((FrameworkElement)window.FindName("HostModeContent")).IsVisible == false, "Unshown fixture must not activate hosting.");
                Equal("Share This PC", ((System.Windows.Controls.TextBlock)window.FindName("RemoteDesktopModeText")).Text);
                window.ShowUtilities(section);
                Equal("Connect or Share", ((System.Windows.Controls.TextBlock)window.FindName("RemoteDesktopModeText")).Text);
            }
            else
            {
                typeof(MainWindow).GetMethod("SetMode", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(window, [section == -2]);
                // The visible Remote Desktop selector names the page actually shown.
                Equal(section == -2 ? "Share This PC" : "Connect", ((System.Windows.Controls.TextBlock)window.FindName("RemoteDesktopModeText")).Text);
                True(!model.CanOpenSelectedWindow, "Open stays disabled until a connected computer's window is selected.");
            }
            var root = (FrameworkElement)window.Content;
            root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
            var image = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); image.Render(root);
            var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(image));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            using var output = File.Create(path); png.Save(output);
            window.Close(); studioModel.DisposeAsync().AsTask().GetAwaiter().GetResult(); model.DisposeAsync().AsTask().GetAwaiter().GetResult();
        });
        Console.WriteLine("PASS rendered production Client layout using explicitly labeled fixture data."); return 0;
    }

    private sealed class ParityTlsResolver(string identity, byte[] key) : IPeelPskCredentialResolver
    {
        public bool TryResolve(string requested, out PeelPskCredential? credential)
        { credential = requested == identity ? new(identity, key) : null; return credential is not null; }
    }
}
