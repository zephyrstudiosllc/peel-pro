//
//  ProcessIconView.swift
//  Kill Switch
//

import SwiftUI
import AppKit

@MainActor
private enum ProcessIconProvider {
    private static let maximumCachedIcons = 96
    private static var cache: [String: NSImage] = [:]

    static func image(for sample: ProcessSample) -> NSImage? {
        guard let path = sample.bundleURLPath ?? sample.executablePath,
              !path.isEmpty else {
            return nil
        }

        if let cached = cache[path] {
            return cached
        }

        if cache.count >= maximumCachedIcons {
            cache.removeAll(keepingCapacity: true)
        }

        let source = NSWorkspace.shared.icon(forFile: path)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 20, height: 20)
        cache[path] = image
        return image
    }
}

struct ProcessIconView: View {
    let sample: ProcessSample
    let size: CGFloat

    var body: some View {
        Group {
            if let image = ProcessIconProvider.image(for: sample) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: sample.processType == "App" ? "app.fill" : "gearshape.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
