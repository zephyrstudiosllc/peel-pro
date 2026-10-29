import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func chatGPTProLimitsSection(input: Input) -> ProviderDetailSection? {
        // Provider-specific by design: Shares Codex's trusted ChatGPT web account, independent of API billing.
        guard input.provider == .codex, input.chatGPTProLimitsEnabled else { return nil }
        let snapshot = input.codexProjection?.chatGPTModelLimits
        let rows: [ProviderDetailSection.Row]
        if let snapshot, !snapshot.models.isEmpty {
            let stale = input.now.timeIntervalSince(snapshot.updatedAt) > 15 * 60
            rows = snapshot.models.compactMap { model in
                let value: String
                let detail: String
                if stale {
                    value = "Unavailable"
                    detail = "Refresh needed"
                } else if let reset = model.resetsAt, reset > input.now {
                    value = "Limit reached"
                    switch input.resetTimeDisplayStyle {
                    case .countdown:
                        detail = "Resets \(UsageFormatter.resetCountdownDescription(from: reset, now: input.now))"
                    case .absolute:
                        detail = "Resets \(reset.formatted(date: .abbreviated, time: .shortened))"
                    }
                } else {
                    value = "Count unavailable"
                    detail = model.resetsAt == nil ? "Reset time unavailable" : "Reset passed; refresh needed"
                }
                return try? ProviderDetailSection.Row(label: model.title, value: value, secondaryValue: detail)
            }
        } else {
            rows = ["GPT-6 Pro", "GPT-5.6 Pro"].compactMap { title in
                try? ProviderDetailSection.Row(
                    label: title,
                    value: snapshot == nil ? "Unavailable" : "Not reported",
                    secondaryValue: snapshot == nil ? "Check OpenAI web connection" : "Not in ChatGPT's model catalog")
            }
        }
        return try? ProviderDetailSection(title: "ChatGPT Pro limits", rows: rows)
    }
}
