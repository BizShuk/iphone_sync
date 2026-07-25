// Preload — context bridge between the renderer (Setup / Pairing) and the
// main process. Mirrors the implicit `MacAppModel` UI bindings in
// `apps/macos/Sources/SetupView.swift`.

import { contextBridge, ipcRenderer } from 'electron';

export interface SetupSnapshot {
  destinationPath: string | null;
  pairedPeerID: string | null;
  pairedPeerDisplayName: string | null;
  launchAtLogin: boolean;
  storageMode: 'albumDate' | 'albumOnly' | 'flat';
  isPairing: boolean;
  pairingCode: string | null;
  pairingExpiresAt: string | null;
  lastSummary: { added: number; existing: number; notLocal: number; failed: number } | null;
  operationLog: Array<{
    id: string;
    occurredAt: string;
    level: 'info' | 'success' | 'warning' | 'error';
    category: string;
    message: string;
  }>;
}

const api = {
  snapshot: async (): Promise<SetupSnapshot> => {
    return await ipcRenderer.invoke('setup:snapshot');
  },
  chooseDestination: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:choose-destination');
  },
  openPairing: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:open-pairing');
  },
  cancelPairing: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:cancel-pairing');
  },
  forgetPhone: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:forget-phone');
  },
  resetSource: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:reset-source');
  },
  setStorageMode: async (mode: 'albumDate' | 'albumOnly' | 'flat'): Promise<void> => {
    await ipcRenderer.invoke('setup:set-storage-mode', mode);
  },
  setLaunchAtLogin: async (enabled: boolean): Promise<void> => {
    await ipcRenderer.invoke('setup:set-launch-at-login', enabled);
  },
  copyOperationLog: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:copy-operation-log');
  },
  clearOperationLog: async (): Promise<void> => {
    await ipcRenderer.invoke('setup:clear-operation-log');
  },
  onSnapshot: (handler: (snap: SetupSnapshot) => void): (() => void) => {
    const listener = (): void => {
      void api.snapshot().then(handler);
    };
    ipcRenderer.on('setup:changed', listener);
    return () => ipcRenderer.off('setup:changed', listener);
  },
  onPairingUpdate: (handler: (payload: { code: string; expiresAt: string }) => void): (() => void) => {
    const listener = (_: unknown, payload: { code: string; expiresAt: string }): void => handler(payload);
    ipcRenderer.on('pairing:update', listener);
    return () => ipcRenderer.off('pairing:update', listener);
  },
};

contextBridge.exposeInMainWorld('iphoneSync', api);

export type IPhoneSyncAPI = typeof api;
