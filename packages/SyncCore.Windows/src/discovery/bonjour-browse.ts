// BonjourBrowse — RFC 6762/6763 browse over multicast-dns on `_local.`,
// emitting a parsed `DiscoveredReceiver[]` as new mDNS responses arrive.
// Mirrors `packages/SyncCore/Sources/SyncCore/BonjourDiscovery.swift`:
//
//   - TXT keys: `id`, `name`, `version`, `pairing`.
//   - `version` must parse as `UInt16` and equal `SyncConstants.protocolVersion`.
//   - `pairing == "1"` ⇒ pairingAvailable; otherwise false.
//   - Result list is sorted by displayName, then by id.

import { EventEmitter } from 'node:events';
import { createSocket, type Socket as UdpSocket } from 'node:dgram';
import { packet, stringDecoder } from 'dns-packet';
import type { DecodedWithoutName } from 'dns-packet';
import { SyncConstants } from '../protocol/constants.js';

export interface DiscoveredReceiver {
  id: string;
  name: string;
  version: number;
  pairingAvailable: boolean;
  host: string;
  port: number;
}

export class BonjourBrowse extends EventEmitter {
  private socket: UdpSocket | null = null;
  private known = new Map<string, DiscoveredReceiver>();

  constructor(private readonly serviceType: string = SyncConstants.normalServiceType) {
    super();
  }

  start(): void {
    if (this.socket) return;
    const socket = createSocket({ type: 'udp4', reuseAddr: true });
    socket.on('message', (msg) => {
      try {
        const decoded = packet.decode(msg) as DecodedWithoutName;
        this.handlePacket(decoded);
      } catch {
        // ignore malformed packets
      }
    });
    socket.on('error', () => {
      // best-effort; recovery is via the next periodic re-browse
    });
    socket.bind(5353, '224.0.0.251', () => {
      socket.addMembership('224.0.0.251');
      this.sendQuery(socket);
      // Re-query every 15s; receivers are 1h TTL but we don't need long-lived state.
      const interval = setInterval(() => this.sendQuery(socket), 15_000);
      interval.unref();
    });
    this.socket = socket;
  }

  stop(): void {
    if (this.socket) {
      this.socket.close();
      this.socket = null;
    }
    this.known.clear();
  }

  private sendQuery(socket: UdpSocket): void {
    const query = packet.encode({
      type: 'query',
      id: 0,
      flags: packet.RECURSION_DESIRED,
      questions: [{ name: this.serviceType, type: 'PTR', class: 'IN' }],
    });
    socket.send(query, 0, query.length, 5353, '224.0.0.251');
  }

  private handlePacket(decoded: DecodedWithoutName): void {
    const answers = (decoded.answers ?? []) as Array<Record<string, unknown>>;
    const additionals = (decoded.additionals ?? []) as Array<Record<string, unknown>>;
    const all = [...answers, ...additionals];

    const txtByName = new Map<string, Record<string, string>>();
    let ptrName: string | null = null;
    for (const record of all) {
      if (record.type === 'PTR' && record.name === this.serviceType) {
        ptrName = String(record.data ?? '');
      }
      if (record.type === 'TXT') {
        const decoder = stringDecoder as unknown as (buf: Buffer) => string[];
        const txt = parseTxt(record.data as Buffer, decoder);
        txtByName.set(String(record.name ?? ''), txt);
      }
    }
    if (!ptrName) ptrName = this.serviceType;
    const txt = txtByName.get(ptrName);
    if (!txt) return;

    const id = txt.id;
    const name = txt.name;
    const versionRaw = txt.version;
    if (!id || !name || !versionRaw) return;
    const version = Number(versionRaw);
    if (!Number.isFinite(version) || version !== SyncConstants.protocolVersion) return;
    const pairingAvailable = txt.pairing === '1';

    const receiver: DiscoveredReceiver = {
      id,
      name,
      version,
      pairingAvailable,
      host: '',
      port: 0,
    };
    this.known.set(id, receiver);
    const list = Array.from(this.known.values()).sort((a, b) => {
      const byName = a.name.localeCompare(b.name);
      return byName !== 0 ? byName : a.id.localeCompare(b.id);
    });
    this.emit('change', list);
  }
}

function parseTxt(
  data: Buffer | undefined,
  decoder: (buf: Buffer) => string[],
): Record<string, string> {
  if (!data) return {};
  const parts = decoder(data);
  const out: Record<string, string> = {};
  for (const part of parts) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    out[part.slice(0, eq)] = part.slice(eq + 1);
  }
  return out;
}
