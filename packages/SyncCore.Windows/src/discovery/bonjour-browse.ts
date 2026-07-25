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
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import Packet from 'dns-packet';
// Re-import the namespace under a different name to avoid clashing with
// the default class export.
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import type { Answer } from 'dns-packet';
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
        // The runtime `dns-packet` default export is a class; we use a
        // structural decode without taking a hard dependency on its
        // specific TS shape (the @types/dns-packet types intentionally
        // omit the runtime helpers).
        const decoded = this.decode(msg);
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

  private decode(buf: Buffer): { answers: Array<Answer>; additionals: Array<Answer> } {
    // We delegate to the runtime class' static decode. Casting to `any`
    // is intentional: @types/dns-packet does not declare the runtime
    // helper `decode`, only the static-side type aliases.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const PacketClass: any = require('dns-packet');
    return PacketClass.decode(buf) as { answers: Array<Answer>; additionals: Array<Answer> };
  }

  private encodeQuery(): Buffer {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const PacketClass: any = require('dns-packet');
    return PacketClass.encode({
      type: 'query',
      id: 0,
      flags: PacketClass.RECURSION_DESIRED,
      questions: [{ name: this.serviceType, type: 'PTR', class: 'IN' }],
    }) as Buffer;
  }

  private sendQuery(socket: UdpSocket): void {
    const query = this.encodeQuery();
    socket.send(query, 0, query.length, 5353, '224.0.0.251');
  }

  private handlePacket(decoded: { answers?: Array<Answer>; additionals?: Array<Answer> }): void {
    const answers = (decoded.answers ?? []) as Array<Answer>;
    const additionals = (decoded.additionals ?? []) as Array<Answer>;
    const all = [...answers, ...additionals];

    const txtByName = new Map<string, Record<string, string>>();
    let ptrName: string | null = null;
    for (const record of all) {
      if (record.type === 'PTR' && (record as { name?: string }).name === this.serviceType) {
        ptrName = String((record as { data?: unknown }).data ?? '');
      }
      if (record.type === 'TXT') {
        const data = (record as { data?: Buffer }).data;
        const txt = parseTxt(data);
        txtByName.set(String((record as { name?: string }).name ?? ''), txt);
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
): Record<string, string> {
  if (!data) return {};
  // TXT records concatenate length-prefixed strings.
  const out: Record<string, string> = {};
  let offset = 0;
  while (offset < data.length) {
    const len = data[offset]!;
    offset += 1;
    if (offset + len > data.length) break;
    const part = data.slice(offset, offset + len).toString('utf-8');
    offset += len;
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    out[part.slice(0, eq)] = part.slice(eq + 1);
  }
  return out;
}
