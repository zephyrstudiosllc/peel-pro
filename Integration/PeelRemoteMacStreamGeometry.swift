import Foundation
import CoreGraphics

/// All window sizing and pointer hit testing use the decoded image aspect.
/// A listed-window descriptor is only the fallback before video configuration.
enum PeelRemoteMacStreamGeometry {
    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 32768 && size.height <= 32768
    }

    static func fit(_ stream: CGSize, inside bounds: CGSize) -> CGSize? {
        guard validSize(stream), bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / stream.width, bounds.height / stream.height)
        return CGSize(width: stream.width * scale, height: stream.height * scale)
    }

    static func contentRect(in bounds: CGRect, stream: CGSize) -> CGRect? {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              let size = fit(stream, inside: bounds.size) else { return nil }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func normalizedPoint(_ point: CGPoint, in bounds: CGRect, stream: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              let image = contentRect(in: bounds, stream: stream), image.contains(point) else { return nil }
        let x = (point.x - image.minX) / image.width
        let y = 1 - (point.y - image.minY) / image.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

/// Labels come only from authenticated protocol metadata; names and service IDs are not OS evidence.
enum PeelRemoteMacPlatformLabel {
    static func title(for platform: String) -> String {
        switch platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "macos", "mac", "os x": return "Mac"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return "Computer"
        }
    }
}
