// SetupWindow — the Setup BrowserWindow that displays Status / Last Sync /
// Operation Log. Mirrors `apps/macos/Sources/SetupView.swift` three-section
// layout.

import { BrowserWindow, app } from 'electron';
import { join } from 'node:path';
import type { ModelRoot } from './model-root.js';

export interface SetupWindowOptions {
  model: ModelRoot;
  preloadPath: string;
}

export class SetupWindow {
  private window: BrowserWindow | null = null;

  constructor(private readonly options: SetupWindowOptions) {}

  show(): void {
    if (this.window) {
      this.window.show();
      this.window.focus();
      return;
    }
    const preload = this.options.preloadPath;
    const renderer = join(__dirname, '..', 'renderer', 'setup.html');
    this.window = new BrowserWindow({
      width: 620,
      height: 680,
      minWidth: 580,
      minHeight: 560,
      title: 'iPhone Sync Setup',
      autoHideMenuBar: true,
      webPreferences: {
        preload,
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });
    void this.window.loadFile(renderer);
    this.window.on('closed', () => {
      this.window = null;
    });
  }

  close(): void {
    this.window?.close();
  }

  widthPref(): number {
    return 620;
  }

  heightPref(): number {
    return 680;
  }

  static appName(): string {
    return app.getName();
  }
}
