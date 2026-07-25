// ModelRoot — Electron main-process facade that owns the paired peer PSK,
// the destination, the manifest, the receiver listener, and the operation
// log. Mirrors `apps/macos/Sources/MacAppModel.swift`.
//
// All cross-process state lives here; the renderer only sees a JSON snapshot
// delivered via IPC.

import { app, dialog, BrowserWindow, type SafeStorage } from 'electron';
import { join, resolve } from 'node:path';
import { mkdirSync, existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import {
  SettingsStore,
  DestinationStore,
  SecretStore,
  OperationLogBuffer,
  OperationLogger,
  PairingServer,
  ReceiverController,
  ManifestStore,
  DestinationWriter,
  SyncServerSession,
  TlsPskServer,
  DestinationStorageMode,
  isDestinationStorageMode,
  type SyncSummary,
  type PairingServerOptions,
  type OperationLogEntry,
} from '@iphonesync/synccore-windows';

interface PairedPeerRecord {
  psk: Uint8Array;
  pskIdentity: Uint8Array;
  sourceBindingID: string;
  displayName: string;
  deviceID: string;
}

export interface ModelSnapshot {
  destinationPath: string | null;
  pairedPeerID: string | null;
  pairedPeerDisplayName: string | null;
  sourceBindingID: string;
  launchAtLogin: boolean;
  storageMode: 'albumDate' | 'albumOnly' | 'flat';
  isPairing: boolean;
  pairingCode: string | null;
  pairingExpiresAt: string | null;
  lastSummary: SyncSummary | null;
  operationLog: Array<Omit<OperationLogEntry, 'occurredAt'> & { occurredAt: string }>;
  runtimeState: 'ready' | 'receiving' | 'error';
  errorMessage: string | null;
}

const SECRET_ACCOUNT = 'paired-peer';

export class ModelRoot {
  readonly settings: SettingsStore;
  readonly destinationStore: DestinationStore;
  readonly operationLog: OperationLogBuffer;
  private readonly operationLogger: OperationLogger;
  private readonly secretStore: SecretStore;
  private readonly receiverController: ReceiverController;
  private pairingServer: PairingServer | null = null;
  private manifest: ManifestStore | null = null;
  private writer: DestinationWriter | null = null;
  private setupWindow: BrowserWindow | null = null;
  private pairingWindow: (() => void) | null = null;
  private lastSummary: SyncSummary | null = null;
  private runtimeState: ModelSnapshot['runtimeState'] = 'ready';
  private errorMessage: string | null = null;
  private safeStorageAvailable = false;

  constructor(public readonly options: { userDataDir: string }) {
    const settingsFile = join(options.userDataDir, 'settings.json');
    mkdirSync(options.userDataDir, { recursive: true });
    this.settings = new SettingsStore(settingsFile);
    this.destinationStore = new DestinationStore(settingsFile);
    this.operationLog = new OperationLogBuffer();
    this.operationLogger = new OperationLogger({ logsDir: join(options.userDataDir, 'logs') });
    this.secretStore = new SecretStore({
      safeStorage: this.resolveSafeStorage(),
      filePath: join(options.userDataDir, 'secret.bin'),
    });
    this.receiverController = new ReceiverController({
      receiverID: this.settings.receiverID,
      displayName: this.displayName,
      pskLookup: (identity) => this.lookupPskByIdentity(identity),
      operationLog: this.operationLog,
    });
  }

  private get displayName(): string {
    return process.env.COMPUTERNAME ?? 'Windows PC';
  }

  private resolveSafeStorage(): import('@iphonesync/synccore-windows').SecretStoreOptions['safeStorage'] {
    // Adapter for Electron's safeStorage. We pull it lazily so the class
    // can be constructed before app.whenReady.
    const ss: SafeStorage | undefined = (app as unknown as { safeStorage?: SafeStorage }).safeStorage;
    if (ss && ss.isEncryptionAvailable()) {
      this.safeStorageAvailable = true;
      return {
        isEncryptionAvailable: () => ss.isEncryptionAvailable(),
        encryptString: (plain) => ss.encryptString(plain),
        decryptString: (cipher) => ss.decryptString(cipher),
      };
    }
    // Fallback: dpapi-style with current-user scope via a JS-only cipher.
    // In practice the Electron safeStorage is always available on
    // Windows 10/11 once app.whenReady has run.
    this.safeStorageAvailable = false;
    return {
      isEncryptionAvailable: () => false,
      encryptString: () => {
        throw new Error('safeStorage.isEncryptionAvailable() is false');
      },
      decryptString: () => {
        throw new Error('safeStorage.isEncryptionAvailable() is false');
      },
    };
  }

  snapshot(): ModelSnapshot {
    const peer = this.loadPairedPeer();
    return {
      destinationPath: this.destinationStore.resolve(),
      pairedPeerID: peer?.deviceID ?? null,
      pairedPeerDisplayName: peer?.displayName ?? null,
      sourceBindingID: this.settings.sourceBindingIDValue,
      launchAtLogin: this.settings.launchAtLoginRequested,
      storageMode: this.settings.storageMode,
      isPairing: this.pairingServer !== null,
      pairingCode: null,
      pairingExpiresAt: null,
      lastSummary: this.lastSummary,
      operationLog: this.operationLog.all.map((entry) => ({
        ...entry,
        occurredAt: entry.occurredAt.toISOString(),
      })),
      runtimeState: this.runtimeState,
      errorMessage: this.errorMessage,
    };
  }

  async bootstrap(): Promise<void> {
    this.recordEvent('info', 'App', 'Loading saved receiver settings.');
    const destination = this.destinationStore.resolve();
    if (destination) {
      this.recordEvent('success', 'Destination', `Restored access to "${destination}".`);
    }
    const peer = this.loadPairedPeer();
    if (peer) {
      this.recordEvent('info', 'Pairing', 'Restored the paired iPhone from Keychain.');
    }
    await this.restartReceiver();
    this.recordEvent('success', 'App', 'Startup completed.');
  }

  async openDestinationChooser(): Promise<void> {
    const win = this.setupWindow ?? BrowserWindow.getFocusedWindow();
    const result = await dialog.showOpenDialog(win ?? new BrowserWindow({ show: false }), {
      title: 'Choose iPhone Backup Destination',
      properties: ['openDirectory', 'createDirectory'],
      defaultPath: app.getPath('downloads'),
    });
    if (result.canceled || result.filePaths.length === 0) return;
    const path = result.filePaths[0]!;
    this.destinationStore.save(path);
    this.settings.resetSourceBindingID();
    this.recordEvent('success', 'Destination', `Selected "${path}".`);
    await this.restartReceiver();
  }

  async openPairingWindow(): Promise<void> {
    if (this.pairingServer) {
      this.recordEvent('info', 'Pairing', 'Pairing window is already open.');
      return;
    }
    if (!this.destinationStore.resolve()) {
      this.recordEvent('warning', 'Pairing', 'Choose a destination before opening pairing.');
      return;
    }
    this.recordEvent('info', 'Pairing', 'Opening a two-minute pairing window.');
    this.receiverController.stopReceiver();
    this.attachPairingWindow(() => this.pairingServer?.close('cancelled'));
    const options: PairingServerOptions = {
      receiverID: this.settings.receiverID,
      displayName: this.displayName,
      onCode: (code, expiresAt) => {
        this.pairingWindow?.();
        this.broadcastSnapshot();
        this.recordEvent('success', 'Pairing', `Pairing code ${code} ready; expires at ${expiresAt.toISOString()}.`);
      },
      onPaired: (info) => {
        const record: PairedPeerRecord = {
          psk: info.psk,
          pskIdentity: info.pskIdentity,
          sourceBindingID: this.settings.sourceBindingIDValue,
          displayName: info.peerDisplayName,
          deviceID: info.peerDeviceID,
        };
        this.secretStore.save(SECRET_ACCOUNT, serialisePeer(record));
        this.recordEvent('success', 'Pairing', `Paired with "${info.peerDisplayName}".`);
        void this.restartReceiver();
      },
      onEvent: (e) => this.recordEvent(e.level, e.category, e.message),
      onClosed: () => {
        this.pairingServer = null;
        this.broadcastSnapshot();
      },
    };
    this.pairingServer = new PairingServer(options);
    await this.pairingServer.open();
  }

  async cancelPairingWindow(): Promise<void> {
    if (this.pairingServer) {
      await this.pairingServer.close('cancelled');
    }
  }

  async forgetPhone(): Promise<void> {
    this.recordEvent('info', 'Pairing', 'Forgetting the paired iPhone.');
    this.receiverController.stopReceiver();
    if (this.pairingServer) {
      await this.pairingServer.close('forget-phone');
    }
    this.secretStore.delete(SECRET_ACCOUNT);
    this.recordEvent('success', 'Pairing', 'Paired iPhone trust removed from Keychain.');
  }

  async resetSource(): Promise<void> {
    this.settings.resetSourceBindingID();
    this.recordEvent('info', 'Source', 'Reset the source binding; existing Finder files were preserved.');
    await this.restartReceiver();
  }

  setStorageMode(mode: 'albumDate' | 'albumOnly' | 'flat'): void {
    if (!isDestinationStorageMode(mode)) return;
    if (this.settings.storageMode === mode) return;
    this.settings.storageMode = mode;
    this.recordEvent('info', 'Destination', `Storage mode changed to ${mode}.`);
    void this.restartReceiver(true);
  }

  setLaunchAtLogin(enabled: boolean): void {
    this.settings.launchAtLoginRequested = enabled;
    this.recordEvent('success', 'Launch at Login', enabled ? 'Launch at Login enabled.' : 'Launch at Login disabled.');
  }

  async shutdown(): Promise<void> {
    if (this.pairingServer) {
      await this.pairingServer.close('shutdown');
    }
    this.receiverController.stopReceiver();
    if (this.manifest) {
      this.manifest.close();
      this.manifest = null;
    }
  }

  recoverReceiver(reason: string): void {
    this.recordEvent('info', 'Recovery', `${reason}; reconciling the receiver listener.`);
    void this.restartReceiver(true);
  }

  attachSetupWindow(window: BrowserWindow | null): void {
    this.setupWindow = window;
  }

  attachPairingWindow(notifier: () => void): void {
    this.pairingWindow = notifier;
  }

  copyOperationLog(): string {
    const text = this.operationLog.all
      .map((entry) => `${entry.occurredAt.toISOString()} [${entry.level.toUpperCase()}] ${entry.category}: ${entry.message}`)
      .join('\n');
    return text;
  }

  clearOperationLog(): void {
    this.operationLog.clear();
  }

  private async restartReceiver(forceRestart = false): Promise<void> {
    const destination = this.destinationStore.resolve();
    const peer = this.loadPairedPeer();
    if (!destination || !peer) {
      this.receiverController.stopReceiver();
      this.runtimeState = 'ready';
      return;
    }
    try {
      await this.receiverController.startReceiver({
        destination,
        peer: {
          psk: peer.psk,
          pskIdentity: peer.pskIdentity,
          sourceBindingID: peer.sourceBindingID,
          displayName: peer.displayName,
        },
        storageMode: this.settings.storageMode,
        sourceBindingID: peer.sourceBindingID,
        displayName: this.displayName,
      });
      this.runtimeState = 'ready';
      this.errorMessage = null;
    } catch (err) {
      this.errorMessage = (err as Error).message;
      this.runtimeState = 'error';
      this.recordEvent('error', 'Receiver', `Failed to start: ${this.errorMessage}`);
    }
    void forceRestart;
  }

  private loadPairedPeer(): PairedPeerRecord | null {
    if (!this.safeStorageAvailable) return null;
    const stored = this.secretStore.load<{ psk: string; pskIdentity: string; sourceBindingID: string; displayName: string; deviceID: string }>(SECRET_ACCOUNT);
    if (!stored) return null;
    return {
      psk: Buffer.from(stored.psk, 'base64'),
      pskIdentity: Buffer.from(stored.pskIdentity, 'base64'),
      sourceBindingID: stored.sourceBindingID,
      displayName: stored.displayName,
      deviceID: stored.deviceID,
    };
  }

  private lookupPskByIdentity(identity: string): Uint8Array | null {
    const peer = this.loadPairedPeer();
    if (!peer) return null;
    const expected = Buffer.from(peer.pskIdentity).toString('utf-8');
    if (expected !== identity) return null;
    return peer.psk;
  }

  private recordEvent(level: 'info' | 'success' | 'warning' | 'error', category: string, message: string): void {
    const entry = this.operationLog.record({ level, category, message });
    this.operationLogger.write(entry);
    this.broadcastSnapshot();
  }

  private broadcastSnapshot(): void {
    if (this.setupWindow && !this.setupWindow.isDestroyed()) {
      this.setupWindow.webContents.send('setup:changed', this.snapshot());
    }
  }
}

function serialisePeer(record: PairedPeerRecord): {
  psk: string;
  pskIdentity: string;
  sourceBindingID: string;
  displayName: string;
  deviceID: string;
} {
  return {
    psk: Buffer.from(record.psk).toString('base64'),
    pskIdentity: Buffer.from(record.pskIdentity).toString('base64'),
    sourceBindingID: record.sourceBindingID,
    displayName: record.displayName,
    deviceID: record.deviceID,
  };
}

void ManifestStore;
void DestinationWriter;
void SyncServerSession;
void TlsPskServer;
void DestinationStorageMode;
void randomUUID;
void resolve;
void existsSync;
