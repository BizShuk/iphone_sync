// SyncConstants — wire-level constants that MUST stay byte-for-byte aligned
// with `packages/SyncCore/Sources/SyncCore/SyncConstants.swift`.
//
// Updating any value here is a protocolVersion break; iOS sender must follow.

export const SyncConstants = {
  protocolVersion: 1 as const,

  // Bonjour service types. Browsed by iPhone Sync via `NWBrowser`; advertised
  // by receivers via their respective mDNS responders (Network.framework on
  // macOS, `multicast-dns` on Windows).
  normalServiceType: '_iphonesync._tcp',
  pairingServiceType: '_iphonesync-pair._tcp',

  // Frame size limits. Header check enforces these BEFORE deserialising the
  // payload to avoid unbounded allocation on malformed input.
  chunkSize: 1_048_576,            // 1 MiB
  maximumControlPayload: 65_536,   // 64 KiB
  checkpointSize: 16_777_216,      // 16 MiB

  // Pairing
  pairingWindowSeconds: 120,
  pairingMaxAttempts: 5,

  // Sync session opening deadline — receiver closes unauthenticated sockets
  // that haven't sent `.session(.request)` within this window.
  defaultOpeningTimeoutSeconds: 15,

  // PSK cipher; both sides must agree exactly.
  tlsPskCipherSuite: 'TLS_PSK_WITH_AES_128_GCM_SHA256',
  tlsPskCipherSuiteAlias: 'PSK-AES128-GCM-SHA256', // accepted by Node OpenSSL backend

  // HKDF labels used during pairing to derive SAS / PSK / proofs / identity.
  // The trailing `-v1` suffix is the extension point for future bumps.
  hkdfLabels: {
    sas: 'iphonesync-sas-v1',
    psk: 'iphonesync-psk-v1',
    identity: 'iphonesync-identity-v1',
    clientProof: 'iphonesync-client-proof-v1',
    serverProof: 'iphonesync-server-proof-v1',
  },

  // Receiving container fixed name; never localised.
  receivingFolderName: 'iPhoneSync',

  // Partial file suffix.
  partialExtension: '.partial',

  // Operation log buffer capacity (mirrors `OperationLogBuffer.defaultCapacity`).
  operationLogCapacity: 500,

  // Listener retry policy (mirrors `ReceiverController.maximumListenerRetryAttempts`
  // and `maximumListenerRetryDelay`).
  maximumListenerRetryAttempts: 5,
  maximumListenerRetryDelaySeconds: 16,
} as const;

export type SyncConstantsType = typeof SyncConstants;
