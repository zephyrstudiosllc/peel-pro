import SwiftUI

/// Actual bundled license texts, available offline in each Apple client.
public struct PeelShellNoticesView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            Text(notices)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Open-source notices")
    }

    private var notices: String {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License notices could not be loaded."
        }
        return text
    }
}
