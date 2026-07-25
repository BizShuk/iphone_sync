// PairingWindow — small dedicated window showing the six-digit SAS and a
// two-minute countdown. Mirrors `PairingCodeDisplay` in `SetupView.swift`.

import { BrowserWindow } from 'electron';
import { join } from 'node:path';
import type { ModelRoot } from './model-root.js';

export interface PairingWindowOptions {
  model: ModelRoot;
  preloadPath: string;
}

export class PairingWindow {
  private window: BrowserWindow | null = null;

  constructor(private readonly options: PairingWindowOptions) {}

  show(code: string, expiresAt: Date): void {
    if (this.window) {
      this.window.show();
      this.window.focus();
      this.window.webContents.send('pairing:update', { code, expiresAt: expiresAt.toISOString() });
      return;
    }
    const renderer = join(__dirname, '..', 'renderer', 'pairing.html');
    this.window = new BrowserWindow({
      width: 360,
      height: 240,
      resizable: false,
      minimizable: false,
      maximizable: false,
      title: 'iPhone Sync Pairing',
      autoHideMenuBar: true,
      webPreferences: {
        preload: this.options.preloadPath,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });
    void this.window.loadFile(renderer);
    this.window.webContents.once('did-finish-load', () => {
      this.window?.webContents.send('pairing:update', { code, expiresAt: expiresAt.toISOString() });
    });
    this.window.on('closed', () => {
      this.window = null;
    });
  }

  close(): void {
    this.window?.close();
  }

  isOpen(): boolean {
    return this.window !== null;
  }
}
