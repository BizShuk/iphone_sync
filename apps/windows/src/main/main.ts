// iPhone Sync Windows 11 receiver — Electron main entry.
//
// Mirrors `apps/macos/Sources/iPhoneSyncMacApp.swift` + `MacAppDelegate`:
//   1. `app.whenReady` → bootstrap AppModel → restore destination / paired peer
//   2. Create tray icon + menu (Open Setup / Pair New iPhone / Choose Destination / Quit)
//   3. If `--open-setup` was passed on command line, show the Setup window
//   4. `app.beforeQuit` → tear down ReceiverController cleanly

import { app, BrowserWindow } from 'electron';
import { join } from 'node:path';
import { mkdirSync } from 'node:fs';
import { TrayController } from './tray.js';
import { SetupWindow } from './setup-window.js';
import { PairingWindow } from './pairing-window.js';
import { AutoLaunchService } from './auto-launch.js';
import { RecoveryMonitor } from './recovery.js';
import { ModelRoot } from './model-root.js';
import { registerIpc } from './ipc.js';

class IPhoneSyncWindowsApp {
  private readonly tray: TrayController;
  private readonly setupWindow: SetupWindow;
  private readonly pairingWindow: PairingWindow;
  private readonly autoLaunch: AutoLaunchService;
  private readonly recovery: RecoveryMonitor;
  private readonly model: ModelRoot;

  constructor() {
    const userData = app.getPath('userData');
    mkdirSync(join(userData, 'logs'), { recursive: true });

    this.model = new ModelRoot({
      userDataDir: userData,
    });

    this.tray = new TrayController({
      iconPath: join(app.getAppPath(), 'assets', 'icons', 'tray.ico'),
      onOpenSetup: () => this.setupWindow.show(),
      onPairNewIPhone: () => this.model.openPairingWindow(),
      onChooseDestination: () => this.model.openDestinationChooser(),
      onQuit: () => app.quit(),
    });

    this.setupWindow = new SetupWindow({
      model: this.model,
      preloadPath: join(__dirname, '..', 'preload', 'preload.js'),
    });

    this.pairingWindow = new PairingWindow({
      model: this.model,
      preloadPath: join(__dirname, '..', 'preload', 'preload.js'),
    });

    this.autoLaunch = new AutoLaunchService({
      enabled: this.model.settings.launchAtLoginRequested,
    });

    this.recovery = new RecoveryMonitor({
      onResume: () => this.model.recoverReceiver('powerMonitor resume'),
      onNetworkChanged: () => this.model.recoverReceiver('network change'),
    });
  }

  start(): void {
    // Make sure only one instance runs at a time.
    const gotLock = app.requestSingleInstanceLock();
    if (!gotLock) {
      app.quit();
      return;
    }

    app.on('second-instance', () => {
      this.setupWindow.show();
    });

    app.whenReady().then(async () => {
      await this.model.bootstrap();
      this.tray.install();
      this.model.attachPairingWindow(() => this.pairingWindow.show('------', new Date()));
      this.model.attachSetupWindow(this.setupWindow as unknown as BrowserWindow | null);
      registerIpc(this.model);
      this.autoLaunch.sync(this.model.settings.launchAtLoginRequested);

      if (process.argv.includes('--open-setup')) {
        this.setupWindow.show();
      }
    });

    app.on('window-all-closed', () => {
      // Keep the app alive when the Setup window is closed; the tray icon
      // remains the only entry point. This mirrors `LSUIElement` behaviour.
      // The signature must take no arguments; Electron passes none here.
    });

    app.on('before-quit', async () => {
      this.recovery.stop();
      await this.model.shutdown();
    });
  }
}

const main = new IPhoneSyncWindowsApp();
main.start();
