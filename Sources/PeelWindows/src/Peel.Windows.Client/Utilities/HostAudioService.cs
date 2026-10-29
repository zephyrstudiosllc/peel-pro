using Peel.Windows.Host.Audio;

namespace Peel.Windows.Client.Utilities;

internal static class HostAudioService
{
    internal static HostAudioSharing Shared { get; } = new();
}
