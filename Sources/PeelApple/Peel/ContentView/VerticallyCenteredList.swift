//
//  VerticallyCenteredList.swift
//  Peel
//

import SwiftUI

private struct PeelListGeometry: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

private struct VerticallyCenteredListModifier: ViewModifier {
    let upwardBias: CGFloat

    @State private var verticalContentMargin: CGFloat = 0

    private var contentInsets: EdgeInsets {
        let totalMargin = verticalContentMargin * 2
        let topMargin = min(max(verticalContentMargin - upwardBias, 0), totalMargin)

        return EdgeInsets(
            top: topMargin,
            leading: 0,
            bottom: totalMargin - topMargin,
            trailing: 0
        )
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.vertical, contentInsets, for: .scrollContent)
            .onScrollGeometryChange(for: PeelListGeometry.self) { geometry in
                PeelListGeometry(
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { _, geometry in
                // visionOS List includes applied scroll-content margins in contentSize.
                let intrinsicContentHeight = max(
                    geometry.contentHeight - (verticalContentMargin * 2),
                    0
                )
                let centeredMargin = max(
                    (geometry.containerHeight - intrinsicContentHeight) / 2,
                    0
                )

                guard abs(centeredMargin - verticalContentMargin) >= 0.5 else {
                    return
                }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    verticalContentMargin = centeredMargin
                }
            }
    }
}

extension View {
    func verticallyCentersUnderfilledList(upwardBias: CGFloat = 0) -> some View {
        modifier(VerticallyCenteredListModifier(upwardBias: upwardBias))
    }
}
