// IPC handlers — bridge renderer requests to ModelRoot.

import { ipcMain, clipboard } from 'electron';
import type { ModelRoot, ModelSnapshot } from './model-root.js';

export function registerIpc(model: ModelRoot): void {
  ipcMain.handle('setup:snapshot', (): ModelSnapshot => model.snapshot());
  ipcMain.handle('setup:choose-destination', () => model.openDestinationChooser());
  ipcMain.handle('setup:open-pairing', () => model.openPairingWindow());
  ipcMain.handle('setup:cancel-pairing', () => model.cancelPairingWindow());
  ipcMain.handle('setup:forget-phone', () => model.forgetPhone());
  ipcMain.handle('setup:reset-source', () => model.resetSource());
  ipcMain.handle('setup:set-storage-mode', (_event, mode: 'albumDate' | 'albumOnly' | 'flat') => {
    model.setStorageMode(mode);
  });
  ipcMain.handle('setup:set-launch-at-login', (_event, enabled: boolean) => {
    model.setLaunchAtLogin(enabled);
  });
  ipcMain.handle('setup:copy-operation-log', () => {
    const text = model.copyOperationLog();
    clipboard.writeText(text);
  });
  ipcMain.handle('setup:clear-operation-log', () => {
    model.clearOperationLog();
  });
}
