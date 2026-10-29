import Foundation
import CoreGraphics

/// Rectangles in the same safe-area container and layout coordinate space that
/// renders the panes. The native adapter matches SwiftUI placement's RTL
/// mirroring and supplies active region frames with their existing margins.
struct PeelPhoneWorkspaceGeometry: Equatable {
    enum Arrangement: String {
        case single
        case columns
        case rows
        case book
        case tabletop
    }

    let arrangement: Arrangement
    let primary: CGRect
    let companion: CGRect

    var showsBoth: Bool { !primary.isEmpty && !companion.isEmpty }

    var visiblePanes: Set<PeelPhoneWorkspacePane> {
        var panes: Set<PeelPhoneWorkspacePane> = []
        if !primary.isEmpty { panes.insert(.primary) }
        if !companion.isEmpty { panes.insert(.companion) }
        return panes
    }

    func frame(for pane: PeelPhoneWorkspacePane) -> CGRect {
        pane == .primary ? primary : companion
    }

    static func resolve(
        size: CGSize,
        regularWidth: Bool,
        selected: PeelPhoneWorkspacePane,
        hasCompanion: Bool,
        divisions: [CGRect] = [],
        occlusions: [CGRect] = []
    ) -> Self {
        let bounds = CGRect(origin: .zero, size: size)
        guard valid(bounds) else { return Self(arrangement: .single, primary: .zero, companion: .zero) }

        let holes = occlusions.compactMap { clipped($0, to: bounds) }
        let division = divisions.compactMap { clipped($0, to: bounds) }.max { area($0) < area($1) }
        let effectiveSelection: PeelPhoneWorkspacePane = hasCompanion ? selected : .primary

        if let division {
            let vertical = division.height >= division.width
            let regions: [CGRect]
            if vertical {
                regions = [
                    CGRect(x: bounds.minX, y: bounds.minY, width: division.minX - bounds.minX, height: bounds.height),
                    CGRect(x: division.maxX, y: bounds.minY, width: bounds.maxX - division.maxX, height: bounds.height)
                ]
            } else {
                regions = [
                    CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: division.minY - bounds.minY),
                    CGRect(x: bounds.minX, y: division.maxY, width: bounds.width, height: bounds.maxY - division.maxY)
                ]
            }
            let safe = regions.map { largestClearRectangle(in: $0, excluding: holes) }
            if hasCompanion, safe.allSatisfy({ $0.width >= 280 && $0.height >= 160 }) {
                return Self(arrangement: vertical ? .book : .tabletop, primary: safe[0], companion: safe[1])
            }
            // A single pane must also avoid the fold. Prefer the trailing book
            // region or upper tabletop region when both have equal usable area.
            let ordered = vertical ? safe.reversed().map { $0 } : safe
            let best = ordered.reduce(CGRect.zero) { area($1) > area($0) ? $1 : $0 }
            return single(best, selected: effectiveSelection)
        }

        if regularWidth && hasCompanion {
            let canUseColumns = bounds.width >= 600 && bounds.height >= 160
            let canUseRows = bounds.height >= 400 && bounds.width >= 300
            let columns = canUseColumns && (bounds.width >= bounds.height || !canUseRows)
            if columns || canUseRows {
                let first: CGRect
                let second: CGRect
                if columns {
                    let width = (bounds.width - 1) / 2
                    first = CGRect(x: 0, y: 0, width: width, height: bounds.height)
                    second = CGRect(x: width + 1, y: 0, width: width, height: bounds.height)
                } else {
                    let height = (bounds.height - 1) / 2
                    first = CGRect(x: 0, y: 0, width: bounds.width, height: height)
                    second = CGRect(x: 0, y: height + 1, width: bounds.width, height: height)
                }
                let safeFirst = largestClearRectangle(in: first, excluding: holes)
                let safeSecond = largestClearRectangle(in: second, excluding: holes)
                if valid(safeFirst) && valid(safeSecond) {
                    return Self(arrangement: columns ? .columns : .rows, primary: safeFirst, companion: safeSecond)
                }
            }
        }
        return single(largestClearRectangle(in: bounds, excluding: holes), selected: effectiveSelection)
    }

    private static func single(_ frame: CGRect, selected: PeelPhoneWorkspacePane) -> Self {
        Self(arrangement: .single, primary: selected == .primary ? frame : .zero, companion: selected == .companion ? frame : .zero)
    }

    nonisolated private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func clipped(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        guard valid(rect) else { return nil }
        let intersection = rect.intersection(bounds)
        return valid(intersection) ? intersection : nil
    }

    private static func area(_ rect: CGRect) -> CGFloat { valid(rect) ? rect.width * rect.height : 0 }

    private static func largestClearRectangle(in bounds: CGRect, excluding holes: [CGRect]) -> CGRect {
        guard valid(bounds) else { return .zero }
        var candidates = [bounds]
        for hole in holes {
            candidates = candidates.flatMap { candidate -> [CGRect] in
                guard let cut = clipped(hole, to: candidate) else { return [candidate] }
                return [
                    CGRect(x: candidate.minX, y: candidate.minY, width: cut.minX - candidate.minX, height: candidate.height),
                    CGRect(x: cut.maxX, y: candidate.minY, width: candidate.maxX - cut.maxX, height: candidate.height),
                    CGRect(x: candidate.minX, y: candidate.minY, width: candidate.width, height: cut.minY - candidate.minY),
                    CGRect(x: candidate.minX, y: cut.maxY, width: candidate.width, height: candidate.maxY - cut.maxY)
                ].filter(valid)
            }
        }
        return candidates.max { area($0) < area($1) } ?? .zero
    }
}
