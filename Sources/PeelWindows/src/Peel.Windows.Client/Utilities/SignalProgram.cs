using System.Globalization;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

public readonly record struct SignalColor(double Red, double Green, double Blue)
{
    internal SignalColor Mix(SignalColor target, double amount)
    { amount = Math.Clamp(amount, 0, 1); return new(Red + (target.Red - Red) * amount, Green + (target.Green - Green) * amount, Blue + (target.Blue - Blue) * amount); }
    internal SignalColor Scale(double factor) => new(Red * factor, Green * factor, Blue * factor);
    internal static SignalColor Parse(string value)
    { uint rgb = uint.Parse(value.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture); return new((rgb >> 16) / 255d, ((rgb >> 8) & 255) / 255d, (rgb & 255) / 255d); }
}

/// <summary>Renders the accepted firmware-text subset with the Mac LEDProgramRenderer's timing and easing.</summary>
public sealed class SignalProgram
{
    private readonly record struct Assignment(int Index, SignalColor Color, double Duration, double Delay, string Easing)
    {
        internal SignalColor At(SignalColor start, double elapsed)
        {
            if (elapsed < Delay) return start;
            if (Easing == "none") return Color;
            double progress = Duration <= 0 ? 1 : (elapsed - Delay) / Duration;
            if (Easing == "pulse" && progress >= 1) return start;
            double value = Math.Clamp(progress, 0, 1);
            double amount = Easing switch
            {
                "ease" => value * value * (3 - 2 * value), "ease-in" => value * value, "ease-out" => 1 - (1 - value) * (1 - value),
                "ease-in-out" or "cosine" => .5 - .5 * Math.Cos(Math.PI * value), "pulse" => .5 - .5 * Math.Cos(2 * Math.PI * value), _ => value,
            };
            return start.Mix(Color, amount);
        }
    }
    private sealed record Step(Assignment[] Assignments, double Duration);
    private readonly Step[] steps;
    private readonly int count;
    private readonly double brightness, cycle;
    private readonly bool repeats;
    public SignalProgram(string program, int ledCount = 8)
    {
        TrustedSignals.ValidateProgram(program);
        count = Math.Clamp(ledCount, 1, 8); brightness = 1;
        var parsed = new List<Step>();
        foreach (string line in program.Replace("\r\n", "\n").Split(['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']))
        {
            if (line.StartsWith("brightness ", StringComparison.Ordinal)) { brightness = int.Parse(line.AsSpan(11), CultureInfo.InvariantCulture) / 255d; continue; }
            if (line == "repeat") { repeats = true; break; }
            var assignments = new Dictionary<int, Assignment>();
            var segments = line.Split(';');
            foreach (string segment in segments)
            {
                var tokens = segment.Split(' '); string first = tokens[0];
                if (first.StartsWith('#') && segments.Length == 1 && tokens.Length > 1 && tokens[1].StartsWith('#'))
                {
                    for (int i = 0; i < Math.Min(count, tokens.Length); i++) assignments[i] = new(i, SignalColor.Parse(tokens[i]), 1d / 60, 0, "none");
                    continue;
                }
                var timing = tokens.Skip(1).ToArray();
                double duration = timing.Length == 0 ? 1d / 60 : Seconds(timing[0]);
                string easing = timing.Length == 0 ? "none" : timing[1];
                double delay = timing.Length == 3 ? Seconds(timing[2]) : 0;
                if (first == "off" || first.StartsWith('#'))
                {
                    var color = first == "off" ? default : SignalColor.Parse(first);
                    for (int i = 0; i < count; i++) assignments[i] = new(i, color, duration, delay, easing);
                }
                else
                {
                    int index = first[0] - '0';
                    if (index < count) assignments[index] = new(index, SignalColor.Parse(first[2..]), duration, delay, easing);
                }
            }
            if (assignments.Count > 0) parsed.Add(new(assignments.Values.OrderBy(a => a.Index).ToArray(), Math.Max(1d / 60, assignments.Values.Max(a => a.Delay + a.Duration))));
        }
        steps = parsed.ToArray(); cycle = steps.Sum(s => s.Duration);
    }
    public SignalColor[] Frame(double elapsed)
    {
        double remaining = double.IsFinite(elapsed) ? Math.Max(0, elapsed) : 0;
        if (repeats && cycle > 0) remaining %= cycle;
        var colors = new SignalColor[count];
        foreach (var step in steps)
        {
            var previous = colors.ToArray();
            foreach (var assignment in step.Assignments)
                colors[assignment.Index] = remaining < step.Duration ? assignment.At(previous[assignment.Index], remaining)
                    : assignment.Easing == "pulse" ? previous[assignment.Index] : assignment.Color;
            if (remaining < step.Duration) break;
            remaining -= step.Duration;
        }
        for (int i = 0; i < colors.Length; i++) colors[i] = colors[i].Scale(brightness);
        return colors;
    }
    public bool NeedsAnimation(double elapsed) => repeats && cycle > 0 || Math.Max(0, elapsed) < cycle;
    private static double Seconds(string value) => value.EndsWith("ms", StringComparison.Ordinal)
        ? double.Parse(value.AsSpan(0, value.Length - 2), CultureInfo.InvariantCulture) / 1000 : double.Parse(value.AsSpan(0, value.Length - 1), CultureInfo.InvariantCulture);
}
