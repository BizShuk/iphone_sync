import SwiftUI

/// One paired computer: host icon, last connection time, its own albums.
struct ReceiverCardView: View {
    let profile: ReceiverProfile
    let isStale: Bool
    let actionsEnabled: Bool
    let chooseAlbums: () -> Void
    let forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(isStale ? Tokens.Palette.alert : Tokens.Palette.wire)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(Tokens.Typography.body.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.wire)
                        .lineLimit(1)
                    Text("Last connected \(lastConnectedText)")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(albumsText)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isStale {
                        Text(
                            "Not synced for 14+ days. Skipped in the deletion "
                                + "check when another computer has the photo."
                        )
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.alert)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Choose Albums", action: chooseAlbums)
                    .buttonStyle(.bordered)
                    .tint(Tokens.Palette.signal)
                    .disabled(!actionsEnabled)
                Button("Forget", action: forget)
                    .buttonStyle(.bordered)
                    .tint(Tokens.Palette.alert)
                    .disabled(!actionsEnabled)
            }
        }
        .padding(Tokens.Layout.cardPadding)
        .background(Tokens.Palette.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                .stroke(Tokens.Palette.frame, lineWidth: Tokens.Layout.hairline)
        )
        .accessibilityElement(children: .contain)
    }

    private var lastConnectedText: String {
        guard let date = profile.lastConnectedAt else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }

    private var albumsText: String {
        let total = profile.albums.reduce(0) { $0 + $1.assetCount }
        switch profile.albums.count {
        case 0: return "No albums selected."
        case 1: return "\(profile.albums[0].title) · \(total.formatted()) photos"
        default: return "\(profile.albums.count) albums · \(total.formatted()) photos"
        }
    }
}
