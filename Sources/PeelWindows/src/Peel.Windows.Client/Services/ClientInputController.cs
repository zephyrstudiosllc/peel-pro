using System.IO;
using Peel.Windows.Client.Models;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Services;

public sealed class ClientInputController : INormalizedInputService, IDisposable
{
    private readonly ClientSession session;
    private readonly IStreamControlService stream;
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly object gate = new();
    private readonly Dictionary<ushort, NormalizedKeyInput> heldKeys = [];
    private readonly HashSet<NormalizedPointerButton> heldButtons = [];
    private NormalizedPoint lastPoint;
    private long epoch;
    private long sessionGeneration;
    private uint? windowId;
    private bool enabled;
    private int pending;
    private Task releaseTask = Task.CompletedTask;
    private bool hasFrame;
    private bool disposed;

    public ClientInputController(ClientSession session, IStreamControlService stream)
    {
        this.session = session; this.stream = stream;
        session.StateChanged += ConnectionChanged;
        stream.StateChanged += StreamChanged;
        stream.FrameAvailable += FrameReceived;
        session.InputRejected += InputRefused;
    }

    private void ConnectionChanged(object? sender, ConnectionStateChangedEventArgs e) { if (e.State != PeelConnectionState.Connected) Disable(); }
    private void StreamChanged(object? sender, StreamStateChangedEventArgs e) { if (e.State != PeelStreamState.Streaming) { lock (gate) hasFrame = false; Disable(); } }
    private void FrameReceived(object? sender, DecodedVideoFrameEventArgs e) { lock (gate) hasFrame = !disposed; }
    private void InputRefused(object? sender, SessionInputRejection e)
    {
        if (e.Generation != session.SessionGeneration || e.Message.WindowId != stream.StreamingWindowId) return;
        string reason = e.Message.Reason ?? "Input permission unavailable";
        Disable("Host refused input: " + reason[..Math.Min(reason.Length, 256)]);
    }
    public async Task ReleaseAsync(CancellationToken token = default)
    {
        Disable(); Task release; lock (gate) release = releaseTask;
        await release.WaitAsync(token).ConfigureAwait(false);
    }
    public void Dispose()
    {
        lock (gate) { if (disposed) return; disposed = true; }
        Disable(); session.StateChanged -= ConnectionChanged; stream.StateChanged -= StreamChanged;
        stream.FrameAvailable -= FrameReceived; session.InputRejected -= InputRefused;
    }

    public event EventHandler<string>? ControlChanged;
    public bool IsEnabled { get { lock (gate) return enabled; } }

    public async Task EnableAsync(CancellationToken token)
    {
        long requestedEpoch;
        uint requestedWindow;
        long generation;
        Task previousRelease;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!hasFrame || stream.State != PeelStreamState.Streaming || stream.StreamingWindowId is not uint id)
                throw new InvalidOperationException("Wait for live video before enabling control.");
            requestedEpoch = ++epoch; requestedWindow = id; generation = session.SessionGeneration;
            enabled = false;
            previousRelease = releaseTask;
        }
        await previousRelease.WaitAsync(token).ConfigureAwait(false);
        await session.RequestInputFocusAsync(requestedWindow, token).ConfigureAwait(false);
        lock (gate)
        {
            if (epoch != requestedEpoch || session.SessionGeneration != generation
                || session.State != PeelConnectionState.Connected || stream.State != PeelStreamState.Streaming
                || stream.StreamingWindowId != requestedWindow)
                throw new OperationCanceledException("The active stream changed while requesting control.");
            windowId = requestedWindow; sessionGeneration = generation; enabled = true;
        }
        ControlChanged?.Invoke(this, "Control enabled · Ctrl+Alt+Esc releases it");
    }

    public void Disable(string reason = "Control off")
    {
        uint? previousWindow;
        long generation;
        lock (gate)
        {
            epoch++; enabled = false; previousWindow = windowId;
            generation = sessionGeneration; windowId = null;
            if (previousWindow is not null) releaseTask = ReleaseHeldAsync(previousWindow.Value, generation);
        }
        ControlChanged?.Invoke(this, reason);
    }

    private async Task ReleaseHeldAsync(uint id, long generation)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        bool acquired = false;
        try
        {
            await writer.WaitAsync(deadline.Token).ConfigureAwait(false);
            acquired = true;
            foreach (var key in heldKeys.Values.ToArray())
                await session.SendClientMessageAsync(ToKeyMessage(key with { IsDown = false }), generation,
                    deadline.Token).ConfigureAwait(false);
            foreach (var button in heldButtons.ToArray())
                await session.SendClientMessageAsync(new PeelRequest(PeelMessageType.MouseUp, id,
                    lastPoint.X, lastPoint.Y, ButtonName(button)), generation, deadline.Token).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException or ObjectDisposedException)
        {
            // Teardown releases host-owned input when a normal release cannot reach this session.
            if (session.SessionGeneration == generation)
                await session.DisconnectAsync(CancellationToken.None).ConfigureAwait(false);
        }
        finally { if (acquired) { heldKeys.Clear(); heldButtons.Clear(); writer.Release(); } }
    }

    public Task SendPointerAsync(NormalizedPointerInput input, CancellationToken token)
    {
        if (!Enum.IsDefined(input.Action) || !Enum.IsDefined(input.Button)
            || !double.IsFinite(input.ScrollDeltaX) || !double.IsFinite(input.ScrollDeltaY))
            throw new ArgumentException("Invalid pointer input.");
        if (input.Button == NormalizedPointerButton.Middle) return Task.CompletedTask;
        if (input.Action is NormalizedPointerAction.Down or NormalizedPointerAction.Up
            && input.Button == NormalizedPointerButton.None) throw new ArgumentException("A pointer button is required.");
        return SendAsync(input.WindowId, token, async generation =>
        {
            string type = input.Action switch
            {
                NormalizedPointerAction.Down => PeelMessageType.MouseDown,
                NormalizedPointerAction.Up => PeelMessageType.MouseUp,
                NormalizedPointerAction.Scroll => PeelMessageType.MouseScroll,
                _ => heldButtons.Count > 0 ? PeelMessageType.MouseDrag : PeelMessageType.MouseMove,
            };
            var button = input.Button == NormalizedPointerButton.None && heldButtons.Count > 0
                ? heldButtons.First() : input.Button;
            await session.SendClientMessageAsync(new PeelRequest(type, input.WindowId,
                input.Action == NormalizedPointerAction.Scroll ? Math.Clamp(input.ScrollDeltaX, -2400, 2400) : input.Position.X,
                input.Action == NormalizedPointerAction.Scroll ? Math.Clamp(input.ScrollDeltaY, -2400, 2400) : input.Position.Y,
                ButtonName(button)), generation, token).ConfigureAwait(false);
            lastPoint = input.Position;
            if (input.Action == NormalizedPointerAction.Down) heldButtons.Add(input.Button);
            if (input.Action == NormalizedPointerAction.Up) heldButtons.Remove(input.Button);
        }, dropIfBusy: input.Action == NormalizedPointerAction.Move);
    }

    public Task SendKeyAsync(NormalizedKeyInput input, CancellationToken token)
    {
        if (ToHidUsage(input.VirtualKey) == 0) return Task.CompletedTask;
        if (input.Meta && input.VirtualKey == 'Q') return Task.CompletedTask;
        return SendAsync(input.WindowId, token, async generation =>
        {
            await session.SendClientMessageAsync(ToKeyMessage(input), generation, token).ConfigureAwait(false);
            if (input.IsDown) heldKeys[input.VirtualKey] = input; else heldKeys.Remove(input.VirtualKey);
        });
    }

    private async Task SendAsync(uint id, CancellationToken token, Func<long, Task> send, bool dropIfBusy = false)
    {
        long queuedEpoch;
        long generation;
        lock (gate)
        {
            if (!enabled || id != windowId) return;
            queuedEpoch = epoch; generation = sessionGeneration;
        }
        if (Interlocked.Increment(ref pending) > (dropIfBusy ? 1 : 64))
        {
            Interlocked.Decrement(ref pending);
            if (!dropIfBusy) Disable("Control released because the connection cannot keep up.");
            return;
        }
        try
        {
            await writer.WaitAsync(token).ConfigureAwait(false);
            try
            {
                lock (gate)
                {
                if (!enabled || !hasFrame || epoch != queuedEpoch || windowId != id || session.SessionGeneration != generation
                        || session.State != PeelConnectionState.Connected || stream.State != PeelStreamState.Streaming
                        || stream.StreamingWindowId != id) return;
                }
                await send(generation).ConfigureAwait(false);
            }
            finally { writer.Release(); }
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or OperationCanceledException or ObjectDisposedException)
        { Disable("Control released after the connection changed."); }
        finally { Interlocked.Decrement(ref pending); }
    }

    private static string? ButtonName(NormalizedPointerButton b) => b switch
    { NormalizedPointerButton.Primary => "left", NormalizedPointerButton.Secondary => "right", _ => null };

    private static KeyboardHardwareKeyMessage ToKeyMessage(NormalizedKeyInput input)
    {
        var modifiers = new List<KeyboardCommand>(4);
        if (input.Shift) modifiers.Add(KeyboardCommand.Shift);
        if (input.Control) modifiers.Add(KeyboardCommand.Control);
        if (input.Alt) modifiers.Add(KeyboardCommand.Option);
        if (input.Meta) modifiers.Add(KeyboardCommand.Command);
        return new KeyboardHardwareKeyMessage(ToHidUsage(input.VirtualKey), modifiers, input.WindowId,
            Action: input.IsDown ? KeyboardCommandAction.Down : KeyboardCommandAction.Up);
    }

    internal static int ToHidUsage(ushort key) => key switch
    {
        >= 0x41 and <= 0x5A => key - 0x41 + 4,
        >= 0x31 and <= 0x39 => key - 0x31 + 30,
        0x30 => 39, 0x0D => 40, 0x1B => 41, 0x08 => 42, 0x09 => 43, 0x20 => 44,
        0xBD => 45, 0xBB => 46, 0xDB => 47, 0xDD => 48, 0xDC => 49, 0xBA => 51,
        0xDE => 52, 0xC0 => 53, 0xBC => 54, 0xBE => 55, 0xBF => 56, 0x14 => 57,
        >= 0x70 and <= 0x7B => key - 0x70 + 58,
        0x2D => 73, 0x24 => 74, 0x21 => 75, 0x2E => 76, 0x23 => 77, 0x22 => 78,
        0x27 => 79, 0x25 => 80, 0x28 => 81, 0x26 => 82,
        0x11 or 0xA2 => 224, 0x10 or 0xA0 => 225, 0x12 or 0xA4 => 226,
        0x5B => 227, 0xA3 => 228, 0xA1 => 229, 0xA5 => 230, 0x5C => 231, _ => 0,
    };
}
