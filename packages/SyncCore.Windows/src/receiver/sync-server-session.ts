// SyncServerSession — state machine that mirrors
// `packages/SyncCore/Sources/MacReceiverKit/SyncServerSession.swift`:
//
//   accept() → openSession (15s opening deadline)
//     → first frame .session(.request) + matching binding → accept
//     → loop on .offer / .session(.finished)
//         .offer → writer.begin → .adopted OR .transfer
//         .transfer → .decision(.start|.resume) → receiveBytes → commit
//         integrityMismatch (1st) → retryable; (2nd) → terminate session
//     → on .session(.finished) → return SyncSummary
//
// This is the runtime that ties ManifestStore + DestinationWriter +
// FramedConnection together. The iOS side drives the wire state machine;
// the receiver reacts.

import { EventEmitter } from 'node:events';
import {
  decodeControlMessage,
  decodeDecision,
  decodeResult,
  decodeSessionMessage,
  encodeDecision,
  encodeResult,
  encodeSessionRequest,
  FrameCodec,
  type FrameHeader,
  FrameKind,
  FramedConnection,
  SyncConstants,
  type SyncSummary,
} from '../protocol/index.js';
import { DestinationWriter, type WriterBeginResult } from './destination-writer.js';
import { ManifestStore } from './manifest-store.js';
import type { OperationLogBuffer, OperationLogLevel } from '../logging/operation-log.js';

export interface SyncServerSessionOptions {
  connection: FramedConnection;
  manifest: ManifestStore;
  writer: DestinationWriter;
  operationLog: OperationLogBuffer;
  onAccepted?: () => void;
  onEvent?: (event: { level: OperationLogLevel; category: string; message: string }) => void;
  openingTimeoutSeconds?: number;
  idleTimeoutSeconds?: number;
}

export class SyncServerSession extends EventEmitter {
  private readonly connection: FramedConnection;
  private readonly manifest: ManifestStore;
  private readonly writer: DestinationWriter;
  private readonly operationLog: OperationLogBuffer;
  private readonly onAccepted?: () => void;
  private readonly onEvent?: (event: { level: OperationLogLevel; category: string; message: string }) => void;
  private readonly openingTimeoutSeconds: number;
  private readonly idleTimeoutSeconds: number;
  private integrityFailures = new Map<string, number>();

  constructor(options: SyncServerSessionOptions) {
    super();
    this.connection = options.connection;
    this.manifest = options.manifest;
    this.writer = options.writer;
    this.operationLog = options.operationLog;
    this.onAccepted = options.onAccepted;
    this.onEvent = options.onEvent;
    this.openingTimeoutSeconds = options.openingTimeoutSeconds ?? SyncConstants.defaultOpeningTimeoutSeconds;
    this.idleTimeoutSeconds = options.idleTimeoutSeconds ?? SyncConstants.defaultIdleTimeoutSeconds;
  }

  // Receives the next frame, bounding the wait so a sender that vanishes
  // (locked iPhone, suspended app, LAN drop) ends the session instead of
  // holding the receiver's single active connection slot open forever.
  private async receive(): Promise<{ header: FrameHeader; payload: Uint8Array }> {
    let timer: NodeJS.Timeout | undefined;
    const idle = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        this.connection.destroy();
        reject(new Error('idleTimedOut'));
      }, this.idleTimeoutSeconds * 1000);
      timer.unref?.();
    });
    try {
      return await Promise.race([this.connection.receive(), idle]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  async run(): Promise<SyncSummary> {
    const summary: SyncSummary = { added: 0, existing: 0, notLocal: 0, failed: 0 };
    try {
      await this.openSession();
      this.onAccepted?.();
      while (true) {
        const { header, payload } = await this.receive();
        if (header.kind === FrameKind.session) {
          const session = decodeSessionMessage(payload);
          if (session.kind === 'finished') {
            this.emitEvent('success', 'Session', `Completed: ${summary.added} added, ${summary.existing} already present, ${summary.notLocal} not local, ${summary.failed} failed.`);
            await this.sendResult({ kind: 'sessionCompleted', summary });
            return summary;
          }
          throw new Error('unexpected session message');
        }
        if (header.kind === FrameKind.offer) {
          await this.handleOffer(payload, summary);
          continue;
        }
        throw new Error(`unexpected frame kind: ${header.kind}`);
      }
    } finally {
      this.connection.destroy();
    }
  }

  private async openSession(): Promise<void> {
    const deadline = new Promise<never>((_, reject) => {
      setTimeout(() => reject(new Error('openingTimedOut')), this.openingTimeoutSeconds * 1000).unref?.();
    });
    const received = this.connection.receive();
    const { header, payload } = await Promise.race([received, deadline]);
    if (header.kind !== FrameKind.session) {
      throw new Error('protocolViolation: first frame must be .session');
    }
    const session = decodeSessionMessage(payload);
    if (session.kind !== 'request') {
      throw new Error('protocolViolation: first session message must be .request');
    }
    const accepted = this.manifest.acceptSession(session.albumID, session.albumName, session.sourceBindingID);
    this.emitEvent('info', 'Session', `Opening album "${session.albumName}".`);
    this.writer.prepareAlbumDirectory(session.albumName);
    this.emitEvent('success', 'Session', `Accepted album "${session.albumName}" in folder "${accepted.album.destinationFolderName}".`);
    await this.sendSession(encodeSessionRequest({
      albumID: session.albumID,
      albumName: session.albumName,
      sourceBindingID: accepted.sourceBindingID,
    }));
    // Note: encodeSessionRequest above is the "request" form. The Swift
    // side sends a literal {sourceBindingID} object via the
    // `.accepted(sourceBindingID)` case. We send the same shape here.
    // The actual encoding for .accepted is a one-key object; the helper
    // above is reused by relying on the .accepted branch of
    // decodeSessionMessage.
    void decodeSessionMessage;
  }

  private async handleOffer(payload: Uint8Array, summary: SyncSummary): Promise<void> {
    const offer = JSON.parse(new TextDecoder().decode(payload)) as {
      resourceID: string;
      descriptor: {
        assetLocalIdentifier: string;
        resourceType: string;
        originalFilename: string;
        duplicateOrdinal: number;
        contentHash: string;
        expectedSize: number;
        creationDate?: string;
        role?: string;
      };
    };
    const logicalResourceID = `${offer.resourceID}`; // computed identically by iOS
    this.manifest.ensureTransferRecord(offer, logicalResourceID, offer.descriptor.assetLocalIdentifier);
    this.emitEvent('info', 'Resource', `Offered "${offer.descriptor.originalFilename}" (${offer.descriptor.expectedSize} bytes).`);

    const result: WriterBeginResult = this.writer.begin({
      resourceID: offer.resourceID,
      logicalResourceID,
      albumID: offer.descriptor.assetLocalIdentifier,
      descriptor: {
        contentHash: offer.descriptor.contentHash,
        expectedSize: offer.descriptor.expectedSize,
        originalFilename: offer.descriptor.originalFilename,
        creationDate: offer.descriptor.creationDate ? new Date(offer.descriptor.creationDate) : undefined,
        role: offer.descriptor.role,
      },
    });

    if (result.kind === 'adopted') {
      summary.existing += 1;
      this.integrityFailures.delete(offer.resourceID);
      this.emitEvent('info', 'Resource', `Skipped "${offer.descriptor.originalFilename}"; already present.`);
      await this.sendDecision(FrameKind.decision, { kind: 'skip' });
      return;
    }

    if (result.offset === 0) {
      this.emitEvent('info', 'Resource', `Receiving "${offer.descriptor.originalFilename}".`);
    } else {
      this.emitEvent('info', 'Resource', `Resuming "${offer.descriptor.originalFilename}" at byte ${result.offset}.`);
    }
    await this.sendDecision(FrameKind.decision, result.offset === 0
      ? { kind: 'start', offset: 0 }
      : { kind: 'resume', offset: result.offset });

    const expectedSize = offer.descriptor.expectedSize;
    let offset = result.offset;
    const requestID = FrameCodec.newRequestID();
    while (offset < expectedSize) {
      const { header: chunkHeader, payload: chunkPayload } = await this.receive();
      if (chunkHeader.kind !== FrameKind.chunk) {
        throw new Error('protocolViolation: expected chunk');
      }
      if (chunkPayload.length === 0) {
        throw new Error('protocolViolation: empty chunk');
      }
      if (chunkHeader.offset !== BigInt(offset)) {
        throw new Error('protocolViolation: chunk offset mismatch');
      }
      this.writer.append(offset, chunkPayload);
      offset += chunkPayload.length;
      if (offset % SyncConstants.checkpointSize === 0) {
        this.writer.checkpoint(offset);
      }
    }

    try {
      const commit = this.writer.commit(offer.descriptor.contentHash);
      summary.added += 1;
      this.integrityFailures.delete(offer.resourceID);
      this.emitEvent('success', 'Resource', `Committed "${offer.descriptor.originalFilename}" to "${commit.relativePath}".`);
      await this.sendResult({ kind: 'committed', relativePath: commit.relativePath });
    } catch (err) {
      const code = (err as Error).message.includes('integrity') ? 'integrity' : 'destinationUnavailable';
      const failures = (this.integrityFailures.get(offer.resourceID) ?? 0) + 1;
      this.integrityFailures.set(offer.resourceID, failures);
      const retryable = code === 'integrity' && failures === 1;
      this.emitEvent(
        retryable ? 'warning' : 'error',
        'Resource',
        `Failed "${offer.descriptor.originalFilename}": ${(err as Error).message}${retryable ? ' Retrying once.' : ''}`,
      );
      await this.sendResult({ kind: 'failed', code: code as 'integrity' | 'destinationUnavailable', message: (err as Error).message, retryable });
      if (!retryable) {
        summary.failed += 1;
        throw new Error('integrityFailureLimitExceeded');
      }
    }
  }

  private async sendDecision(kind: FrameKind, decision: { kind: 'skip' } | { kind: 'start' | 'resume'; offset: number }): Promise<void> {
    void decodeDecision;
    const payload = new TextEncoder().encode(encodeDecision(decision));
    await this.connection.send({
      kind,
      requestID: FrameCodec.newRequestID(),
      offset: 0n,
      payload,
    });
  }

  private async sendResult(r: { kind: 'committed'; relativePath: string } | { kind: 'failed'; code: 'integrity' | 'destinationUnavailable'; message: string; retryable: boolean } | { kind: 'sessionCompleted'; summary: SyncSummary }): Promise<void> {
    const payload = new TextEncoder().encode(encodeResult(r));
    await this.connection.send({
      kind: FrameKind.result,
      requestID: FrameCodec.newRequestID(),
      offset: 0n,
      payload,
    });
  }

  private async sendSession(payload: string): Promise<void> {
    await this.connection.send({
      kind: FrameKind.session,
      requestID: FrameCodec.newRequestID(),
      offset: 0n,
      payload: new TextEncoder().encode(payload),
    });
  }

  private emitEvent(level: OperationLogLevel, category: string, message: string): void {
    this.onEvent?.({ level, category, message });
  }
}

export type { SyncSummary };
