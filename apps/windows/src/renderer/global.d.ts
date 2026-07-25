// Shared globals for the renderer scripts. Both setup.html and
// pairing.html load their respective TS bundles against the same
// contextBridge surface. This file is a module (`export {}`) so the
// `declare global` augmentation is picked up automatically when the file
// is included by the root tsconfig `include: ["src/**/*"]` glob. No
// explicit `/// <reference>` is required in the consuming scripts.

declare global {
  interface Window {
    iphoneSync: {
      snapshot(): Promise<{
        destinationPath: string | null;
        pairedPeerID: string | null;
        pairedPeerDisplayName: string | null;
        sourceBindingID: string;
        launchAtLogin: boolean;
        storageMode: 'albumDate' | 'albumOnly' | 'flat';
        isPairing: boolean;
        pairingCode: string | null;
        pairingExpiresAt: string | null;
        lastSummary: { added: number; existing: number; notLocal: number; failed: number } | null;
        runtimeState: 'ready' | 'receiving' | 'error';
        errorMessage: string | null;
        operationLog: Array<{
          id: string;
          occurredAt: string;
          level: 'info' | 'success' | 'warning' | 'error';
          category: string;
          message: string;
        }>;
      }>;
      chooseDestination(): Promise<void>;
      openPairing(): Promise<void>;
      cancelPairing(): Promise<void>;
      forgetPhone(): Promise<void>;
      resetSource(): Promise<void>;
      setStorageMode(mode: 'albumDate' | 'albumOnly' | 'flat'): Promise<void>;
      setLaunchAtLogin(enabled: boolean): Promise<void>;
      copyOperationLog(): Promise<void>;
      clearOperationLog(): Promise<void>;
      onSnapshot(handler: (snap: any) => void): () => void;
      onPairingUpdate(handler: (payload: { code: string; expiresAt: string }) => void): () => void;
    };
  }
}

export {};
