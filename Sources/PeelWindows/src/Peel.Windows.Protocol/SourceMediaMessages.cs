using System.Text;
using System.Text.Json.Serialization;

namespace Peel.Windows.Protocol;

/// <summary>
/// Source media protocol v1, wire-identical to the Host and Apple PeelSourceMediaMessages.swift.
/// Controls act on the streamed source computer, never on the receiver.
/// <c>source-media-keys-v1</c> is advertised only by a source that posts OS media keys;
/// <c>source-volume-v1</c> only once a volume backend for a stated scope exists.
/// </summary>
public static class SourceMediaProtocol
{
    public const int Version = 1;
    public const string MediaKeysCapability = "source-media-keys-v1";
    public const string VolumeCapability = "source-volume-v1";

    public const string CommandType = "sourceMediaCommand";
    public const string VolumeQueryType = "sourceVolumeQuery";
    public const string VolumeSetType = "sourceVolumeSet";
    public const string AckType = "sourceMediaAck";
    public const string VolumeStateType = "sourceVolumeState";

    public const int MaximumLineBytes = 4096;
    public const int MaximumPairingIdBytes = 256;
    public const int MaximumEnumBytes = 32;

    /// <summary>Per control session, sliding one-second window.</summary>
    public const int MediaActionsPerSecond = 5;
    public const int VolumeSetsPerSecond = 20;
    public const int VolumeQueriesPerSecond = 10;

    public const int ClientMaximumPending = 8;
    public static TimeSpan ClientTimeout { get; } = TimeSpan.FromSeconds(3);

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static bool IsRequestType(string? type) =>
        type is CommandType or VolumeQueryType or VolumeSetType;

    /// <summary>Exact ASCII 8-4-4-4-12 hexadecimal UUID (36 bytes); either hex case.</summary>
    public static bool IsRequestId(string? value)
    {
        if (value is not { Length: 36 }) return false;
        for (int index = 0; index < 36; index++)
        {
            char c = value[index];
            if (index is 8 or 13 or 18 or 23)
            {
                if (c != '-') return false;
            }
            else if (!char.IsAsciiHexDigit(c))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>1...256 UTF-8 bytes without NUL; lone surrogates are not valid UTF-8.</summary>
    public static bool IsPairingId(string? value)
    {
        if (string.IsNullOrEmpty(value) || value.Contains('\0')) return false;
        try { return StrictUtf8.GetByteCount(value) <= MaximumPairingIdBytes; }
        catch (EncoderFallbackException) { return false; }
    }

    public static bool IsEnumString(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        try { return StrictUtf8.GetByteCount(value) <= MaximumEnumBytes; }
        catch (EncoderFallbackException) { return false; }
    }

    public static bool IsVolume(double value) => double.IsFinite(value) && value >= 0 && value <= 1;

    public static string WireName(SourceMediaAction value) => value switch
    {
        SourceMediaAction.PlayPause => "playPause",
        SourceMediaAction.PreviousTrack => "previousTrack",
        SourceMediaAction.NextTrack => "nextTrack",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static string WireName(SourceVolumeScope value) => value switch
    {
        SourceVolumeScope.SystemOutput => "systemOutput",
        SourceVolumeScope.PeelStream => "peelStream",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static string WireName(SourceMediaStatus value) => value switch
    {
        SourceMediaStatus.Applied => "applied",
        SourceMediaStatus.Unsupported => "unsupported",
        SourceMediaStatus.Denied => "denied",
        SourceMediaStatus.Failed => "failed",
        SourceMediaStatus.Stale => "stale",
        SourceMediaStatus.Invalid => "invalid",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    public static string WireName(SourceMediaReason value) => value switch
    {
        SourceMediaReason.ControlOff => "controlOff",
        SourceMediaReason.NotVisible => "notVisible",
        SourceMediaReason.Locked => "locked",
        SourceMediaReason.AccessibilityMissing => "accessibilityMissing",
        SourceMediaReason.ScopeUnsupported => "scopeUnsupported",
        SourceMediaReason.FixedVolume => "fixedVolume",
        SourceMediaReason.NoOutputDevice => "noOutputDevice",
        SourceMediaReason.StaleStream => "staleStream",
        SourceMediaReason.RateLimited => "rateLimited",
        SourceMediaReason.OsRefused => "osRefused",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    // Ordinal, exact-case closed sets. Unknown strings are refused, never guessed.
    public static bool TryParseAction(string? value, out SourceMediaAction action) =>
        TryParse(value, Enum.GetValues<SourceMediaAction>(), WireName, out action);

    public static bool TryParseScope(string? value, out SourceVolumeScope scope) =>
        TryParse(value, Enum.GetValues<SourceVolumeScope>(), WireName, out scope);

    public static bool TryParseStatus(string? value, out SourceMediaStatus status) =>
        TryParse(value, Enum.GetValues<SourceMediaStatus>(), WireName, out status);

    public static bool TryParseReason(string? value, out SourceMediaReason reason) =>
        TryParse(value, Enum.GetValues<SourceMediaReason>(), WireName, out reason);

    private static bool TryParse<T>(string? value, T[] values, Func<T, string> name, out T parsed)
        where T : struct, Enum
    {
        foreach (T candidate in values)
        {
            if (StringComparer.Ordinal.Equals(value, name(candidate)))
            {
                parsed = candidate;
                return true;
            }
        }
        parsed = default;
        return false;
    }
}

public enum SourceMediaAction { PlayPause, PreviousTrack, NextTrack }

public enum SourceVolumeScope
{
    /// <summary>The source computer's actual default output device volume/mute.</summary>
    SystemOutput,
    /// <summary>Only the source's Peel audio stream gain/mute.</summary>
    PeelStream,
}

public enum SourceMediaStatus
{
    /// <summary>The source OS accepted the effect. For media keys: events posted, not playback confirmed.</summary>
    Applied,
    Unsupported,
    Denied,
    Failed,
    Stale,
    Invalid,
}

public enum SourceMediaReason
{
    ControlOff,
    NotVisible,
    Locked,
    AccessibilityMissing,
    ScopeUnsupported,
    FixedVolume,
    NoOutputDevice,
    StaleStream,
    RateLimited,
    OsRefused,
}

/// <summary>Validation outcome of an identity-valid request: a value or a bounded refusal.</summary>
public readonly record struct SourceMediaCheck<T>(T Value, SourceMediaStatus? RefusalStatus, SourceMediaReason? RefusalReason)
    where T : struct
{
    public bool IsValid => RefusalStatus is null;
    public static SourceMediaCheck<T> Valid(T value) => new(value, null, null);
    public static SourceMediaCheck<T> Refused(SourceMediaStatus status, SourceMediaReason? reason = null) =>
        new(default, status, reason);
}

/// <summary>Minimal identity every request must carry before any reply is possible. Invalid identity: no reply.</summary>
public sealed record SourceMediaRequestIdentityMessage(
    [property: JsonPropertyName("type")] string? Type,
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId)
{
    [JsonIgnore]
    public bool IsValid =>
        SourceMediaProtocol.IsRequestType(Type) &&
        SourceMediaProtocol.IsRequestId(RequestId) &&
        SourceMediaProtocol.IsPairingId(PairingId) &&
        WindowId is not null;
}

public readonly record struct SourceVolumeChange(SourceVolumeScope Scope, double? Volume, bool? Muted);

// Client -> source

public sealed record SourceMediaCommandMessage(
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId,
    // Raw, so an unknown future action decodes and is refused as unsupported.
    [property: JsonPropertyName("action")] string? Action,
    [property: JsonPropertyName("version")] int? Version,
    [property: JsonPropertyName("type")] string? Type)
{
    public static SourceMediaCommandMessage Create(Guid requestId, string pairingId, uint windowId, SourceMediaAction action) =>
        new(requestId.ToString("D").ToUpperInvariant(), pairingId, windowId, SourceMediaProtocol.WireName(action),
            SourceMediaProtocol.Version, SourceMediaProtocol.CommandType);

    public SourceMediaCheck<SourceMediaAction> Check()
    {
        if (Type != SourceMediaProtocol.CommandType || Version is null || WindowId is null ||
            !SourceMediaProtocol.IsRequestId(RequestId) || !SourceMediaProtocol.IsPairingId(PairingId) ||
            !SourceMediaProtocol.IsEnumString(Action))
            return SourceMediaCheck<SourceMediaAction>.Refused(SourceMediaStatus.Invalid);
        if (Version != SourceMediaProtocol.Version || !SourceMediaProtocol.TryParseAction(Action, out var action))
            return SourceMediaCheck<SourceMediaAction>.Refused(SourceMediaStatus.Unsupported);
        return SourceMediaCheck<SourceMediaAction>.Valid(action);
    }
}

public sealed record SourceVolumeQueryMessage(
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId,
    [property: JsonPropertyName("scope")] string? Scope,
    [property: JsonPropertyName("version")] int? Version,
    [property: JsonPropertyName("type")] string? Type)
{
    public static SourceVolumeQueryMessage Create(Guid requestId, string pairingId, uint windowId, SourceVolumeScope scope) =>
        new(requestId.ToString("D").ToUpperInvariant(), pairingId, windowId, SourceMediaProtocol.WireName(scope),
            SourceMediaProtocol.Version, SourceMediaProtocol.VolumeQueryType);

    public SourceMediaCheck<SourceVolumeScope> Check()
    {
        if (Type != SourceMediaProtocol.VolumeQueryType || Version is null || WindowId is null ||
            !SourceMediaProtocol.IsRequestId(RequestId) || !SourceMediaProtocol.IsPairingId(PairingId) ||
            !SourceMediaProtocol.IsEnumString(Scope))
            return SourceMediaCheck<SourceVolumeScope>.Refused(SourceMediaStatus.Invalid);
        if (Version != SourceMediaProtocol.Version)
            return SourceMediaCheck<SourceVolumeScope>.Refused(SourceMediaStatus.Unsupported);
        if (!SourceMediaProtocol.TryParseScope(Scope, out var scope))
            return SourceMediaCheck<SourceVolumeScope>.Refused(SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported);
        return SourceMediaCheck<SourceVolumeScope>.Valid(scope);
    }
}

public sealed record SourceVolumeSetMessage(
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId,
    [property: JsonPropertyName("scope")] string? Scope,
    // Finite 0...1. Out-of-range values are invalid, never clamped.
    [property: JsonPropertyName("volume")] double? Volume,
    [property: JsonPropertyName("muted")] bool? Muted,
    [property: JsonPropertyName("version")] int? Version,
    [property: JsonPropertyName("type")] string? Type)
{
    public static SourceVolumeSetMessage Create(Guid requestId, string pairingId, uint windowId, SourceVolumeScope scope,
        double? volume, bool? muted)
    {
        if (volume is null && muted is null) throw new ArgumentException("A volume or mute value is required.");
        if (volume is { } v && !SourceMediaProtocol.IsVolume(v)) throw new ArgumentOutOfRangeException(nameof(volume));
        return new(requestId.ToString("D").ToUpperInvariant(), pairingId, windowId, SourceMediaProtocol.WireName(scope),
            volume, muted, SourceMediaProtocol.Version, SourceMediaProtocol.VolumeSetType);
    }

    public SourceMediaCheck<SourceVolumeChange> Check()
    {
        if (Type != SourceMediaProtocol.VolumeSetType || Version is null || WindowId is null ||
            !SourceMediaProtocol.IsRequestId(RequestId) || !SourceMediaProtocol.IsPairingId(PairingId) ||
            !SourceMediaProtocol.IsEnumString(Scope) || Volume is null && Muted is null ||
            Volume is { } volume && !SourceMediaProtocol.IsVolume(volume))
            return SourceMediaCheck<SourceVolumeChange>.Refused(SourceMediaStatus.Invalid);
        if (Version != SourceMediaProtocol.Version)
            return SourceMediaCheck<SourceVolumeChange>.Refused(SourceMediaStatus.Unsupported);
        if (!SourceMediaProtocol.TryParseScope(Scope, out var scope))
            return SourceMediaCheck<SourceVolumeChange>.Refused(SourceMediaStatus.Unsupported, SourceMediaReason.ScopeUnsupported);
        return SourceMediaCheck<SourceVolumeChange>.Valid(new(scope, Volume, Muted));
    }
}

// Source -> client, targeted only to the requesting current paired control session.

public sealed record SourceMediaAckMessage(
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId,
    [property: JsonPropertyName("status")] string? Status,
    [property: JsonPropertyName("reason")] string? Reason,
    [property: JsonPropertyName("version")] int? Version,
    [property: JsonPropertyName("type")] string? Type)
{
    public static SourceMediaAckMessage Create(string requestId, string pairingId, uint windowId,
        SourceMediaStatus status, SourceMediaReason? reason = null) =>
        new(requestId, pairingId, windowId, SourceMediaProtocol.WireName(status),
            reason is { } r ? SourceMediaProtocol.WireName(r) : null, SourceMediaProtocol.Version, SourceMediaProtocol.AckType);

    /// <summary>Client-side check. Unknown status: rejected. Unknown reason reads as null.</summary>
    public bool TryParse(out SourceMediaStatus status, out SourceMediaReason? reason)
    {
        reason = null;
        if (Type != SourceMediaProtocol.AckType || Version != SourceMediaProtocol.Version || WindowId is null ||
            !SourceMediaProtocol.IsRequestId(RequestId) || !SourceMediaProtocol.IsPairingId(PairingId) ||
            !SourceMediaProtocol.TryParseStatus(Status, out status))
        {
            status = default;
            return false;
        }
        if (SourceMediaProtocol.TryParseReason(Reason, out var parsed)) reason = parsed;
        return true;
    }
}

/// <summary>Actual source state, never an optimistic echo. Values the source cannot read stay null.</summary>
public sealed record SourceVolumeStateMessage(
    // Present on every query/set response; null only for a future unsolicited update.
    [property: JsonPropertyName("requestId")] string? RequestId,
    [property: JsonPropertyName("pairingId")] string? PairingId,
    [property: JsonPropertyName("windowId")] uint? WindowId,
    [property: JsonPropertyName("scope")] string? Scope,
    [property: JsonPropertyName("supported")] bool? Supported,
    [property: JsonPropertyName("canSetVolume")] bool? CanSetVolume,
    [property: JsonPropertyName("canSetMute")] bool? CanSetMute,
    [property: JsonPropertyName("volume")] double? Volume,
    [property: JsonPropertyName("muted")] bool? Muted,
    // Monotonic per source process.
    [property: JsonPropertyName("sequence")] ulong? Sequence,
    [property: JsonPropertyName("reason")] string? Reason,
    [property: JsonPropertyName("version")] int? Version,
    [property: JsonPropertyName("type")] string? Type)
{
    public static SourceVolumeStateMessage Create(string? requestId, string pairingId, uint windowId, SourceVolumeScope scope,
        bool supported, bool canSetVolume, bool canSetMute, double? volume, bool? muted, ulong sequence,
        SourceMediaReason? reason = null) =>
        new(requestId, pairingId, windowId, SourceMediaProtocol.WireName(scope), supported,
            supported && canSetVolume, supported && canSetMute,
            supported && volume is { } v && SourceMediaProtocol.IsVolume(v) ? v : null,
            supported ? muted : null, sequence, reason is { } r ? SourceMediaProtocol.WireName(r) : null,
            SourceMediaProtocol.Version, SourceMediaProtocol.VolumeStateType);

    /// <summary>Unsupported scope state: everything unreadable stays null.</summary>
    public static SourceVolumeStateMessage Unsupported(string requestId, string pairingId, uint windowId,
        SourceVolumeScope scope, ulong sequence, SourceMediaReason reason = SourceMediaReason.ScopeUnsupported) =>
        Create(requestId, pairingId, windowId, scope, false, false, false, null, null, sequence, reason);

    /// <summary>Client-side check of a decoded state. Never part of the wire shape.</summary>
    [JsonIgnore]
    public bool IsValid
    {
        get
        {
            if (Type != SourceMediaProtocol.VolumeStateType || Version != SourceMediaProtocol.Version ||
                RequestId is not null && !SourceMediaProtocol.IsRequestId(RequestId) ||
                !SourceMediaProtocol.IsPairingId(PairingId) || WindowId is null ||
                !SourceMediaProtocol.TryParseScope(Scope, out _) ||
                Supported is null || CanSetVolume is null || CanSetMute is null || Sequence is null ||
                Volume is { } volume && !SourceMediaProtocol.IsVolume(volume))
                return false;
            return Supported == true || CanSetVolume == false && CanSetMute == false && Volume is null && Muted is null;
        }
    }
}
