import SwiftUI
import SyncCore

/// Full Operation Log sheet — opened from the Operation Log card on
/// the iPhone main view.
struct IOSOperationLogView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.operationLog.isEmpty {
                    ContentUnavailableView(
                        "No Operations",
                        systemImage: "list.bullet.rectangle",
                        description: Text(
                            "App, pairing, discovery, sync, album, and resource "
                                + "operations will appear here."
                        )
                    )
                } else {
                    List {
                        ForEach(model.operationLog) { entry in
                            IOSOperationLogRow(entry: entry)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Operation Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        model.clearOperationLog()
                    }
                    .disabled(model.operationLog.isEmpty)
                }
            }
        }
    }
}

struct IOSOperationLogRow: View {
    let entry: OperationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(tint.opacity(0.4), lineWidth: 1)
                )
                .accessibilityLabel(entry.level.rawValue)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.category)
                        .font(Tokens.Typography.callout.weight(.medium))
                        .foregroundStyle(Tokens.Palette.wire)
                    Spacer()
                    Text(
                        entry.occurredAt.formatted(
                            date: .omitted,
                            time: .standard
                        )
                    )
                    .font(Tokens.Typography.numericData)
                    .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.category). \(entry.message)")
    }

    private var symbolName: String {
        switch entry.level {
        case .info: "circle.fill"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }

    private var tint: Color {
        switch entry.level {
        case .info: Tokens.Palette.frame
        case .success: Tokens.Palette.verified
        case .warning: Tokens.Palette.alert
        case .error: Tokens.Palette.alert
        }
    }
}
