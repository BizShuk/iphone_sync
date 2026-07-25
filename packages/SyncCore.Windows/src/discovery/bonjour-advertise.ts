// BonjourAdvertise — RFC 6762/6763 responder that publishes the receiver
// service over multicast-dns with TXT `{ id, name, version: '1', pairing }`.
// Mirrors the TXT construction in `apps/macos/Sources/ReceiverController.swift`
// `startNormalListener(...)`.

import { createSocket, type Socket as UdpSocket } from 'node:dgram';

export interface AdvertiseOptions {
  serviceType: string;
  port: number;
  id: string;
  name: string;
  pairing: boolean;
}

interface DnsPacketClass {
  encode(obj: Record<string, unknown>): Buffer;
  decode(buf: Buffer): Record<string, unknown>;
  RECURSION_DESIRED: number;
  AUTHORITATIVE_ANSWER: number;
}

function loadPacket(): DnsPacketClass {
  // The runtime dns-packet default export is a class with static helpers;
  // @types/dns-packet does not declare these to keep the surface typed.
  // eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-explicit-any
  return require('dns-packet');
}

export class BonjourAdvertise {
  private socket: UdpSocket | null = null;
  private readonly PacketClass = loadPacket();

  constructor(private readonly options: AdvertiseOptions) {}

  start(): void {
    const socket = createSocket({ type: 'udp4', reuseAddr: true });
    socket.on('message', (msg) => {
      try {
        const decoded = this.PacketClass.decode(msg) as { questions?: Array<{ name: string }> };
        if (decoded.questions && decoded.questions.length > 0) {
          const want = decoded.questions.some((q) => q.name === this.options.serviceType);
          if (want) this.sendResponse(socket);
        }
      } catch {
        // ignore
      }
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
    const txtBuffer = encodeTxt({
      id: this.options.id,
      name: this.options.name,
      version: '1',
      pairing: this.options.pairing ? '1' : '0',
    });
    const response = this.PacketClass.encode({
      type: 'response',
      id: 0,
      flags: this.PacketClass.AUTHORITATIVE_ANSWER,
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
          data: txtBuffer,
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
  const chunks: Buffer[] = [];
  for (const [k, v] of Object.entries(parts)) {
    const text = `${k}=${v}`;
    const buf = Buffer.from(text, 'utf-8');
    if (buf.length > 255) continue; // TXT labels are max 255 bytes
    chunks.push(Buffer.from([buf.length]));
    chunks.push(buf);
  }
  return Buffer.concat(chunks);
}
