// AutoLaunchService — registers/unregisters the app at Windows login via
// `app.setLoginItemSettings`. Mirrors `setLaunchAtLogin(_:)` in MacAppModel.

import { app } from 'electron';

export interface AutoLaunchServiceOptions {
  enabled: boolean;
}

export class AutoLaunchService {
  private currentEnabled: boolean;

  constructor(private readonly options: AutoLaunchServiceOptions) {
    this.currentEnabled = options.enabled;
  }

  sync(requested: boolean): void {
    if (requested === this.currentEnabled) return;
    app.setLoginItemSettings({
      openAtLogin: requested,
      openAsHidden: true,
      path: process.execPath,
    });
    this.currentEnabled = requested;
  }

  isEnabled(): boolean {
    return this.currentEnabled;
  }
}
