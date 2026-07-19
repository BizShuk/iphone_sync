import Foundation
import Network
import Security

public enum PSKRole: Sendable {
    case client
    case server
}

public enum PSKTLSParameters {
    public static func make(
        psk: Data,
        identity: Data,
        role: PSKRole,
        requireWiFi: Bool = true
    ) -> NWParameters {
        precondition(psk.count == 32, "TLS PSK must contain exactly 32 bytes")
        precondition(!identity.isEmpty, "TLS PSK identity must not be empty")

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            dispatchData(copying: psk),
            dispatchData(copying: identity)
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
        )

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        if role == .client, requireWiFi {
            parameters.requiredInterfaceType = .wifi
        }
        return parameters
    }

    private static func dispatchData(copying data: Data) -> dispatch_data_t {
        let wrapped = data.withUnsafeBytes { DispatchData(bytes: $0) }
        return wrapped as dispatch_data_t
    }
}
