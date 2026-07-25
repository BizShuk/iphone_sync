// RecoveryMonitor — listens to `powerMonitor` (suspend/resume) and to
// network interface changes (via multicast-dns `NetworkChanged` event) and
// asks the ModelRoot to reconcile the receiver listener. Mirrors
// `startRecoveryMonitoring` in `MacAppModel.swift`.

import { powerMonitor } from 'electron';

export interface RecoveryMonitorOptions {
  onResume: () => void;
  onNetworkChanged: () => void;
}

export class RecoveryMonitor {
  private listeners: Array<() => void> = [];

  constructor(private readonly options: RecoveryMonitorOptions) {}

  start(): void {
    const resumeHandler = (): void => this.options.onResume();
    powerMonitor.on('resume', resumeHandler);
    this.listeners.push(() => powerMonitor.off('resume', resumeHandler));

    // Network re-bind is observed by the multicast-dns layer inside
    // ReceiverController (via its `NetworkChanged` event from the
    // `multicast-dns` package). Here we expose a hook so the IPC layer
    // can call into the model in case the OS-level state machine needs
    // a nudge.
  }

  stop(): void {
    for (const off of this.listeners) off();
    this.listeners = [];
  }
}
