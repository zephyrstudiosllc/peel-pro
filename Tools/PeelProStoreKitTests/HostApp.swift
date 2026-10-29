import SwiftUI
import StoreKit

/// The fixture captures the same real SwiftUI purchase environment action used
/// by the shipping paywall. This does not manufacture purchase results.
@MainActor
public enum FixturePurchaseContext {
    public static var action: PurchaseAction?
}

private struct FixtureRootView: View {
    @Environment(\.purchase) private var purchase
    var body: some View {
        Text("Peel Pro local StoreKit validation")
            .task { FixturePurchaseContext.action = purchase }
    }
}

@main
struct PeelProStoreKitFixtureHost: App {
    var body: some Scene {
        WindowGroup { FixtureRootView() }
    }
}
