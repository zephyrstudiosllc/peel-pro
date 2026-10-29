import SwiftUI

struct AboutPeelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var didCopyHostLink = false

    private let peelHostDownloadURL = URL(string: "https://peelpro.app")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {


                        VStack(spacing: 14) {
                            TutorialStepRow(
                                number: "1",
                                title: "Download",
                                message: "Install Peel Pro and leave it running."
                            ) {
                                
                                HStack{
                                    Button {
                                        copyPeelHostDownloadLink()
                                    } label: {
                                        Label(didCopyHostLink ? "Copied" : "Copy",
                                              systemImage: didCopyHostLink ? "checkmark.circle.fill" : "doc.on.doc")
                                        .frame(maxWidth: 80)
                                    }
                                    .buttonStyle(.bordered)
                                    Spacer()
                                    
                                    Button {
                                        openURL(peelHostDownloadURL)
                                    } label: {
                                        Text("peelpro.app")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.blue)
                                            .underline()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open the Peel Pro download page")
                                    
                                }
                            }
                                

                            TutorialStepRow(
                                number: "2",
                                title: "Pair",
                                message: "Tap pair, then enter the pairing code from Peel Pro."
                            )

                            TutorialStepRow(
                                number: "3",
                                title: "Connect",
                                message: "Tap connect, and you're all set."
                            )
                        }

                        quickControls
                    }
                    .padding(.horizontal, 24)
                }

                Divider()

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(20)
            }
            .navigationTitle("Info")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif

            
        }
    }



    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
          
            /*
            Text("Status")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack{
                    StatusDot(status: .active)
                    ControlTipRow(title: "Active", message: "Input available")
                }
                HStack{
                    StatusDot(status: .sleeping)
                    ControlTipRow(title: "Inactive", message: "Input unavailable")
                }
                HStack{
                    StatusDot(status: .offline)
                    ControlTipRow(title: "No signal", message: "Disconnected")
                }
            }
            Spacer(minLength: 24)
             
             */
            Text("Controls")
                .font(.headline)

            
            
#if os(iOS)
            VStack(alignment: .leading, spacing: 8) {
                ControlTipRow(title: "Click", message: "Tap (Left by default)")
                ControlTipRow(title: "Right Click", message: "Choose Right Click, then tap")
                ControlTipRow(title: "Scroll", message: "Swipe at normal zoom")
                ControlTipRow(title: "Drag", message: "Touch and hold, then move")
                ControlTipRow(title: "Zoom View", message: "Pinch or use Zoom")
                ControlTipRow(title: "Type", message: "Open the Keyboard control")
            }

            Text("For a connected remote window. Zoom only enlarges your view; while zoomed, swipe to pan it and tap Reset to scroll again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
#else
            VStack(alignment: .leading, spacing: 8) {
                ControlTipRow(title: "Left Click", message: "Pinch")
                ControlTipRow(title: "Right Click", message: "Pinch and hold")
                ControlTipRow(title: "Scroll", message: "Pinch and drag")
                ControlTipRow(title: "Drag", message: "Pinch, hold, and drag")
                ControlTipRow(title: "Zoom", message: "Pinch in/out with both hands")
            }
#endif
            
Text("Peel Pro also supports external input devices")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            



          //  VStack(alignment: .leading, spacing: 8) {
          //      ControlTipRow(title: "Tap", message: "Click")
          //      ControlTipRow(title: "Double-tap", message: "Double-click")
          //      ControlTipRow(title: "Tap and drag", message: "Scroll")
          //      ControlTipRow(title: "Long press and drag", message: "Drag")
          //  }
            
   
            
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func copyPeelHostDownloadLink() {
#if canImport(UIKit)
        UIPasteboard.general.string = peelHostDownloadURL.absoluteString
#elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(peelHostDownloadURL.absoluteString, forType: .string)
#endif

        didCopyHostLink = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyHostLink = false
        }
    }
}

private struct TutorialStepRow<Accessory: View>: View {
    let number: String
    let title: String
    let message: String
    @ViewBuilder let accessory: Accessory

    init(
        number: String,
        title: String,
        message: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.number = number
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.blue))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension TutorialStepRow where Accessory == EmptyView {
    init(number: String, title: String, message: String) {
        self.number = number
        self.title = title
        self.message = message
        self.accessory = EmptyView()
    }
}

private struct ControlTipRow: View {
    let title: String
    let message: String

    var body: some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))

            Spacer()

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
