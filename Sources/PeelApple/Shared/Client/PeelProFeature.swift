import Foundation

enum PeelProFeature: String, Identifiable {
    case general
    case multipleWindows
    case appLauncher
    case macIcon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Peel Pro"
        case .multipleWindows: return "Open more remote windows"
        case .appLauncher: return "Launch Mac apps with Pro"
        case .macIcon: return "Personalize your computers with Pro"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Choose how you pay. Get the same Pro features on your supported Apple devices."
        case .multipleWindows:
#if os(visionOS)
            return "Your first two streaming windows are free. Unlock Pro to open a third and keep more apps in view."
#else
            return "Your first streaming window is free. Unlock Pro to use two or more remote apps side by side."
#endif
        case .appLauncher:
            return "Open apps on your paired Mac with the app launcher, included with every Pro plan."
        case .macIcon:
            return "Custom computer icons are included with every Pro plan."
        }
    }
}
