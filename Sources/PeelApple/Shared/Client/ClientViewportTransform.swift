//
//  ClientViewportTransform.swift
//  Peel
//
//  Created by Zach on 4/3/26.
//


//
//  ClientViewportTransform.swift
//  Peel
//
//  Client-side viewport math for local zoom + pan over a fitted streamed image.
//  This is intentionally UI-agnostic so PeeledWindowView can stay focused on gesture wiring.
//

import SwiftUI
import CoreGraphics

struct ClientViewportTransform {
    let viewSize: CGSize
    let contentAspect: CGFloat

    /// Current local zoom applied on the client.
    let zoomScale: CGFloat

    /// Current local pan offset in view points, relative to the fitted content rect center.
    let contentOffset: CGSize

    /// Small per-client calibration to keep host clicks aligned with the captured content.
    let clickCalibrationOffset: CGSize

    init(
        viewSize: CGSize,
        contentAspect: CGFloat,
        zoomScale: CGFloat,
        contentOffset: CGSize,
        clickCalibrationOffset: CGSize = .zero
    ) {
        self.viewSize = viewSize
        self.contentAspect = contentAspect
        self.zoomScale = max(1.0, zoomScale)
        self.contentOffset = contentOffset
        self.clickCalibrationOffset = clickCalibrationOffset
    }

    // MARK: - Base fitted rect

    /// The rect occupied by the streamed content after `.aspectRatio(..., contentMode: .fit)`.
    var fittedContentRect: CGRect {
        guard viewSize.width > 0, viewSize.height > 0, contentAspect > 0 else {
            return .zero
        }

        let viewAspect = viewSize.width / max(viewSize.height, 1)

        if viewAspect > contentAspect {
            let height = viewSize.height
            let width = height * contentAspect
            let originX = (viewSize.width - width) / 2
            return CGRect(x: originX, y: 0, width: width, height: height)
        } else {
            let width = viewSize.width
            let height = width / contentAspect
            let originY = (viewSize.height - height) / 2
            return CGRect(x: 0, y: originY, width: width, height: height)
        }
    }

    // MARK: - Displayed rect after local zoom + pan

    var scaledContentSize: CGSize {
        let rect = fittedContentRect
        return CGSize(width: rect.width * zoomScale, height: rect.height * zoomScale)
    }

    /// The actual on-screen rect of the content after local zoom + pan.
    var displayedContentRect: CGRect {
        let rect = fittedContentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }

        let clamped = clampedOffset(contentOffset)
        let scaled = scaledContentSize

        return CGRect(
            x: rect.midX - (scaled.width / 2) + clamped.width,
            y: rect.midY - (scaled.height / 2) + clamped.height,
            width: scaled.width,
            height: scaled.height
        )
    }

    // MARK: - Offset clamping

    func clampedOffset(_ proposed: CGSize) -> CGSize {
        let rect = fittedContentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }

        if zoomScale <= 1.0001 {
            return .zero
        }

        let scaled = scaledContentSize
        let maxX = max(0, (scaled.width - rect.width) / 2)
        let maxY = max(0, (scaled.height - rect.height) / 2)

        return CGSize(
            width: proposed.width.clamped(to: -maxX...maxX),
            height: proposed.height.clamped(to: -maxY...maxY)
        )
    }

    func pannedOffset(from baseOffset: CGSize, translation: CGSize) -> CGSize {
        clampedOffset(
            CGSize(
                width: baseOffset.width + translation.width,
                height: baseOffset.height + translation.height
            )
        )
    }

    // MARK: - View <-> normalized content mapping

    /// Converts a view-space point into normalized content coordinates (0...1, top-left origin),
    /// undoing the client-side zoom + pan first.
    func normalizedPoint(for viewPoint: CGPoint) -> CGPoint? {
        let baseRect = fittedContentRect
        let shownRect = displayedContentRect

        guard baseRect.width > 0, baseRect.height > 0,
              shownRect.width > 0, shownRect.height > 0 else {
            return nil
        }

        // Clamp into the displayed rect so taps in outer space snap to the nearest edge.
        var x = viewPoint.x.clamped(to: shownRect.minX...shownRect.maxX)
        var y = viewPoint.y.clamped(to: shownRect.minY...shownRect.maxY)

        // Move into displayed-content-local space.
        x -= shownRect.minX
        y -= shownRect.minY

        // Undo local zoom to get back into unzoomed content space.
        x /= zoomScale
        y /= zoomScale

        // Apply the same calibration used by click mapping.
        x = (x + clickCalibrationOffset.width).clamped(to: 0...baseRect.width)
        y = (y + clickCalibrationOffset.height).clamped(to: 0...baseRect.height)

        return CGPoint(x: x / baseRect.width, y: y / baseRect.height)
    }

    /// Converts a normalized content point (0...1, top-left origin) into a view-space point,
    /// re-applying the client-side zoom + pan for overlays/cursors.
    func viewPoint(fromNormalized norm: CGPoint) -> CGPoint {
        let baseRect = fittedContentRect
        let shownRect = displayedContentRect

        guard baseRect.width > 0, baseRect.height > 0,
              shownRect.width > 0, shownRect.height > 0 else {
            return .zero
        }

        let nx = norm.x.clamped(to: 0...1)
        let ny = norm.y.clamped(to: 0...1)

        let contentX = nx * baseRect.width
        let contentY = ny * baseRect.height

        return CGPoint(
            x: shownRect.minX + (contentX * zoomScale),
            y: shownRect.minY + (contentY * zoomScale)
        )
    }

    // MARK: - Pinch anchoring

    /// Adjusts pan so scaling feels anchored around the user's pinch/tap location in view space.
    func offsetKeepingAnchorStable(
        from oldScale: CGFloat,
        to newScale: CGFloat,
        anchorInView anchor: CGPoint,
        currentOffset: CGSize
    ) -> CGSize {
        let rect = fittedContentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }

        let oldScale = max(1.0, oldScale)
        let newScale = max(1.0, newScale)

        let oldTransform = ClientViewportTransform(
            viewSize: viewSize,
            contentAspect: contentAspect,
            zoomScale: oldScale,
            contentOffset: currentOffset,
            clickCalibrationOffset: clickCalibrationOffset
        )

        let oldDisplayed = oldTransform.displayedContentRect
        guard oldDisplayed.width > 0, oldDisplayed.height > 0 else { return .zero }

        // Find which unzoomed content point currently sits under the anchor.
        let localX = ((anchor.x - oldDisplayed.minX) / oldScale).clamped(to: 0...rect.width)
        let localY = ((anchor.y - oldDisplayed.minY) / oldScale).clamped(to: 0...rect.height)

        // Solve the new offset so that same content point remains under the same view anchor.
        let newScaledWidth = rect.width * newScale
        let newScaledHeight = rect.height * newScale

        let proposed = CGSize(
            width: anchor.x - rect.midX + (newScaledWidth / 2) - (localX * newScale),
            height: anchor.y - rect.midY + (newScaledHeight / 2) - (localY * newScale)
        )

        let newTransform = ClientViewportTransform(
            viewSize: viewSize,
            contentAspect: contentAspect,
            zoomScale: newScale,
            contentOffset: proposed,
            clickCalibrationOffset: clickCalibrationOffset
        )

        return newTransform.clampedOffset(proposed)
    }
}

// MARK: - Small helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}