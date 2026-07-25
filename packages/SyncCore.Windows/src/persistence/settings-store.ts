// SettingsStore — typed wrapper around `%LOCALAPPDATA%\iPhoneSync\settings.json`.
// Mirrors `apps/macos/Sources/MacSettingsStore.swift`.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { DestinationStorageMode, isDestinationStorageMode, type DestinationStorageModeType } from '../receiver/destination-storage-mode.js';

export interface SettingsSchema {
  receiverID: string;
  sourceBindingID: string;
  storageMode: DestinationStorageModeType;
  launchAtLoginRequested: boolean;
  destinationBookmark: string | null;
}

const DEFAULT_SETTINGS: SettingsSchema = {
  receiverID: '',
  sourceBindingID: '',
  storageMode: DestinationStorageMode.albumDate,
  launchAtLoginRequested: false,
  destinationBookmark: null,
};

export class SettingsStore {
  private state: SettingsSchema;

  constructor(private readonly filePath: string) {
    if (existsSync(filePath)) {
      const raw = readFileSync(filePath, 'utf-8');
      try {
        this.state = { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
      } catch {
        this.state = { ...DEFAULT_SETTINGS };
      }
    } else {
      this.state = { ...DEFAULT_SETTINGS };
    }
    if (!this.state.receiverID) {
      this.state.receiverID = randomUUID();
    }
    if (!isDestinationStorageMode(this.state.storageMode)) {
      this.state.storageMode = DEFAULT_SETTINGS.storageMode;
    }
  }

  get receiverID(): string { return this.state.receiverID; }

  get sourceBindingIDValue(): string { return this.state.sourceBindingID; }

  set sourceBindingIDValue(value: string) {
    this.state.sourceBindingID = value;
    this.persist();
  }

  resetSourceBindingID(): void {
    this.state.sourceBindingID = randomUUID();
    this.persist();
  }

  get storageMode(): DestinationStorageModeType { return this.state.storageMode; }
  set storageMode(value: DestinationStorageModeType) {
    this.state.storageMode = value;
    this.persist();
  }

  get launchAtLoginRequested(): boolean { return this.state.launchAtLoginRequested; }
  set launchAtLoginRequested(value: boolean) {
    this.state.launchAtLoginRequested = value;
    this.persist();
  }

  get destinationBookmark(): string | null { return this.state.destinationBookmark; }
  set destinationBookmark(value: string | null) {
    this.state.destinationBookmark = value;
    this.persist();
  }

  private persist(): void {
    mkdirSync(dirname(this.filePath), { recursive: true });
    writeFileSync(this.filePath, JSON.stringify(this.state, null, 2), 'utf-8');
  }
}
