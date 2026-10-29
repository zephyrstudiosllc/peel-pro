using System.Text;
namespace Peel.Linux.Host;
internal sealed record LinuxHostServiceIdentity(string ComputerName,string ControlServiceName,string PairServiceName)
{
    internal static LinuxHostServiceIdentity Validate(string name,string control,string pair)
    {
        if (!LinuxHostWire.Text(name,256) || !LinuxHostWire.Text(control,63) || !LinuxHostWire.Text(pair,63)
            || Encoding.UTF8.GetByteCount(control)>63 || Encoding.UTF8.GetByteCount(pair)>63 || control==pair) throw new InvalidDataException("Invalid persisted service names.");
        return new(name,control,pair);
    }
    internal static string ShortName(string name,int budget)
    {
        var result = new StringBuilder(); int bytes=0;
        foreach (var rune in name.EnumerateRunes()) { if (bytes+rune.Utf8SequenceLength>budget) break; result.Append(rune.ToString()); bytes+=rune.Utf8SequenceLength; }
        return result.ToString();
    }
}
