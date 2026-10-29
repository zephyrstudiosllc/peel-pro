import SwiftUI
import StoreKit

/// Every payment option grants the same Pro capabilities. StoreKit supplies
/// localized prices and sharing eligibility; the local catalog is not a live offer.
struct PeelPaywallView: View {
    @EnvironmentObject private var store: PeelStore
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var showingSubscriptions = false
    @State private var confirmingLifetime = false

    let feature: PeelProFeature

    init(feature: PeelProFeature = .general) {
        self.feature = feature
    }

    private var subscriptionProducts: [Product] {
        store.aiSubscriptionProducts.sorted {
            ($0.subscription?.subscriptionPeriod.unit == .month ? 0 : 1) <
                ($1.subscription?.subscriptionPeriod.unit == .month ? 0 : 1)
        }
    }

    private var availableProducts: [Product] {
        subscriptionProducts + [store.lifetimeProduct].compactMap { $0 }
    }

    private var purchasesBusy: Bool {
        !store.hasResolvedAccessState || store.isPurchasing || store.isRestoring
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("PeelHostMenuBarIcon_256x256")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 8) {
                    Text(feature.title)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("peel.pro.title")
                    Text(feature.subtitle)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    Label("More remote windows at once", systemImage: "rectangle.on.rectangle")
                    Label("Remote agent coordination and automation", systemImage: "sparkles")
                    Label("Agent notifications and app launcher", systemImage: "bell.badge")
                    Text("Monthly, yearly and lifetime unlock the same Pro features.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                purchaseStatus

                if !store.hasLifetimeUnlock {
                    VStack(spacing: 12) {
                        ForEach(subscriptionProducts, id: \.id) { product in
                            purchaseButton(product)
                        }
                        if let lifetime = store.lifetimeProduct {
                            purchaseButton(lifetime)
                        }
                    }

                    if availableProducts.isEmpty {
                        if store.isLoadingProducts {
                            ProgressView("Loading plans…")
                        } else {
                            Text("Plans are temporarily unavailable. You can keep using Peel for free or restore an existing purchase.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try Again") { Task { await store.requestProducts() } }
                                .disabled(purchasesBusy)
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button("Restore Purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .accessibilityIdentifier("peel.pro.restore")
                    .disabled(store.isRestoring || store.isPurchasing)

                    Button("Manage Subscriptions") { showingSubscriptions = true }
                        .accessibilityIdentifier("peel.pro.manageSubscriptions")
                    if feature == .multipleWindows {
                        Button("Continue with Free") { dismiss() }
                            .accessibilityIdentifier("peel.pro.continueFree")
                    }
                }

                if let error = store.purchaseErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("peel.pro.error")
                }

                VStack(spacing: 10) {
                    Text("Subscriptions renew automatically until canceled in your App Store account. Lifetime is a single payment with no renewal.")
                    Text("Existing Peel lifetime purchases include Pro. Restore using the Apple Account that purchased Peel, or an eligible family member’s purchase.")
                    Text("AI provider subscriptions and usage are not included. Computer pairing and sharing permissions remain under your control.")
                    HStack(spacing: 20) {
                        Link("Terms of Use", destination: URL(string: "https://zephyrstudios.dev/terms-of-use.html")!)
                        Link("Privacy Policy", destination: URL(string: "https://zephyrstudios.dev/privacy-policy.html")!)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("peel.pro.paywall")
        .task { await store.start() }
        .manageSubscriptionsSheet(isPresented: $showingSubscriptions)
        .alert("Switch to lifetime Pro?", isPresented: $confirmingLifetime) {
            Button("Manage Subscription") { showingSubscriptions = true }
            Button("Buy Lifetime") { Task { await store.purchaseLifetime(using: purchase) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lifetime is a separate purchase. Your current subscription keeps renewing until you cancel it in App Store subscription settings.")
        }
        .onChange(of: store.hasProAccess) { _, hasAccess in
            if hasAccess && feature == .multipleWindows { dismiss() }
        }
    }

    private func purchaseButton(_ product: Product) -> some View {
        Button {
            store.clearError()
            if product.type == .nonConsumable {
                if store.hasAISubscription {
                    confirmingLifetime = true
                } else {
                    Task { await store.purchaseLifetime(using: purchase) }
                }
            } else {
                Task { await store.purchaseAISubscription(product, using: purchase) }
            }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(planName(product)).font(.headline)
                    Text(product.isFamilyShareable ? "Family Sharing included" : "For your Apple Account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(product.displayPrice).font(.headline)
                    Text(billingPeriod(product)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(purchasesBusy)
        .accessibilityIdentifier("peel.pro.purchase.\(product.id)")
    }

    private func planName(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "Lifetime Pro" }
        switch period.unit {
        case .month where period.value == 1: return "Monthly Pro"
        case .year where period.value == 1: return "Yearly Pro"
        default: return product.displayName
        }
    }

    private func billingPeriod(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "one-time payment" }
        switch period.unit {
        case .month where period.value == 1: return "per month"
        case .year where period.value == 1: return "per year"
        default: return "auto-renewing"
        }
    }

    @ViewBuilder
    private var purchaseStatus: some View {
        if !store.hasResolvedAccessState {
            ProgressView("Checking purchases…")
        } else if store.hasLifetimeUnlock {
            Label("Lifetime Pro is active", systemImage: "checkmark.seal.fill")
                .accessibilityIdentifier("peel.pro.active")
            if store.hasAISubscription {
                Text("You also have an active subscription. Use Manage Subscriptions to avoid future subscription charges.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if store.hasAISubscription {
            Label(store.aiSubscriptionState.userMessage, systemImage: "checkmark.seal.fill")
                .accessibilityIdentifier("peel.pro.active")
        } else if store.isTrialActive {
            Label("Your Peel Pro trial is active", systemImage: "clock")
                .accessibilityIdentifier("peel.pro.active")
        }
    }
}
