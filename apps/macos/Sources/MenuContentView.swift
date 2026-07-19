import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: MacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.statusText, systemImage: model.statusSymbol)
                .font(.headline)

            if case let .pairing(code, expiresAt) = model.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(code)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                    Text("Expires \(expiresAt, style: .relative)")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Button("Open Setup") { openWindow(id: "setup") }
            Button("Pair New iPhone") { model.openPairingWindow() }
            Button("Choose Destination") { model.chooseDestination() }
            Button("Forget iPhone") { model.forgetPhone() }
                .disabled(model.pairedPeer == nil)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 260)
        .task { await model.bootstrap() }
    }
}
