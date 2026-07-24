import Foundation
import Network

public struct DiscoveredReceiver: Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let endpoint: NWEndpoint
    public let pairingAvailable: Bool
    public let protocolVersion: UInt16

    public init?(endpoint: NWEndpoint, txtRecord: NWTXTRecord) {
        guard let id = txtRecord["id"], !id.isEmpty,
              let displayName = txtRecord["name"], !displayName.isEmpty,
              let versionText = txtRecord["version"],
              let protocolVersion = UInt16(versionText),
              protocolVersion == SyncConstants.protocolVersion
        else {
            return nil
        }
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.pairingAvailable = txtRecord["pairing"] == "1"
        self.protocolVersion = protocolVersion
    }
}

public final class BonjourDiscovery: @unchecked Sendable {
    private let serviceType: String
    private let requireWiFi: Bool
    private let queue = DispatchQueue(label: "com.shuk.iphonesync.discovery")
    private let lock = NSLock()
    private var browser: NWBrowser?

    public init(
        serviceType: String = SyncConstants.normalServiceType,
        requireWiFi: Bool = true
    ) {
        self.serviceType = serviceType
        self.requireWiFi = requireWiFi
    }

    public func receivers() -> AsyncStream<[DiscoveredReceiver]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            if requireWiFi {
                parameters.requiredInterfaceType = .wifi
            }
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                using: parameters
            )
            replaceBrowser(with: browser)

            browser.browseResultsChangedHandler = { results, _ in
                let receivers = results.compactMap { result -> DiscoveredReceiver? in
                    guard case let .bonjour(txtRecord) = result.metadata else { return nil }
                    return DiscoveredReceiver(endpoint: result.endpoint, txtRecord: txtRecord)
                }.sorted {
                    if $0.displayName == $1.displayName { return $0.id < $1.id }
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                continuation.yield(receivers)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { [weak self, weak browser] _ in
                guard let browser else { return }
                self?.stop(browser)
            }
            browser.start(queue: queue)
        }
    }

    public func stop() {
        lock.lock()
        let current = browser
        browser = nil
        lock.unlock()
        current?.cancel()
    }

    private func replaceBrowser(with newBrowser: NWBrowser) {
        lock.lock()
        let previous = browser
        browser = newBrowser
        lock.unlock()
        previous?.cancel()
    }

    private func stop(_ target: NWBrowser) {
        lock.lock()
        if browser === target {
            browser = nil
        }
        lock.unlock()
        target.cancel()
    }
}
