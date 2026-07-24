import SwiftUI
import SyncCore

struct SetupView: View {
    @Bindable var model: MacAppModel

    var body: some View {
        Form {
            statusSection
            if let summary = model.lastSummary {
                lastSyncSection(summary: summary)
            }
            operationLogSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 580, minHeight: 620)
        .task { await model.bootstrap() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(Tokens.Palette.wire)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let peer = model.pairedPeer {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.system(size: 22))
                                .foregroundStyle(Tokens.Palette.wire)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("iPhone \(peer.displayName)")
                                        .font(Tokens.Typography.body.weight(.semibold))
                                    Image(systemName: pairedIPhoneConnectionIcon)
                                        .foregroundStyle(pairedIPhoneConnectionTint)
                                        .font(.system(size: 11))
                                }
                                Text(peer.id)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .monospaced()
                                if let statusText = pairedIPhoneStatusText {
                                    Text(statusText)
                                        .font(Tokens.Typography.caption)
                                        .foregroundStyle(pairedIPhoneConnectionTint)
                                }
                            }
                            Spacer()
                            if model.pairedPeer != nil {
                                Button("Forget iPhone") {
                                    model.forgetPhone()
                                }
                                .buttonStyle(.bordered)
                                .tint(Tokens.Palette.alert)
                                .controlSize(.small)
                                .help("Forget paired iPhone")
                                .padding(.leading, 8)
                            }
                        }
                    } else {
                        Text("Not paired")
                            .font(Tokens.Typography.body.weight(.semibold))
                        Text("Choose a Mac on the same Wi-Fi to begin.")
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.pairedPeer == nil {
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Pair iPhone", action: model.openPairingWindow)
                    .disabled(model.destinationURL == nil)
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if let info = pairingInfo {
                PairingCodeDisplay(
                    code: info.code,
                    expiresAt: info.expiresAt,
                    remainingAttempts: 5,
                    totalAttempts: 5
                )
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                        .fill(Tokens.Palette.paper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Layout.cardCornerRadius)
                        .stroke(Tokens.Palette.signal, lineWidth: 1.5)
                )
                .padding(.vertical, 8)
            }

            if case let .error(message) = model.state {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Palette.alert)
                    Text(message)
                        .font(Tokens.Typography.callout)
                        .foregroundStyle(Tokens.Palette.alert)
                }
            }
        } header: {
            HStack(spacing: 8) {
                sectionHeader("Status")
                Spacer(minLength: 8)
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .scaleEffect(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var pairingInfo: (code: String, expiresAt: Date)? {
        if case let .pairing(code, expiresAt) = model.state {
            return (code, expiresAt)
        }
        return nil
    }

    private var pairedIPhoneConnectionIcon: String {
        isPairedIPhoneReady ? "circle.fill" : "xmark.circle.fill"
    }

    private var pairedIPhoneConnectionTint: Color {
        isPairedIPhoneReady ? Tokens.Palette.verified : Tokens.Palette.alert
    }

    private var isPairedIPhoneReady: Bool {
        model.pairedPeer != nil && (model.state == .ready || model.state == .receiving)
    }

    private var pairedIPhoneStatusText: String? {
        isPairedIPhoneReady ? nil : "Not connected"
    }

    // MARK: Last Sync

    private func lastSyncSection(summary: SyncSummary) -> some View {
        Section {
            HStack(spacing: 16) {
                summaryStat(label: "Added", value: summary.added)
                summaryStat(label: "Already", value: summary.existing)
                summaryStat(label: "Not local", value: summary.notLocal)
                summaryStat(label: "Failed", value: summary.failed)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lastSyncAccessibilityLabel(summary: summary))
        } header: {
            sectionHeader("Last Sync")
        }
    }

    private func summaryStat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Tokens.Typography.numericData)
                .foregroundStyle(Tokens.Palette.wire)
            Text(label)
                .font(Tokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastSyncAccessibilityLabel(summary: SyncSummary) -> String {
        "Last sync: \(summary.added) added, "
            + "\(summary.existing) already present, "
            + "\(summary.notLocal) not on iPhone, "
            + "\(summary.failed) failed."
    }

    // MARK: Operation Log

    private var operationLogSection: some View {
        Section {
            HStack {
                Text(
                    model.operationLog.isEmpty
                        ? "No operations recorded"
                        : "\(model.operationLog.count) recorded"
                )
                .font(Tokens.Typography.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") { model.copyOperationLog() }
                    .disabled(model.operationLog.isEmpty)
                    .buttonStyle(.borderless)
                    .font(Tokens.Typography.caption)
                Button("Clear") { model.clearOperationLog() }
                    .disabled(model.operationLog.isEmpty)
                    .buttonStyle(.borderless)
                    .font(Tokens.Typography.caption)
            }

            Text(
                "Keeps the latest \(OperationLogBuffer.defaultCapacity) semantic "
                    + "operations for this app run. Secrets, pairing codes, and "
                    + "full destination paths are not recorded."
            )
            .font(Tokens.Typography.caption)
            .foregroundStyle(.secondary)

            if !model.operationLog.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.operationLog) { entry in
                            MacOperationLogRow(entry: entry)
                            Rectangle()
                                .fill(Tokens.Palette.frame)
                                .frame(height: Tokens.Layout.hairline)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        } header: {
            sectionHeader("Operation Log")
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Typography.sectionHeader)
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

private struct MacOperationLogRow: View {
    let entry: OperationLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(
                entry.occurredAt.formatted(date: .omitted, time: .standard)
            )
            .font(Tokens.Typography.numericData)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.category)
                    .font(Tokens.Typography.callout.weight(.medium))
                    .foregroundStyle(Tokens.Palette.wire)
                Text(entry.message)
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: symbolName)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(tint.opacity(0.4), lineWidth: 1)
                )
                .accessibilityLabel(entry.level.rawValue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.category). \(entry.message)"
        )
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
