using System.Text;
using System.Text.Json;
using Peel.Windows.Protocol;

namespace Peel.Windows.Protocol.Tests;

internal static partial class Program
{
    private const string SourceRequestId = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9";

    private static void SourceMediaContract()
    {
        Equal("source-media-keys-v1", SourceMediaProtocol.MediaKeysCapability);
        Equal("source-volume-v1", SourceMediaProtocol.VolumeCapability);
        Equal(1, SourceMediaProtocol.Version);
        Equal(4096, SourceMediaProtocol.MaximumLineBytes);
        Equal(8, SourceMediaProtocol.ClientMaximumPending);
        Equal(TimeSpan.FromSeconds(3), SourceMediaProtocol.ClientTimeout);
        Equal(5, SourceMediaProtocol.MediaActionsPerSecond);

        // Outbound shapes: exact field names, no extras, nulls omitted like Swift optionals.
        Guid id = Guid.Parse(SourceRequestId);
        AssertFields(SourceMediaCommandMessage.Create(id, "pair-1", 7, SourceMediaAction.PreviousTrack),
            ("type", "sourceMediaCommand"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("action", "previousTrack"));
        AssertFields(SourceVolumeQueryMessage.Create(id, "pair-1", 7, SourceVolumeScope.PeelStream),
            ("type", "sourceVolumeQuery"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("scope", "peelStream"));
        AssertFields(SourceVolumeSetMessage.Create(id, "pair-1", 7, SourceVolumeScope.SystemOutput, null, true),
            ("type", "sourceVolumeSet"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("scope", "systemOutput"), ("muted", true));
        AssertFields(SourceMediaAckMessage.Create(SourceRequestId, "pair-1", 7, SourceMediaStatus.Applied),
            ("type", "sourceMediaAck"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("status", "applied"));
        AssertFields(SourceMediaAckMessage.Create(SourceRequestId, "pair-1", 7, SourceMediaStatus.Denied, SourceMediaReason.ControlOff),
            ("type", "sourceMediaAck"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("status", "denied"), ("reason", "controlOff"));
        AssertFields(SourceVolumeStateMessage.Unsupported(SourceRequestId, "pair-1", 7, SourceVolumeScope.SystemOutput, 42),
            ("type", "sourceVolumeState"), ("version", 1), ("requestId", SourceRequestId), ("pairingId", "pair-1"),
            ("windowId", 7), ("scope", "systemOutput"), ("supported", false), ("canSetVolume", false),
            ("canSetMute", false), ("sequence", 42), ("reason", "scopeUnsupported"));
        Throws<ArgumentException>(() => SourceVolumeSetMessage.Create(id, "p", 1, SourceVolumeScope.PeelStream, null, null));
        Throws<ArgumentOutOfRangeException>(() => SourceVolumeSetMessage.Create(id, "p", 1, SourceVolumeScope.PeelStream, 1.5, null));
        Throws<ArgumentOutOfRangeException>(() => SourceVolumeSetMessage.Create(id, "p", 1, SourceVolumeScope.PeelStream, double.NaN, null));

        // Every closed enum round-trips exactly; wire names are case-sensitive.
        foreach (var action in Enum.GetValues<SourceMediaAction>())
            True(SourceMediaProtocol.TryParseAction(SourceMediaProtocol.WireName(action), out var parsed) && parsed == action);
        foreach (var reason in Enum.GetValues<SourceMediaReason>())
            True(SourceMediaProtocol.TryParseReason(SourceMediaProtocol.WireName(reason), out var parsed) && parsed == reason);
        True(!SourceMediaProtocol.TryParseAction("PlayPause", out _));
        True(!SourceMediaProtocol.TryParseScope("both", out _));

        // A Swift-encoded command (different key order, extra unknown key) decodes and validates.
        var swift = Read<SourceMediaCommandMessage>(
            $$"""{"windowId":4294967295,"action":"playPause","type":"sourceMediaCommand","pairingId":"pair-1","future":true,"requestId":"{{SourceRequestId.ToLowerInvariant()}}","version":1}""");
        var valid = swift.Check();
        True(valid.IsValid && valid.Value == SourceMediaAction.PlayPause);
        True(Read<SourceMediaRequestIdentityMessage>(
            $$"""{"type":"sourceMediaCommand","requestId":"{{SourceRequestId}}","pairingId":"pair-1","windowId":0}""").IsValid,
            "Window 0 is a valid identity that the source answers as a stale stream.");

        // Identity: request ID shape, pairing bytes, NUL and lone surrogates, missing window.
        foreach (string bad in new[] { "", "0A1B2C3D4E5F60718293A4B5C6D7E8F9", "{0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9}",
                     "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8FG", "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F99", "0A1B2C3D_4E5F-6071-8293-A4B5C6D7E8F9",
                     "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F٩" })
            True(!SourceMediaProtocol.IsRequestId(bad), "Rejected request ID " + bad);
        True(SourceMediaProtocol.IsPairingId(new string('é', 128)), "256 UTF-8 bytes are allowed.");
        True(!SourceMediaProtocol.IsPairingId(new string('é', 128) + "a"));
        True(!SourceMediaProtocol.IsPairingId("pair\0id"));
        True(!SourceMediaProtocol.IsPairingId("pair\uD800"));
        True(!SourceMediaProtocol.IsPairingId(""));
        True(!Read<SourceMediaRequestIdentityMessage>(
            $$"""{"type":"sourceMediaCommand","requestId":"{{SourceRequestId}}","pairingId":"pair-1"}""").IsValid);
        True(!Read<SourceMediaRequestIdentityMessage>(
            $$"""{"type":"sourceMediaAck","requestId":"{{SourceRequestId}}","pairingId":"pair-1","windowId":1}""").IsValid);
        foreach (string window in new[] { "-1", "4294967296", "1.5", "\"1\"" })
            Throws<JsonException>(() => Read<SourceMediaRequestIdentityMessage>(
                $$"""{"type":"sourceMediaCommand","requestId":"{{SourceRequestId}}","pairingId":"p","windowId":{{window}}}"""));
        Throws<JsonException>(() => Read<SourceVolumeSetMessage>(
            $$"""{"type":"sourceVolumeSet","version":1,"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,"scope":"peelStream","volume":NaN}"""));

        // Refusal semantics match the Swift checks: invalid vs unsupported vs scopeUnsupported.
        AssertRefusal(Command("playPause", "\"version\":2"), SourceMediaStatus.Unsupported, null);
        AssertRefusal(Command("stop", "\"version\":1"), SourceMediaStatus.Unsupported, null);
        AssertRefusal(Command(new string('a', 33), "\"version\":1"), SourceMediaStatus.Invalid, null);
        AssertRefusal(Command("playPause", "\"other\":1"), SourceMediaStatus.Invalid, null);
        AssertRefusal(Query("both", "\"version\":1"), SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported);
        AssertRefusal(Query("peelStream", "\"version\":3"), SourceMediaStatus.Unsupported, null);
        AssertRefusal(Set("\"scope\":\"peelStream\""), SourceMediaStatus.Invalid, null);
        AssertRefusal(Set("\"scope\":\"peelStream\",\"volume\":1.0000001"), SourceMediaStatus.Invalid, null);
        AssertRefusal(Set("\"scope\":\"peelStream\",\"volume\":-0.5"), SourceMediaStatus.Invalid, null);
        AssertRefusal(Set("\"scope\":\"later\",\"muted\":false"), SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported);
        var change = Read<SourceVolumeSetMessage>(SetJson("\"scope\":\"systemOutput\",\"volume\":0,\"muted\":false")).Check();
        True(change.IsValid && change.Value == new SourceVolumeChange(SourceVolumeScope.SystemOutput, 0, false));

        // Replies: unknown status is rejected, unknown reason reads as null, bounded state invariants.
        string ack = $$"""{"type":"sourceMediaAck","version":1,"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,"status":"applied","reason":"fromTheFuture"}""";
        True(Read<SourceMediaAckMessage>(ack).TryParse(out var status, out var unknownReason) &&
            status == SourceMediaStatus.Applied && unknownReason is null);
        True(!Read<SourceMediaAckMessage>(ack.Replace("\"applied\"", "\"queued\"")).TryParse(out _, out _));
        True(!Read<SourceMediaAckMessage>(ack.Replace("\"version\":1", "\"version\":2")).TryParse(out _, out _));
        True(!Read<SourceMediaAckMessage>(ack.Replace(",\"version\":1", "")).TryParse(out _, out _), "A missing version is never defaulted.");
        True(SourceVolumeStateMessage.Unsupported(SourceRequestId, "p", 1, SourceVolumeScope.PeelStream, 1).IsValid);
        True(SourceVolumeStateMessage.Create(null, "p", 1, SourceVolumeScope.PeelStream, true, true, true, 0.25, false, 2).IsValid,
            "A future unsolicited state may omit requestId.");
        string state = $$"""{"type":"sourceVolumeState","version":1,"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,"scope":"peelStream","supported":false,"canSetVolume":false,"canSetMute":false,"sequence":3}""";
        True(Read<SourceVolumeStateMessage>(state).IsValid);
        True(!Read<SourceVolumeStateMessage>(state.Replace("\"sequence\":3", "\"sequence\":3,\"muted\":true")).IsValid,
            "Unsupported state never carries a value.");
        True(!Read<SourceVolumeStateMessage>(state.Replace(",\"sequence\":3", "")).IsValid);
        True(!Read<SourceVolumeStateMessage>(state.Replace("\"supported\":false", "\"supported\":true")
            .Replace("\"sequence\":3", "\"sequence\":3,\"volume\":1.5")).IsValid);
        // Unsupported construction drops any supplied value rather than reporting it.
        var unsupported = SourceVolumeStateMessage.Create(SourceRequestId, "p", 1, SourceVolumeScope.PeelStream, false, true, true, 0.5, true, 9);
        True(unsupported.IsValid && unsupported.Volume is null && unsupported.Muted is null && unsupported.CanSetMute == false);
    }

    private static string Command(string action, string versionField) =>
        $$"""{"type":"sourceMediaCommand",{{versionField}},"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,"action":"{{action}}"}""";

    private static string Query(string scope, string versionField) =>
        $$"""{"type":"sourceVolumeQuery",{{versionField}},"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,"scope":"{{scope}}"}""";

    private static string SetJson(string fields) =>
        $$"""{"type":"sourceVolumeSet","version":1,"requestId":"{{SourceRequestId}}","pairingId":"p","windowId":1,{{fields}}}""";

    private static string Set(string fields) => SetJson(fields);

    private static void AssertRefusal(string json, SourceMediaStatus status, SourceMediaReason? reason)
    {
        (bool valid, SourceMediaStatus? refused, SourceMediaReason? refusedReason) = PeelJson.ReadEnvelope(Encoding.UTF8.GetBytes(json)).Type switch
        {
            SourceMediaProtocol.CommandType => Refusal(Read<SourceMediaCommandMessage>(json).Check()),
            SourceMediaProtocol.VolumeQueryType => Refusal(Read<SourceVolumeQueryMessage>(json).Check()),
            _ => Refusal(Read<SourceVolumeSetMessage>(json).Check()),
        };
        True(!valid && refused == status && refusedReason == reason, $"Unexpected refusal for {json}");
    }

    private static (bool, SourceMediaStatus?, SourceMediaReason?) Refusal<T>(SourceMediaCheck<T> check) where T : struct =>
        (check.IsValid, check.RefusalStatus, check.RefusalReason);

    private static T Read<T>(string json) => PeelJson.Deserialize<T>(Encoding.UTF8.GetBytes(json));

    private static void AssertFields(object message, params (string Name, object Value)[] expected)
    {
        using var document = JsonDocument.Parse(PeelJson.SerializeString(message));
        var actual = document.RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone(), StringComparer.Ordinal);
        Equal(expected.Length, actual.Count);
        foreach (var (name, value) in expected)
        {
            True(actual.TryGetValue(name, out var element), "Missing wire field " + name);
            switch (value)
            {
                case string text: Equal(text, element.GetString()); break;
                case bool flag: Equal(flag, element.GetBoolean()); break;
                case int number: Equal((long)number, element.GetInt64()); break;
                default: throw new InvalidOperationException("Unsupported fixture value.");
            }
        }
    }
}
