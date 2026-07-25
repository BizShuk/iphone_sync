// ReceiverController — owns the normal-sync Bonjour listener lifecycle:
// startup, exponential-backoff retry, force-restart, reconcile-on-recovery.
// Mirrors `apps/macos/Sources/ReceiverController.swift`.

import { EventEmitter } from 'node:events';
import { SyncConstants } from '../protocol/constants.js';
import { TlsPskServer } from '../crypto/tls-psk-server.js';
import { BonjourAdvertise } from '../discovery/bonjour-advertise.js';
import { DestinationStorageMode, type DestinationStorageModeType } from './destination-storage-mode.js';
import { OperationLogBuffer, type OperationLogLevel } from '../logging/operation-log.js';

export interface PairedPeer {
  psk: Uint8Array;
  pskIdentity: Uint8Array;
  sourceBindingID: string;
  displayName: string;
}

export interface ReceiverControllerOptions {
  receiverID: string;
  displayName: string;
  pskLookup: (identity: string) => Uint8Array | null;
  operationLog: OperationLogBuffer;
}

export interface ReceiverConfiguration {
  destination: string;
  peer: PairedPeer;
  storageMode: DestinationStorageModeType;
  sourceBindingID: string;
  displayName: string;
}

export class ReceiverController extends EventEmitter {
  private readonly pskServer: TlsPskServer;
  private readonly advertisement: BonjourAdvertise;
  private configuration: ReceiverConfiguration | null = null;
  private listenerActive = false;
  private listenerRetryAttempt = 0;
  private listenerRetryTask: NodeJS.Timeout | null = null;
  private listenerRetryToken: symbol | null = null;

  constructor(private readonly options: ReceiverControllerOptions) {
    super();
    this.pskServer = new TlsPskServer({
      pskLookup: options.pskLookup,
      onConnection: () => {
        // Session-level wiring lands in Phase 4 (SyncServerSession).
      },
    });
    this.advertisement = new BonjourAdvertise({
      serviceType: SyncConstants.normalServiceType,
      port: 0, // updated below when listener is ready
      id: options.receiverID,
      name: options.displayName,
      pairing: false,
    });
  }

  async startReceiver(config: ReceiverConfiguration): Promise<void> {
    const changed = this.configuration === null
      || JSON.stringify(this.configuration) !== JSON.stringify(config);
    if (!changed && this.listenerActive) return;
    this.configuration = config;
    this.cancelRetry(true);
    await this.startListener();
  }

  async reconcileReceiver(forceRestart = false): Promise<void> {
    if (forceRestart) this.cancelRetry(true);
    if (this.listenerActive) return;
    if (this.configuration) await this.startListener();
  }

  stopReceiver(): void {
    this.cancelRetry(true);
    this.configuration = null;
    this.listenerActive = false;
    void this.pskServer.close();
    this.advertisement.stop();
    this.emit('runtimeState', { kind: 'ready' });
  }

  isPairingWindowOpen = false;

  private async startListener(): Promise<void> {
    if (!this.configuration) return;
    try {
      const port = await this.pskServer.listen();
      this.listenerActive = true;
      this.listenerRetryAttempt = 0;
      this.advertisement.stop();
      Object.assign(this.advertisement, {
        port,
        id: this.options.receiverID,
        name: this.configuration.displayName,
        pairing: false,
      });
      this.advertisement.start();
      this.emitEvent('success', 'Receiver', 'Receiver is ready for the paired iPhone.');
      this.emit('runtimeState', { kind: 'ready' });
    } catch (err) {
      this.emitEvent('error', 'Receiver', `Failed to start listener: ${(err as Error).message}`);
      this.scheduleRetry();
    }
  }

  private scheduleRetry(): void {
    if (!this.configuration || this.listenerRetryTask !== null) return;
    if (this.listenerRetryAttempt >= SyncConstants.maximumListenerRetryAttempts) return;
    const attempt = this.listenerRetryAttempt + 1;
    this.listenerRetryAttempt = attempt;
    const delay = Math.min(
      Math.pow(2, attempt - 1),
      SyncConstants.maximumListenerRetryDelaySeconds,
    );
    const token = Symbol('retry');
    this.listenerRetryToken = token;
    this.emitEvent('warning', 'Receiver', `Scheduled listener retry ${attempt} in ${delay}s.`);
    this.listenerRetryTask = setTimeout(() => {
      this.listenerRetryTask = null;
      if (this.listenerRetryToken !== token) return;
      this.listenerRetryToken = null;
      void this.startListener();
    }, delay * 1000);
  }

  private cancelRetry(resetAttempt: boolean): void {
    if (this.listenerRetryTask) {
      clearTimeout(this.listenerRetryTask);
      this.listenerRetryTask = null;
    }
    this.listenerRetryToken = null;
    if (resetAttempt) this.listenerRetryAttempt = 0;
  }

  private emitEvent(
    level: OperationLogLevel,
    category: string,
    message: string,
  ): void {
    this.options.operationLog.record({ level, category, message });
    this.emit('event', { level, category, message });
  }
}
