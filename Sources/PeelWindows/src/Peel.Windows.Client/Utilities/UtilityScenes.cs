using System.Globalization;

namespace Peel.Windows.Client.Utilities;

internal enum CountdownPhase { Idle, Running, Paused, Finished }
internal sealed class Countdown
{
    internal CountdownPhase Phase { get; private set; }
    internal double Duration { get; private set; }
    private double pausedRemaining;
    private DateTimeOffset deadline;
    internal double Remaining(DateTimeOffset now) => Phase switch { CountdownPhase.Running => Math.Clamp((deadline - now).TotalSeconds, 0, Duration), CountdownPhase.Paused => pausedRemaining, _ => 0 };
    internal void Start(double seconds, DateTimeOffset now)
    {
        Duration = double.IsFinite(seconds) ? Math.Clamp(seconds, 1, 86400) : 1500;
        pausedRemaining = Duration; deadline = now.AddSeconds(Duration); Phase = CountdownPhase.Running;
    }
    internal bool Tick(DateTimeOffset now)
    {
        if (Phase != CountdownPhase.Running || Remaining(now) > 0) return false;
        Phase = CountdownPhase.Finished; pausedRemaining = 0; return true;
    }
    internal void Pause(DateTimeOffset now)
    { Tick(now); if (Phase == CountdownPhase.Running) { pausedRemaining = Remaining(now); Phase = CountdownPhase.Paused; } }
    internal void Resume(DateTimeOffset now)
    { if (Phase == CountdownPhase.Paused) { deadline = now.AddSeconds(pausedRemaining); Phase = CountdownPhase.Running; } }
    internal void Reset() { Phase = CountdownPhase.Idle; Duration = pausedRemaining = 0; }
    internal static string Label(double seconds)
    {
        int whole = (int)Math.Ceiling(double.IsFinite(seconds) ? Math.Clamp(seconds, 0, 86400) : 0);
        return whole >= 3600 ? $"{whole / 3600}:{whole / 60 % 60:00}:{whole % 60:00}" : $"{whole / 60:00}:{whole % 60:00}";
    }
}

internal sealed record UtilityScene(string Key, string Label, string Pro, string Dot, long? ValidUntil = null, DateTimeOffset? StartedAt = null);
internal static class UtilityScenes
{
    internal static string Program(string color, double intensity, int count, double fraction = 1, string motion = "solid", double seconds = 2)
    {
        int lit = (int)Math.Ceiling(Math.Clamp(double.IsFinite(fraction) ? fraction : 0, 0, 1) * Math.Clamp(count, 1, 8));
        if (lit == 0) return "off";
        uint rgb = uint.Parse(color.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        static int Scale(uint value, double scale) => (int)Math.Round(value * Math.Clamp(scale, 0, 1), MidpointRounding.AwayFromZero);
        color = $"#{Scale(rgb >> 16, intensity):X2}{Scale((rgb >> 8) & 255, intensity):X2}{Scale(rgb & 255, intensity):X2}";
        static string Time(double value)
        {
            int ms = Math.Max(1, (int)Math.Round(value * 100, MidpointRounding.AwayFromZero) * 10);
            return ms >= 1000 ? (ms / 1000d).ToString("0.##", CultureInfo.InvariantCulture) + "s" : ms.ToString(CultureInfo.InvariantCulture) + "ms";
        }
        double cycle = Math.Clamp(seconds, .2, 30);
        string duration = Time(motion == "flash" ? cycle / 2 : cycle);
        string targets = string.Join(';', Enumerable.Range(0, lit).Select(i => i + ":" + color));
        string prefix = lit < count ? "off\n" : "";
        if (motion == "solid") return prefix + targets;
        prefix += "off\n";
        if (motion == "flash") return prefix + targets.Replace(";", " " + duration + " none;", StringComparison.Ordinal) + " " + duration + " none\n" +
            string.Join(';', Enumerable.Range(0, lit).Select(i => i + ":#000000 " + duration + " none")) + "\nrepeat";
        if (motion == "breathe" && lit == 2)
            return prefix + $"0:{color} 250ms cosine\n1:{color} 250ms cosine\n0:#000000 250ms cosine\n1:#000000 250ms cosine\nrepeat";
        string rise = string.Join(';', Enumerable.Range(0, lit).Select(i =>
        {
            int maxStep = motion == "converge" ? (lit - 1) / 2 : lit - 1;
            int step = motion == "converge" ? Math.Min(i, lit - 1 - i) : i;
            bool travels = (motion is "breathe" or "converge") && maxStep > 0;
            double pulse = travels ? Math.Max(.16, cycle * .58) : cycle;
            double delay = travels ? Math.Max(0, cycle - pulse) * step / maxStep : 0;
            return i + ":" + color + " " + Time(pulse) + " pulse" + (delay >= .005 ? " " + Time(delay) : "");
        }));
        return prefix + rise + "\nrepeat";
    }
    internal static UtilityScene Timer(Countdown timer, DateTimeOffset now, int warning, bool animation)
    {
        double remaining = timer.Remaining(now);
        bool finished = timer.Phase == CountdownPhase.Finished;
        bool warns = remaining <= Math.Clamp(warning, 0, timer.Duration);
        string color = finished ? "#30D158" : warns ? "#FF9F0A" : "#7C3AED";
        double intensity = finished ? .9 : warns ? .8 : .65;
        string motion = finished ? "flash" : warns ? "pulse" : "solid";
        double fraction = finished || animation ? 1 : timer.Duration > 0 ? remaining / timer.Duration : 0;
        string label = "Timer · " + (finished ? "Finished" : timer.Phase == CountdownPhase.Idle ? "Ready" : Countdown.Label(remaining) + (timer.Phase == CountdownPhase.Paused ? " · paused" : ""));
        string pro = timer.Phase == CountdownPhase.Idle ? "off" : Program(color, intensity, 8, fraction, motion, finished ? .6 : 1.5);
        string dot = timer.Phase == CountdownPhase.Idle ? "off" : Program(color, intensity, 2, fraction, motion, finished ? .6 : 1.5);
        return new("timer:" + pro, label, pro, dot);
    }
}
