import SwiftUI
import PeelWatchCore

struct PeelWatchStreamView: View {
    @ObservedObject var model: PeelCompanionModel
    @State private var zoom = 1.0
    @State private var centerX = 0.5
    @State private var centerY = 0.5
    @State private var tapControl = false
    @State private var showsText = false
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let info = model.watchStreamInfo {
                    Text(info.hostName).font(.caption2).foregroundStyle(.secondary)
                    Text(info.windowTitle).font(.headline).lineLimit(2)
                }
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image = model.watchStreamImage {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "iphone.and.arrow.forward")
                                Text("Waiting for live view").font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in click(point, size: geometry.size) }
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        centerX -= Double(value.translation.width / max(1, geometry.size.width)) / zoom
                        centerY -= Double(value.translation.height / max(1, geometry.size.height)) / zoom
                        updateViewport()
                    })
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Live window view. Drag to pan. Use the crown to zoom.")
                .accessibilityIdentifier("watch.stream.image")
                Text(model.watchStreamStatus).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button { zoom = max(1, zoom-1); updateViewport() } label: { Image(systemName: "minus.magnifyingglass") }
                    Button("\(zoom, specifier: "%.1f")×") { zoom = 1; centerX = 0.5; centerY = 0.5; updateViewport() }
                    Button { zoom = min(8, zoom+1); updateViewport() } label: { Image(systemName: "plus.magnifyingglass") }
                }.buttonStyle(.bordered)
                HStack(spacing: 4) {
                    panButton("arrow.left", x: -0.2, y: 0)
                    panButton("arrow.up", x: 0, y: -0.2)
                    panButton("arrow.down", x: 0, y: 0.2)
                    panButton("arrow.right", x: 0.2, y: 0)
                }.buttonStyle(.bordered)
                if model.watchStreamInfo?.controlToken != nil {
                    Toggle("Tap to click", isOn: $tapControl).font(.caption)
                    HStack {
                        Button("Text") { showsText = true }
                        Button { send(.init(kind: .enter)) } label: { Image(systemName: "return") }
                        Button { send(.init(kind: .backspace)) } label: { Image(systemName: "delete.left") }
                    }.buttonStyle(.bordered).disabled(model.watchStreamBusy || model.watchStreamImage == nil)
                    HStack {
                        Button("Scroll ↑") { send(.init(kind: .scrollUp)) }
                        Button("Scroll ↓") { send(.init(kind: .scrollDown)) }
                    }.font(.caption).disabled(model.watchStreamBusy || model.watchStreamImage == nil)
                } else {
                    Text("Viewing only. Allow Watch Control on iPhone for clicks and text.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Reconnect") { tapControl = false; model.startWatchViewing() }
                Button("Stop", role: .destructive) { tapControl = false; model.stopWatchViewing() }
                Text("Paired iPhone required with Peel Pro open. Up to 1 frame/sec; no independent connection.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal, 4)
        }
        .navigationTitle("Remote Desktop")
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 8, by: 0.25,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, _ in updateViewport() }
        .onChange(of: model.watchStreamInfo?.controlToken) { _, token in if token == nil { tapControl = false } }
        .onAppear { updateViewport(); model.startWatchViewing() }
        .onDisappear { tapControl = false; model.stopWatchViewing() }
        .sheet(isPresented: $showsText) {
            NavigationStack {
                Form {
                    TextField("Type or dictate", text: $text)
                    Text("Sent to the focused remote app through your paired iPhone.").font(.caption2)
                    Button("Send text") {
                        let value = text; text = ""; showsText = false
                        send(.init(kind: .text, text: value))
                    }.disabled(text.isEmpty || text.count > 500)
                    Button("Cancel", role: .cancel) { showsText = false }
                }.navigationTitle("Remote text")
            }
        }
    }
    private func updateViewport() {
        centerX = min(1, max(0, centerX)); centerY = min(1, max(0, centerY))
        model.watchViewport = .centered(zoom: zoom, centerX: centerX, centerY: centerY)
    }
    private func panButton(_ symbol: String, x: Double, y: Double) -> some View {
        Button { centerX += x/zoom; centerY += y/zoom; updateViewport() } label: { Image(systemName: symbol) }
    }
    private func send(_ input: WatchStreamInput) { Task { await model.sendWatchInput(input) } }
    private func click(_ point: CGPoint, size: CGSize) {
        guard tapControl, let frame = model.watchStreamFrame else { return }
        let scale = min(size.width/CGFloat(frame.width), size.height/CGFloat(frame.height))
        let width = CGFloat(frame.width)*scale, height = CGFloat(frame.height)*scale
        guard width > 0, height > 0 else { return }
        let x = point.x-(size.width-width)/2, y = point.y-(size.height-height)/2
        guard x >= 0, y >= 0, x <= width, y <= height else { return }
        send(.init(kind: .click, x: frame.viewport.x + Double(x/width)*frame.viewport.width,
                   y: frame.viewport.y + Double(y/height)*frame.viewport.height))
    }
}
