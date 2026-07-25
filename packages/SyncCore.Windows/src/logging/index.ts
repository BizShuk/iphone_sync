// Logging layer: in-memory 500-entry OperationLogBuffer plus a streaming
// operation-logger that writes JSONL to `%LOCALAPPDATA%\iPhoneSync\logs\`.
//
// Mirrors `packages/SyncCore/Sources/SyncCore/OperationLog.swift`.

export { OperationLogBuffer } from './operation-log.js';
export { OperationLogger } from './operation-logger.js';
export type { OperationLogLevel, OperationLogEntry } from './operation-log.js';
