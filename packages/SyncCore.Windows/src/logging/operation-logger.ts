// OperationLogger — append-only JSONL sink to
// `%LOCALAPPDATA%\iPhoneSync\logs\operations-<YYYY-MM-DD>.jsonl`.
// Mirrors the macOS receiver's `os.Logger` integration.

import { appendFileSync, mkdirSync, existsSync, readdirSync, unlinkSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { OperationLogEntry, OperationLogLevel } from './operation-log.js';

export interface OperationLoggerOptions {
  logsDir: string;
}

export class OperationLogger {
  private currentDate: string = '';

  constructor(private readonly options: OperationLoggerOptions) {
    mkdirSync(this.options.logsDir, { recursive: true });
  }

  /** Append one entry as a JSON line. */
  write(entry: OperationLogEntry): void {
    const today = this.todayStamp(entry.occurredAt);
    if (today !== this.currentDate) {
      this.currentDate = today;
    }
    const path = join(this.options.logsDir, `operations-${today}.jsonl`);
    const line = JSON.stringify({
      ...entry,
      occurredAt: entry.occurredAt.toISOString(),
    }) + '\n';
    appendFileSync(path, line, 'utf-8');
  }

  /** Read entries for the given day, newest first. */
  readDay(date: Date = new Date()): OperationLogEntry[] {
    const path = join(this.options.logsDir, `operations-${this.todayStamp(date)}.jsonl`);
    if (!existsSync(path)) return [];
    const lines = require('node:fs').readFileSync(path, 'utf-8').split('\n').filter(Boolean);
    return lines
      .map((line: string) => JSON.parse(line) as OperationLogEntry)
      .reverse();
  }

  /** Drop log files older than `retainDays`. */
  prune(retainDays: number = 14): void {
    const cutoff = Date.now() - retainDays * 86_400_000;
    for (const name of readdirSync(this.options.logsDir)) {
      const path = join(this.options.logsDir, name);
      try {
        if (statSync(path).mtimeMs < cutoff) {
          unlinkSync(path);
        }
      } catch {
        // ignore
      }
    }
  }

  private todayStamp(d: Date): string {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }
}

export const LevelEmoji: Record<OperationLogLevel, string> = {
  info: '·',
  success: '✓',
  warning: '!',
  error: '✗',
};
