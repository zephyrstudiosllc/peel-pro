using System.Collections.ObjectModel;
using System.IO;
using Peel.Windows.Client.ViewModels;

namespace Peel.Windows.Client.Utilities;
public sealed partial class CommandCenterViewModel
{
    private readonly SidePulseOutput proOutput = new(), dotOutput = new();
    private SidePulseDevice? selectedPro, selectedDot;
    private double lightBrightness = 1;
    private string hardwareScanStatus = "Connect SidePulse by USB, then scan for its program volume.";
    public ObservableCollection<SidePulseDevice> ProDevices { get; } = new();
    public ObservableCollection<SidePulseDevice> DotDevices { get; } = new();
    public SidePulseDevice? SelectedPro { get => selectedPro; set => SetProperty(ref selectedPro, value); }
    public SidePulseDevice? SelectedDot { get => selectedDot; set => SetProperty(ref selectedDot, value); }
    public double LightBrightness { get => lightBrightness; set { if (double.IsFinite(value) && SetProperty(ref lightBrightness, Math.Clamp(value, 0, 1))) RefreshHardwareOutput(); } }
    public string HardwareScanStatus { get => hardwareScanStatus; private set => SetProperty(ref hardwareScanStatus, value); }
    public string ProOutputStatus => proOutput.Status;
    public string DotOutputStatus => dotOutput.Status;
    public AsyncCommand ScanLightDevicesCommand { get; private set; } = null!;
    public AsyncCommand StartProOutputCommand { get; private set; } = null!;
    public AsyncCommand StartDotOutputCommand { get; private set; } = null!;
    public AsyncCommand StopLightOutputCommand { get; private set; } = null!;
    private void InitializeHardwareOutput()
    {
        ScanLightDevicesCommand = new(async () =>
        {
            try
            {
                var devices = await Task.Run(SidePulseDevice.Discover, lifetime.Token);
                if (lifetime.IsCancellationRequested) return;
                var pro = SelectedPro; var dot = SelectedDot;
                ProDevices.Clear(); DotDevices.Clear();
                foreach (var device in devices) (device.Kind == "dot" ? DotDevices : ProDevices).Add(device);
                SelectedPro = ProDevices.FirstOrDefault(d => d == pro) ?? ProDevices.FirstOrDefault();
                SelectedDot = DotDevices.FirstOrDefault(d => d == dot) ?? DotDevices.FirstOrDefault();
                HardwareScanStatus = devices.Count == 0 ? "No SidePulse USB program volumes found." : $"Found {devices.Count} device(s). Select a device and start its output.";
            }
            catch (OperationCanceledException) { }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { HardwareScanStatus = "Could not scan USB devices: " + e.Message; }
        });
        StartProOutputCommand = new(() => StartHardwareOutputAsync(proOutput, SelectedPro));
        StartDotOutputCommand = new(() => StartHardwareOutputAsync(dotOutput, SelectedDot));
        StopLightOutputCommand = new(StopHardwareOutputAsync);
    }
    private async Task StartHardwareOutputAsync(SidePulseOutput output, SidePulseDevice? device)
    {
        if (device is null) { HardwareScanStatus = "Scan and select a connected device first."; return; }
        try { RefreshHardwareOutput(); await output.StartAsync(device, lifetime.Token); }
        catch (Exception e) when (e is IOException or InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or OperationCanceledException)
        { HardwareScanStatus = "Could not start USB output: " + e.Message; }
        RefreshHardwareOutput();
    }
    private void RefreshHardwareOutput()
    {
        proOutput.Update(ActivityProgram, ActivityDotProgram, ActivityValidUntil, LightBrightness, LightMode == "Flashlight");
        dotOutput.Update(ActivityProgram, ActivityDotProgram, ActivityValidUntil, LightBrightness, LightMode == "Flashlight");
        OnPropertyChanged(nameof(ProOutputStatus)); OnPropertyChanged(nameof(DotOutputStatus));
    }
    public void CancelHardwareOutput() { proOutput.Cancel(); dotOutput.Cancel(); }
    private async Task StopHardwareOutputAsync()
    { CancelHardwareOutput(); await Task.WhenAll(proOutput.StopAsync(), dotOutput.StopAsync()); RefreshHardwareOutput(); }
}
