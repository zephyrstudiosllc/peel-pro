using Peel.Linux;
static void Require(bool value, string name) { if (!value) throw new Exception(name); }
static void Rejected(Action action) { try { action(); } catch (InvalidDataException) { return; } throw new Exception("Malformed codec data accepted."); }
Require(LinuxDecoder.ToAnnexB(new byte[] { 0,0,0,2,0x65,0x01,0,0,0,1,0x06 },4).SequenceEqual(new byte[] {0,0,0,1,0x65,0x01,0,0,0,1,0x06}),"AVCC4 multipart");
Require(LinuxDecoder.ToAnnexB(new byte[] {0,2,0x65,0x02},2).SequenceEqual(new byte[] {0,0,0,1,0x65,0x02}),"AVCC2");
Require(LinuxDecoder.ToAnnexB(new byte[] {1,0x65},1).SequenceEqual(new byte[] {0,0,0,1,0x65}),"AVCC1");
Rejected(() => LinuxDecoder.ToAnnexB(new byte[] {0,0,0,0},4));
Rejected(() => LinuxDecoder.ToAnnexB(new byte[] {0,0,0,8,0x65},4));
Rejected(() => LinuxDecoder.ToAnnexB(new byte[] {0,0,0},4));
Rejected(() => LinuxDecoder.ToAnnexB(new byte[] {1,0x65},3));
Require(LinuxDecoder.Nanoseconds(90000,90000)==1_000_000_000,"Timescale conversion");
Require(LinuxDecoder.Nanoseconds(long.MaxValue,uint.MaxValue)>0,"Wide intermediate conversion");
Console.WriteLine("Codec boundary checks passed. No native capture, decode, GUI, TLS or Linux parity is proved by these pure checks.");
if (await ReceiverMediaChecks.RunAsync() != 0) return 1;
return 0;
