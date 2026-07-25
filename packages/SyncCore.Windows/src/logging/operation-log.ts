// OperationLogBuffer — bounded in-memory ring (newest-first) capped at
// `SyncConstants.operationLogCapacity` (= 500). Mirrors
// `packages/SyncCore/Sources/SyncCore/OperationLog.swift`.

import { randomUUID } from 'node:crypto';

export type OperationLogLevel = 'info' | 'success' | 'warning' | 'error';

export interface OperationLogEntry {
  id: string;
  occurredAt: Date;
  level: OperationLogLevel;
  category: string;
  message: string;
}

export class OperationLogBuffer {
  private entries: OperationLogEntry[] = [];

  constructor(public readonly capacity: number = 500) {}

  record(event: Omit<OperationLogEntry, 'id' | 'occurredAt'> & { occurredAt?: Date }): OperationLogEntry {
    const entry: OperationLogEntry = {
      id: randomUUID(),
      occurredAt: event.occurredAt ?? new Date(),
      level: event.level,
      category: event.category,
      message: event.message,
    };
    this.entries.unshift(entry);
    if (this.entries.length > this.capacity) {
      this.entries.length = this.capacity;
    }
    return entry;
  }

  get all(): ReadonlyArray<OperationLogEntry> {
    return this.entries;
  }

  clear(): void {
    this.entries = [];
  }
}
