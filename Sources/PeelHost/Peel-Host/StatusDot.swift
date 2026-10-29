//
//  WindowStreamStatus.swift
//  Peel
//
//  Created by Zach on 1/18/26.
//


import SwiftUI

enum WindowStreamStatus: Equatable {
    case offline      // no connection / not available
    case sleeping     // connected but not actively streaming (1fps or paused)
    case active       // actively streaming (30fps window)
}

struct StatusDot: View {
    let status: WindowStreamStatus
    var size: CGFloat = 10
    /// For dots that show something other than a window stream, such as host
    /// readiness. Window-stream dots keep the default labels.
    var accessibilityLabelOverride: String? = nil

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityLabelOverride ?? accessibilityText)
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
