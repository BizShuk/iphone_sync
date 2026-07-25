// TrayController — system-tray icon + context menu. Mirrors
// `apps/macos/Sources/iPhoneSyncMacApp.swift` `configureStatusItem(...)` +
// `rebuildMenu(...)`.

import { Tray, Menu, nativeImage } from 'electron';
import { existsSync } from 'node:fs';

export interface TrayControllerOptions {
  iconPath: string;
  onOpenSetup: () => void;
  onPairNewIPhone: () => void;
  onChooseDestination: () => void;
  onQuit: () => void;
}

export class TrayController {
  private tray: Tray | null = null;

  constructor(private readonly options: TrayControllerOptions) {}

  install(): void {
    if (!existsSync(this.options.iconPath)) {
      // Fall back to a tiny in-memory image so the app can still launch in
      // dev environments where the icon asset has not been built yet.
      this.options.iconPath = nativeImage.createEmpty().toDataURL();
    }
    const image = nativeImage.createFromPath(this.options.iconPath);
    this.tray = new Tray(image);
    this.tray.setToolTip('iPhone Sync');
    this.rebuildMenu();
  }

  rebuildMenu(): void {
    if (!this.tray) return;
    this.tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open Setup', click: () => this.options.onOpenSetup() },
      { label: 'Pair New iPhone', click: () => this.options.onPairNewIPhone() },
      { label: 'Choose Destination', click: () => this.options.onChooseDestination() },
      { type: 'separator' },
      { label: 'Quit', click: () => this.options.onQuit() },
    ]));
  }

  setIdle(): void {
    this.tray?.setImage(this.options.iconPath);
  }

  setReceiving(): void {
    this.tray?.setImage(this.options.iconPath);
  }
}
