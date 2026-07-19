import Network
import Testing
@testable import SyncCore

@Test
func discoveredReceiverParsesCompatibleTXTRecord() throws {
    let endpoint = NWEndpoint.service(
        name: "mac-1",
        type: SyncConstants.normalServiceType,
        domain: "local.",
        interface: nil
    )
    let receiver = try #require(DiscoveredReceiver(
        endpoint: endpoint,
        txtRecord: NWTXTRecord([
            "id": "mac-1",
            "name": "Studio Mac",
            "pairing": "0",
            "version": String(SyncConstants.protocolVersion),
        ])
    ))

    #expect(receiver.id == "mac-1")
    #expect(receiver.displayName == "Studio Mac")
    #expect(!receiver.pairingAvailable)
    #expect(receiver.endpoint == endpoint)
}

@Test
func discoveredReceiverRejectsUnsupportedProtocol() {
    let receiver = DiscoveredReceiver(
        endpoint: .hostPort(host: "127.0.0.1", port: 9000),
        txtRecord: NWTXTRecord([
            "id": "mac-1",
            "name": "Studio Mac",
            "version": "999",
        ])
    )

    #expect(receiver == nil)
}
