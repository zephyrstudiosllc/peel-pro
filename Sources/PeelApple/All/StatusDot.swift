import SwiftUI

enum WindowStreamStatus: Equatable {
    case offline      // no connection / not available
    case sleeping     // connected but not actively streaming (1fps or paused)
    case active       // actively streaming (30fps window)
}

struct StatusDot: View {
    let status: WindowStreamStatus
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityText)
    }

    private var dotColor: Color {
        switch status {
        case .active: return .green
        case .sleeping: return .orange
        case .offline: return .gray
        }
    }

    private var accessibilityText: String {
        switch status {
        case .active: return "Streaming active"
        case .sleeping: return "Streaming sleeping"
        case .offline: return "Offline"
        }
    }
}
