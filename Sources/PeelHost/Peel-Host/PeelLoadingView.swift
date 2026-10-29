//
//  PeelLoadingView.swift
//  Peel
//
//  Created by Zach on 5/23/26.
//


import SwiftUI

// MARK: - PeelLoadingView

struct PeelLoadingView: View {
    
    enum Variant {
        case searching
        case connecting
        case streaming
        case minimal
        
        var defaultTitle: String {
            switch self {
            case .searching:
                return "Looking for your Mac"
            case .connecting:
                return "Connecting to Peel Pro"
            case .streaming:
                return "Starting stream"
            case .minimal:
                return "Loading Peel"
            }
        }
        
        var defaultMessage: String {
            switch self {
            case .searching:
                return "Make sure Peel Pro is open and both devices are on the same Wi-Fi."
            case .connecting:
                return "Starting a local connection to your Mac…"
            case .streaming:
                return "Preparing your Mac window…"
            case .minimal:
                return "Just a moment…"
            }
        }
        
        var symbolName: String {
            switch self {
            case .searching:
                return "dot.radiowaves.left.and.right"
            case .connecting:
                return "point.3.connected.trianglepath.dotted"
            case .streaming:
                return "play.rectangle.on.rectangle"
            case .minimal:
                return "sparkle"
            }
        }
        
        var showsLogoByDefault: Bool {
            switch self {
            case .searching, .connecting, .streaming:
                return true
            case .minimal:
                return false
            }
        }
    }
    
    let title: String
    let message: String
    let delayedTitle: String?
    let delayedMessage: String?
    let helpDelay: TimeInterval
    let variant: Variant
    let assetName: String
    let showsLogo: Bool
    
    @State private var breathes = false
    @State private var rotates = false
    @State private var sparkles = false
    @State private var waveExpands = false
    @State private var showsDelayedHelp = false
    
    init(
        title: String? = nil,
        message: String? = nil,
        delayedTitle: String? = nil,
        delayedMessage: String? = nil,
        helpDelay: TimeInterval = 6,
        variant: Variant = .connecting,
        assetName: String = "visionOS_icon_1024",
        showsLogo: Bool? = nil
    ) {
        self.variant = variant
        self.title = title ?? variant.defaultTitle
        self.message = message ?? variant.defaultMessage
        self.delayedTitle = delayedTitle
        self.delayedMessage = delayedMessage
        self.helpDelay = helpDelay
        self.assetName = assetName
        self.showsLogo = showsLogo ?? variant.showsLogoByDefault
    }

    init(
        header: String,
        subhead: String,
        delayedHeader: String? = nil,
        delayedSubhead: String? = nil,
        helpDelay: TimeInterval = 6,
        variant: Variant = .connecting,
        assetName: String = "visionOS_icon_1024",
        showsLogo: Bool? = nil
    ) {
        self.variant = variant
        self.title = header
        self.message = subhead
        self.delayedTitle = delayedHeader
        self.delayedMessage = delayedSubhead
        self.helpDelay = helpDelay
        self.assetName = assetName
        self.showsLogo = showsLogo ?? variant.showsLogoByDefault
    }
    
    var body: some View {
        VStack(spacing: 24) {
            loaderMark
            
            VStack(spacing: 8) {
                Text(currentTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                
                Text(currentMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            backgroundCard
        }
        .padding(24)
        .task {
            startAnimations()
            await revealDelayedHelpIfNeeded()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(currentTitle). \(currentMessage)")
    }
}

// MARK: - Pieces

private extension PeelLoadingView {
    var currentTitle: String {
        if showsDelayedHelp, let delayedTitle {
            return delayedTitle
        }
        return title
    }
    
    var currentMessage: String {
        if showsDelayedHelp, let delayedMessage {
            return delayedMessage
        }
        return message
    }
    
    
    var loaderMark: some View {
        ZStack {
            ambientGlow
            
            if variant == .searching {
                searchWaves
            }
            
            if variant == .connecting || variant == .streaming {
                rotatingHalo
            }
            
            if variant == .streaming || variant == .minimal {
                sparkleLayer
            }
            
            centerBadge
        }
        .frame(width: 144, height: 144)
    }
    
    var backgroundCard: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 26, x: 0, y: 14)
    }
    
    var ambientGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        .orange.opacity(breathes ? 0.36 : 0.18),
                        .blue.opacity(breathes ? 0.22 : 0.10),
                        .clear
                    ],
                    center: .center,
                    startRadius: 6,
                    endRadius: 78
                )
            )
            .scaleEffect(breathes ? 1.10 : 0.92)
            .blur(radius: 8)
    }
    
    var rotatingHalo: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                AngularGradient(
                    colors: [
                        .orange.opacity(0.12),
                        .orange.opacity(0.9),
                        .blue.opacity(0.7),
                        .orange.opacity(0.12)
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .frame(width: 112, height: 112)
            .rotationEffect(.degrees(rotates ? 360 : 0))
    }
    
    var searchWaves: some View {
        ZStack {
            Circle()
                .stroke(.orange.opacity(waveExpands ? 0.04 : 0.20), lineWidth: 2)
                .frame(width: waveExpands ? 132 : 76, height: waveExpands ? 132 : 76)
            
            Circle()
                .stroke(.blue.opacity(waveExpands ? 0.04 : 0.16), lineWidth: 2)
                .frame(width: waveExpands ? 104 : 60, height: waveExpands ? 104 : 60)
        }
    }
    
    var centerBadge: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 80, height: 80)
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 6)
            
            if showsLogo {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: variant.symbolName)
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(breathes ? 1.025 : 0.985)
    }
    
    var sparkleLayer: some View {
        ZStack {
            sparkle(size: 8, x: -52, y: -36, opacity: 0.95)
            sparkle(size: 5, x: 48, y: -46, opacity: 0.62)
            sparkle(size: 6, x: 54, y: 32, opacity: 0.80)
            sparkle(size: 4, x: -42, y: 46, opacity: 0.58)
        }
    }
    
    func sparkle(size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.orange.opacity(opacity))
            .scaleEffect(sparkles ? 1.28 : 0.72)
            .opacity(sparkles ? opacity : 0.22)
            .offset(x: x, y: y)
            .accessibilityHidden(true)
    }
}

// MARK: - Animation

private extension PeelLoadingView {
    
    func startAnimations() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            breathes = true
        }
        
        withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
            rotates = true
        }
        
        withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
            sparkles = true
        }
        
        withAnimation(.easeOut(duration: 1.45).repeatForever(autoreverses: false)) {
            waveExpands = true
        }
    }
    
    func revealDelayedHelpIfNeeded() async {
        guard delayedTitle != nil || delayedMessage != nil else { return }
        guard helpDelay > 0 else {
            showsDelayedHelp = true
            return
        }
        
        try? await Task.sleep(for: .seconds(helpDelay))
        guard !Task.isCancelled else { return }
        
        withAnimation(.easeInOut(duration: 0.25)) {
            showsDelayedHelp = true
        }
    }
}

// MARK: - Convenience Presets

extension PeelLoadingView {
    
    static var searchingForMac: PeelLoadingView {
        PeelLoadingView(variant: .searching)
    }
    
    static var connectingToHost: PeelLoadingView {
        PeelLoadingView(variant: .connecting)
    }
    
    static var startingStream: PeelLoadingView {
        PeelLoadingView(variant: .streaming)
    }
    
    static var minimal: PeelLoadingView {
        PeelLoadingView(variant: .minimal)
    }
}

// MARK: - Preview

#Preview("Searching") {
    PeelLoadingPreviewBackground {
        PeelLoadingView(variant: .searching)
    }
}

#Preview("Connecting") {
    PeelLoadingPreviewBackground {
        PeelLoadingView(variant: .connecting)
    }
}

#Preview("Streaming") {
    PeelLoadingPreviewBackground {
        PeelLoadingView(
            header: "Opening Peel…",
            subhead: "Preparing your Mac window.",
            delayedHeader: "Still waiting for your Mac",
            delayedSubhead: "Return to the Peel Pro menu and reconnect if this window does not appear.",
            helpDelay: 3,
            variant: .streaming
        )
    }
}

#Preview("Minimal / No Logo") {
    PeelLoadingPreviewBackground {
        PeelLoadingView(variant: .minimal, showsLogo: false)
    }
}

private struct PeelLoadingPreviewBackground<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.orange.opacity(0.14),
                    Color.blue.opacity(0.10),
                    Color.black.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            content
        }
    }
}
