//
//  HostAppIconProvider.swift
//  Peel-Host
//
//  Created by Zach on 5/23/26.
//


import AppKit

enum HostAppIconProvider {
    private static var cache: [String: String] = [:]

    static func iconPNGBase64(for pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        let cacheKey = app.bundleIdentifier
            ?? app.bundleURL?.path
            ?? "\(pid)"

        if let cached = cache[cacheKey] {
            return cached
        }

        guard let icon = iconImage(for: app),
              let data = pngData(from: icon, size: 64) else {
            return nil
        }

        let base64 = data.base64EncodedString()
        cache[cacheKey] = base64
        return base64
    }

    private static func iconImage(for app: NSRunningApplication) -> NSImage? {
        if let bundleURL = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        return app.icon
    }

    private static func pngData(from image: NSImage, size: CGFloat) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let resized = NSImage(size: targetSize)

        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}