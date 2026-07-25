// Protocol layer: wire constants, frame codec, framed connection, message types.

export { SyncConstants } from './constants.js';
export {
  FrameCodec,
  FrameCodecError,
  FRAME_HEADER_LENGTH,
  FRAME_MAGIC,
  FrameKind,
  type FrameHeader,
} from './frame-codec.js';
export {
  FramedConnection,
  FramedConnectionError,
  type SyncFrame,
} from './framed-connection.js';
export {
  encodeSessionRequest,
  decodeSessionMessage,
  encodeDecision,
  decodeDecision,
  encodeResult,
  decodeResult,
  decodeControlMessage,
  type SessionMessage,
  type SyncControlMessage,
  type SyncSummary,
  type TransferDecision,
  type TransferFailureCode,
  type TransferResult,
} from './messages.js';
export {
  ResourceIdentity,
  type ResourceDescriptor,
} from './resource.js';
export {
  FilenamePolicy,
  FilenamePolicyError,
  RESOURCE_ID_LENGTH,
  type FilenamePolicyInput,
} from './filename-policy.js';
