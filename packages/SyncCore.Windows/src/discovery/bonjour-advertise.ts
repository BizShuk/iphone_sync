// BonjourAdvertise — RFC 6762/6763 responder that publishes the receiver
// service over multicast-dns with TXT `{ id, name, version: '1', pairing }`.
// Mirrors the TXT construction in `apps/macos/Sources/ReceiverController.swift`
// `startNormalListener(...)`.

import { createSocket, type Socket as UdpSocket } from 'node:dgram';
import { packet, stringEncoder } from 'dns-packet';

export interface AdvertiseOptions {
  serviceType: string;
  port: number;
  id: string;
  name: string;
  pairing: boolean;
}

export class BonjourAdvertise {
  private socket: UdpSocket | null = null;

  constructor(private readonly options: AdvertiseOptions) {}

  start(): void {
    const socket = createSocket({ type: 'udp4', reuseAddr: true });
    socket.on('message', (msg, rinfo) => {
      try {
        const decoded = packet.decode(msg) as { questions?: Array<{ name: string; type: string }> };
        if (decoded.questions && decoded.questions.length > 0) {
          const want = decoded.questions.some((q) => q.name === this.options.serviceType);
          if (want) this.sendResponse(socket);
        }
      } catch {
        // ignore
      }
      void rinfo;
    });
    socket.bind(5353, () => {
      socket.addMembership('224.0.0.251');
      this.sendResponse(socket);
    });
    this.socket = socket;
  }

  stop(): void {
    if (this.socket) {
      this.socket.close();
      this.socket = null;
    }
  }

  private sendResponse(socket: UdpSocket): void {
    const txtData = encodeTxt({
      id: this.options.id,
      name: this.options.name,
      version: '1',
      pairing: this.options.pairing ? '1' : '0',
    });
    const response = packet.encode({
      type: 'response',
      id: 0,
      flags: packet.AUTHORITATIVE_ANSWER,
      answers: [
        {
          name: this.options.serviceType,
          type: 'PTR',
          class: 'IN',
          ttl: 4500,
          data: this.options.serviceType,
        },
        {
          name: this.options.serviceType,
          type: 'TXT',
          class: 'IN',
          ttl: 4500,
          data: txtData,
        },
        {
          name: this.options.serviceType,
          type: 'SRV',
          class: 'IN',
          ttl: 4500,
          data: { priority: 0, weight: 0, port: this.options.port, target: 'localhost.' },
        },
      ],
    });
    socket.send(response, 0, response.length, 5353, '224.0.0.251');
  }
}

function encodeTxt(parts: Record<string, string>): Buffer {
  const entries = Object.entries(parts).map(([k, v]) => `${k}=${v}`);
  const encoder = stringEncoder as unknown as (strs: string[]) => Buffer;
  return encoder(entries);
}
