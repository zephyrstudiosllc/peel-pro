using System.Globalization;
using System.IO;
using Peel.Windows.Protocol;

namespace Peel.Windows.Client.Utilities;

internal sealed record LightAgent(string Id, string State, DateTimeOffset UpdatedAt, string Provider = "codex")
{
    internal int Priority => State switch { "error" => 0, "waiting" => 1, "toolRunning" => 2, "working" => 3, "completed" => 4, _ => 5 };
}
internal sealed record AgentLightScene(string Program, LightAgent?[] Slots);

/// <summary>Matches the Mac adaptive/stable allocators. Residency is owned by a single output.</summary>
internal sealed class LightAllocator
{
    private readonly List<string> resident = [];
    private readonly Dictionary<string, int> assignments = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> lastSeen = new(StringComparer.Ordinal);
    internal void Reset() { resident.Clear(); assignments.Clear(); lastSeen.Clear(); }
    internal LightAgent?[] Assign(IReadOnlyList<LightAgent> agents, int count, string strategy, DateTimeOffset now)
    {
        count = Math.Clamp(count, 1, 8);
        var latest = agents.Take(32).GroupBy(a => a.Id, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.OrderByDescending(a => a.UpdatedAt).First(), StringComparer.Ordinal);
        var result = new LightAgent?[count];
        if (strategy == "adaptiveOccupancy")
        {
            resident.RemoveAll(id => !latest.ContainsKey(id));
            string Victim() => resident.OrderBy(id => latest[id].UpdatedAt).First();
            while (resident.Count > count) resident.Remove(Victim());
            foreach (var candidate in latest.Values.OrderByDescending(a => a.UpdatedAt).ThenBy(a => a.Priority).ThenBy(a => a.Id, StringComparer.Ordinal))
            {
                if (resident.Contains(candidate.Id)) continue;
                if (resident.Count < count) resident.Add(candidate.Id);
                else { string victim = Victim(); if (candidate.UpdatedAt > latest[victim].UpdatedAt) resident[resident.IndexOf(victim)] = candidate.Id; }
            }
            if (resident.Count == 0) return result;
            int block = count == 8 ? resident.Count switch { 1 => 8, 2 => 4, <= 4 => 2, _ => 1 }
                : count == 2 ? resident.Count == 1 ? 2 : 1 : resident.Count == 1 ? count : Math.Max(1, count / resident.Count);
            int cursor = count - 1;
            foreach (string id in resident) for (int i = 0; i < block && cursor >= 0; i++) result[cursor--] = latest[id];
            return result;
        }
        // The Mac providerLanes path feeds the same stable allocator; its newcomer
        // ordering remains state priority, then recency, then session identity.
        if (strategy == "priorityStack") Reset();
        foreach (string id in latest.Keys) lastSeen[id] = now;
        foreach (string id in assignments.Keys.ToArray())
            if (assignments[id] >= count || !latest.ContainsKey(id) && now - lastSeen.GetValueOrDefault(id) >= TimeSpan.FromSeconds(300))
            { assignments.Remove(id); lastSeen.Remove(id); }
        var selected = assignments.Where(p => latest.ContainsKey(p.Key)).OrderBy(p => p.Value).Select(p => p.Key)
            .Concat(latest.Values.Where(a => !assignments.ContainsKey(a.Id)).OrderBy(a => a.Priority).ThenByDescending(a => a.UpdatedAt).ThenBy(a => a.Id, StringComparer.Ordinal).Select(a => a.Id)).Take(count).ToArray();
        foreach (string id in selected)
        {
            if (!assignments.ContainsKey(id))
            {
                int? free = Enumerable.Range(0, count).Where(i => !assignments.ContainsValue(i)).Cast<int?>().FirstOrDefault();
                if (free is { } slot) assignments[id] = slot;
                else if (assignments.Keys.Where(k => !latest.ContainsKey(k)).OrderBy(k => lastSeen.GetValueOrDefault(k)).FirstOrDefault() is { } victim)
                { assignments[id] = assignments[victim]; assignments.Remove(victim); lastSeen.Remove(victim); }
            }
            if (assignments.TryGetValue(id, out int index)) result[index] = latest[id];
        }
        // lastSeen entries for unallocated contenders need no reservation.
        foreach (string id in lastSeen.Keys.Where(id => !assignments.ContainsKey(id)).ToArray()) lastSeen.Remove(id);
        return result;
    }
}

internal static class AgentLighting
{
    private sealed record Rendered(int Index, LightStyle Style, int Position, int Count);
    internal static LightAgent[] Visible(IEnumerable<AgentActivityReading> readings, DateTimeOffset now) => readings.Take(32)
        .Where(r => now - r.EventAt <= TimeSpan.FromMinutes(15) && r.EventAt <= now.AddMinutes(5) && r.State is "error" or "waiting" or "toolRunning" or "working" or "completed")
        .Select(r => new LightAgent(r.Id, r.State, r.EventAt)).ToArray();
    internal static LightAgent[] ForMode(IReadOnlyList<LightAgent> agents, string mode)
    {
        if (mode == "perAgent") return agents.ToArray();
        var active = agents.Where(a => a.State != "idle").ToArray();
        if (active.Length == 0) return [];
        string state = active.Select(a => a with { State = a.State == "toolRunning" ? "working" : a.State }).OrderBy(a => a.Priority).First().State;
        return [new("sidepulse:simple-signal", state, active.Max(a => a.UpdatedAt), "unknown")];
    }
    internal static AgentLightScene Compile(LightingProfile profile, IReadOnlyList<LightAgent> agents, LightAllocator allocator, int count, DateTimeOffset now)
    {
        var slots = allocator.Assign(agents, count, profile.Strategy, now);
        if (slots.All(a => a is null)) return new("off", slots);
        var rendered = slots.Select((agent, index) =>
        {
            if (agent is null) return null;
            var indices = slots.Select((a, i) => (a, i)).Where(p => p.a?.Id == agent.Id).Select(p => p.i).ToArray();
            return new Rendered(index, profile.Style(agent.State), Array.IndexOf(indices, index), indices.Length);
        }).Where(r => r is not null).Select(r => r!).ToArray();
        bool split = rendered.Any(r => r.Style.ColorMode == "rotatingColorway" || r.Style.Motion == "flash" || r.Style.Motion == "chase" && r.Count > 1);
        var byIndex = rendered.ToDictionary(r => r.Index);
        string[] bases = slots.Select((_, index) => $"{index}:" + (byIndex.TryGetValue(index, out var slot) && slot.Style.Motion == "solid" ? Color(slot, 0) : "#000000")).ToArray();
        var lines = new List<string>(); int brightness = (int)(Math.Clamp(profile.DeviceBrightness, 0, 1) * 255);
        if (brightness < 255) lines.Add("brightness " + brightness);
        lines.Add(bases.All(s => s.EndsWith("#000000", StringComparison.Ordinal)) ? "off" : string.Join(';', bases));
        if (count == 2 && rendered.Length == 2 && slots.Where(a => a is not null).Select(a => a!.Id).Distinct().Count() == 1 && rendered.All(r => r.Style.Motion == "breathe" && r.Style.ColorMode != "rotatingColorway"))
        {
            lines.Add($"0:{Color(rendered[0], 0)} 250ms cosine"); lines.Add($"1:{Color(rendered[1], 0)} 250ms cosine");
            lines.Add("0:#000000 250ms cosine"); lines.Add("1:#000000 250ms cosine"); lines.Add("repeat");
        }
        else
        {
            var first = rendered.Select(r => Segment(r, 1, false, split)).Where(s => s is not null).ToArray();
            var second = split ? rendered.Select(r => Segment(r, 2, true, true)).Where(s => s is not null).ToArray() : [];
            if (first.Length > 0) lines.Add(string.Join(';', first));
            if (second.Length > 0) lines.Add(string.Join(';', second));
            if (first.Length > 0 || second.Length > 0) lines.Add("repeat");
        }
        string program = string.Join('\n', lines); TrustedSignals.ValidateProgram(program); return new(program, slots);
    }
    private static string? Segment(Rendered slot, int phase, bool reverse, bool split)
    {
        var style = slot.Style;
        if (style.Motion == "off" || style.Motion == "solid" && style.ColorMode != "rotatingColorway") return null;
        double cycle = Math.Clamp(style.CycleSeconds, .2, 30) / (split ? 2 : 1);
        string color = Color(slot, style.ColorMode == "rotatingColorway" ? phase : 0);
        if (style.Motion == "solid") return $"{slot.Index}:{(phase == 2 ? Color(slot, 0) : color)} {Time(cycle)} cosine";
        if (style.Motion == "flash") return $"{slot.Index}:{(phase == 2 ? "#000000" : color)} {Time(cycle)} none";
        if (style.Motion == "pulse") return Pulse(slot.Index, color, cycle, 0);
        int step = style.Motion switch
        {
            "chase" => reverse ? slot.Count - 1 - slot.Position : slot.Position,
            "converge" => Math.Min(slot.Position, slot.Count - 1 - slot.Position),
            "diverge" => Math.Min(Math.Abs(slot.Position - (slot.Count - 1) / 2), Math.Abs(slot.Position - slot.Count / 2)),
            _ => slot.Position,
        };
        int maxStep = style.Motion is "converge" or "diverge" ? (slot.Count - 1) / 2 : slot.Count - 1;
        if (maxStep <= 0) return Pulse(slot.Index, color, cycle, 0);
        double duration = Math.Max(.16, cycle * .58);
        return Pulse(slot.Index, color, duration, Math.Max(0, cycle - duration) * step / maxStep);
    }
    private static string Pulse(int index, string color, double duration, double delay) => $"{index}:{color} {Time(duration)} pulse" + (delay >= .005 ? " " + Time(delay) : "");
    internal static string Time(double seconds)
    {
        int ms = Math.Max(1, (int)Math.Round(seconds * 1000 / 10, MidpointRounding.AwayFromZero) * 10);
        return ms >= 1000 ? (ms / 1000d).ToString("0.##", CultureInfo.InvariantCulture) + "s" : ms.ToString(CultureInfo.InvariantCulture) + "ms";
    }
    private static string Color(Rendered slot, int phase)
    {
        var style = slot.Style;
        static (double R, double G, double B) Rgb(string hex) { uint value = uint.Parse(hex.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture); return ((value >> 16) / 255d, ((value >> 8) & 255) / 255d, (value & 255) / 255d); }
        var primary = Rgb(style.ColorHex); var secondary = Rgb(style.SecondaryColorHex);
        static (double R, double G, double B) Blend((double R, double G, double B) a, (double R, double G, double B) b, double t) => (a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t);
        var rgb = primary;
        switch (style.ColorMode)
        {
            case "colorway": rgb = Blend(primary, secondary, slot.Count <= 1 ? 0 : slot.Position / (double)(slot.Count - 1)); break;
            case "rotatingColorway": rgb = slot.Count <= 1 ? phase % 2 == 0 ? primary : secondary : Blend(primary, secondary, 1 - Math.Abs((slot.Position + phase) % slot.Count / (double)slot.Count * 2 - 1)); break;
            case "rainbow":
                double h = (slot.Count <= 1 ? slot.Index / 8d : slot.Position / (double)Math.Max(2, slot.Count)) * 6;
                int i = (int)Math.Floor(h); double f = h - i, p = 1 - .9, q = 1 - .9 * f, t = 1 - .9 * (1 - f);
                rgb = (i % 6) switch { 0 => (1, t, p), 1 => (q, 1, p), 2 => (p, 1, t), 3 => (p, q, 1), 4 => (t, p, 1), _ => (1, p, q) }; break;
        }
        static int Scale(double value, double factor) => (int)Math.Round(Math.Clamp(value, 0, 1) * Math.Clamp(factor, 0, 1) * 255, MidpointRounding.AwayFromZero);
        return $"#{Scale(rgb.R, style.Intensity):X2}{Scale(rgb.G, style.Intensity):X2}{Scale(rgb.B, style.Intensity):X2}";
    }
}

internal sealed record LocalLightScene(string State, SignalPrograms Programs, LightAgent?[] ProSlots, LightAgent?[] DotSlots, string? Error = null);

internal sealed class LocalLightScenes
{
    private readonly LightAllocator pro = new(), dot = new();
    private string? allocatorKey;
    internal LocalLightScene Compile(SignalSettings settings, IReadOnlyList<LightAgent> visible, DateTimeOffset now)
    {
        string mode = settings.Presentation.DisplayMode; var profile = settings.Profiles.Selected;
        string key = $"{profile.Id}:{profile.Strategy}:{mode}";
        if (key != allocatorKey) { pro.Reset(); dot.Reset(); allocatorKey = key; }
        var agents = AgentLighting.ForMode(visible, mode);
        string state = agents.OrderBy(a => a.Priority).ThenByDescending(a => a.UpdatedAt).FirstOrDefault()?.State ?? "idle";
        try
        {
            var a = AgentLighting.Compile(profile, agents, pro, 8, now); var b = AgentLighting.Compile(profile, agents, dot, 2, now);
            var programs = agents.Length == 1 ? settings.Override(state) ?? new(a.Program, b.Program) : new(a.Program, b.Program);
            return new(state, programs, a.Slots, b.Slots);
        }
        catch (InvalidDataException)
        {
            // A legal profile can exceed firmware bounds when several animations combine.
            // Keep the sampler/publisher alive and explicitly turn this scene off.
            return new("idle", new("off", "off"), new LightAgent?[8], new LightAgent?[2],
                "This combination exceeds the light program limits. Choose a simpler motion or Simple display.");
        }
    }
}
