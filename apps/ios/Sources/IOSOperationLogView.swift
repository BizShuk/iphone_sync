import SwiftUI
import SyncCore

struct IOSOperationLogSection: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        Section {
            if model.operationLog.isEmpty {
                Text("No operations recorded")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.operationLog.prefix(3))) { entry in
                    IOSOperationLogRow(entry: entry)
                }
                NavigationLink {
                    IOSOperationLogView(model: model)
                } label: {
                    LabeledContent(
                        "View all operations",
                        value: String(model.operationLog.count)
                    )
                }
                Button("Clear Log", role: .destructive) {
                    model.clearOperationLog()
                }
            }
        } header: {
            Text("Operation Log")
        } footer: {
            Text(
                "Keeps the latest \(OperationLogBuffer.defaultCapacity) "
                    + "semantic operations for this app run. Secrets and pairing codes "
                    + "are never included."
            )
        }
    }
}

private struct IOSOperationLogView: View {
    @Bindable var model: IOSAppModel

    var body: some View {
        List {
            ForEach(model.operationLog) { entry in
                IOSOperationLogRow(entry: entry)
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
        .overlay {
            if model.operationLog.isEmpty {
                ContentUnavailableView(
                    "No Operations",
                    systemImage: "list.bullet.rectangle",
                    description: Text(
                        "App, pairing, discovery, sync, album, and resource "
                            + "operations will appear here."
                    )
                )
            }
        }
    }
}

private struct IOSOperationLogRow: View {
    let entry: OperationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityLabel(entry.level.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.category)
                        .font(.subheadline)
                    Spacer()
                    Text(
                        entry.occurredAt.formatted(
                            date: .omitted,
                            time: .standard
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var symbolName: String {
        switch entry.level {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch entry.level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
