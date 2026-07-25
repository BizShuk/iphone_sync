// Pairing layer: 120-second pairing window + wire protocol helpers.

export { PairingServer, type PairingServerOptions } from './pairing-server.js';
export {
  decodePairingMessage,
  encodePairingMessage,
  PairingProtocolError,
  type PairingHello,
  type PairingMessage,
} from './pairing-protocol.js';
